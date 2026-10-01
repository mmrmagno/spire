#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL_PLANE_IP="192.168.0.213"
DEST="${SPIRE_BACKUP_DIR:-$HOME/spire-backups}"
REMOTE="${SPIRE_BACKUP_REMOTE:-proton:Spire/etcd}"
LOCAL_KEEP="${SPIRE_LOCAL_KEEP:-10}"
REMOTE_KEEP="${SPIRE_REMOTE_KEEP:-30}"
PATTERN='^etcd-[0-9]{8}-[0-9]{6}\.db\.age$'

export TALOSCONFIG="${TALOSCONFIG:-$REPO/talos/generated/talosconfig}"

[ -f "$TALOSCONFIG" ] || { echo "missing $TALOSCONFIG, run scripts/gen-configs.sh first" >&2; exit 1; }

RECIPIENT="$(grep -oE 'age1[0-9a-z]+' "$REPO/.sops.yaml" | head -1)"
[ -n "$RECIPIENT" ] || { echo "no age recipient found in .sops.yaml" >&2; exit 1; }

umask 077
mkdir -p "$DEST"

exec 9>"$DEST/.lock"
flock -n 9 || { echo "another snapshot is already running" >&2; exit 1; }

NAME="etcd-$(date +%Y%m%d-%H%M%S)"
WORK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/etcd-snapshot.XXXXXX")"
PLAIN="$WORK/$NAME.db"
OUT="$DEST/$NAME.db.age"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT

talosctl -n "$CONTROL_PLANE_IP" etcd snapshot "$PLAIN"
age -r "$RECIPIENT" -o "$OUT" "$PLAIN"
echo "saved: $OUT"

mapfile -t local_sets < <(ls -1 "$DEST" | grep -E "$PATTERN" | sort)
while (( ${#local_sets[@]} > LOCAL_KEEP )); do
  echo "pruning local: ${local_sets[0]}"
  rm -f "$DEST/${local_sets[0]}"
  local_sets=("${local_sets[@]:1}")
done

if ! rclone lsd "${REMOTE%%:*}:" >/dev/null 2>&1; then
  echo "upload skipped: rclone remote ${REMOTE%%:*}: is not logged in" >&2
  echo "fix: rclone lsd ${REMOTE%%:*}: --protondrive-2fa=<code>, then re-run" >&2
  echo "local snapshot kept: $OUT" >&2
  exit 1
fi

rclone copy "$OUT" "$REMOTE" --retries 5 --low-level-retries 20
echo "uploaded: $REMOTE/$NAME.db.age"

mapfile -t remote_sets < <(rclone lsf --files-only "$REMOTE" | grep -E "$PATTERN" | sort)
while (( ${#remote_sets[@]} > REMOTE_KEEP )); do
  echo "pruning remote: ${remote_sets[0]}"
  rclone deletefile "$REMOTE/${remote_sets[0]}"
  remote_sets=("${remote_sets[@]:1}")
done

echo "local: ${#local_sets[@]}/$LOCAL_KEEP  remote: ${#remote_sets[@]}/$REMOTE_KEEP"
