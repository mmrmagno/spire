#!/usr/bin/env bash
set -euo pipefail

# Age-encrypted off-router backup of a MikroTik device.
# show-sensitive is deliberate: it emits PSKs, SNMP and BGP secrets, which is exactly what a
# restore needs. The output therefore never reaches the repo, only ~/spire-backups, encrypted.
# User passwords and SSH keys are NOT in a RouterOS export at all; they live in Proton Pass.

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-}"
HOSTONLY="${HOST##*@}"
NAME="${2:-${HOSTONLY%%.*}}"
DEST="${SPIRE_BACKUP_DIR:-$HOME/spire-backups}"
KEEP="${ROUTER_BACKUP_KEEP:-10}"

[ -n "$HOST" ] || { echo "usage: $0 <user@host> [name]" >&2; exit 2; }

RECIPIENTS="$(grep -oE 'age1[0-9a-z]+' "$REPO/.sops.yaml" | sort -u)"
[ "$(printf '%s\n' "$RECIPIENTS" | grep -c .)" -eq 1 ] || { echo ".sops.yaml has more than one age recipient, pick one explicitly" >&2; exit 1; }
RECIPIENT="$RECIPIENTS"
[ -n "$RECIPIENT" ] || { echo "no age recipient found in .sops.yaml" >&2; exit 1; }

umask 077
mkdir -p "$DEST"

WORK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/network-backup.XXXXXX")"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM HUP

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$DEST/${NAME}-${STAMP}.rsc.age"

ssh "$HOST" '/export terse show-sensitive' > "$WORK/export.rsc"
[ -s "$WORK/export.rsc" ] || { echo "export came back empty, refusing to write a backup" >&2; exit 1; }

age -r "$RECIPIENT" -o "$WORK/out.age" "$WORK/export.rsc"
mv "$WORK/out.age" "$OUT"
echo "wrote $OUT"

mapfile -t OLD < <(find "$DEST" -maxdepth 1 -name "${NAME}-*.rsc.age" -printf '%f\n' | sort -r | tail -n "+$((KEEP + 1))")
for f in "${OLD[@]:-}"; do
  [ -n "$f" ] || continue
  rm -f "$DEST/$f"
  echo "pruned $f"
done

cat <<MSG

Decrypt with:
  age -d -i \$SOPS_AGE_KEY_FILE $OUT

A full binary backup (needed to restore RouterBOOT settings, not just config) is separate:
  ssh $HOST '/system backup save name=$NAME encryption=aes-sha256 password=<from Proton Pass>'
  scp $HOST:/$NAME.backup .
MSG
