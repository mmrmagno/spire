#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$REPO/network/secrets.enc.yaml"

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

umask 077
cd "$REPO"

usage() { echo "usage: $0 merchant|osty|all" >&2; exit 2; }

[ $# -eq 1 ] || usage
case "$1" in
  merchant) TARGETS=(merchant) ;;
  osty)     TARGETS=(osty) ;;
  all)      TARGETS=(merchant osty) ;;
  *)        usage ;;
esac

WORK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/gen-network.XXXXXX")"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT INT TERM HUP

# Placeholders are REPLACE_<KEY>, resolved from the top-level keys of secrets.enc.yaml.
# No secrets file is fine as long as no template uses a placeholder.
if [ -f "$SECRETS" ]; then
  sops -d --output-type json "$SECRETS" > "$WORK/secrets.json"
  jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$WORK/secrets.json" > "$WORK/subs"
else
  : > "$WORK/subs"
fi

mkdir -p network/generated

for t in "${TARGETS[@]}"; do
  src="network/${t}.rsc"
  out="network/generated/${t}.rsc"
  [ -f "$src" ] || { echo "missing $src" >&2; exit 1; }

  cp "$src" "$WORK/${t}.rsc"
  # Values go through a script file, never argv: argv is world-readable in ps.
  # They are also escaped, so a & | or \ in a value cannot corrupt the output.
  : > "$WORK/sedscript"
  while IFS=$'\t' read -r key value; do
    [ -n "$key" ] || continue
    printf 's|REPLACE_%s|%s|g\n' "$key" "$(printf '%s' "$value" | sed -e 's/[&|\\]/\\&/g')" >> "$WORK/sedscript"
  done < "$WORK/subs"
  sed -i -f "$WORK/sedscript" "$WORK/${t}.rsc"

  if grep -q 'REPLACE_' "$WORK/${t}.rsc"; then
    echo "refusing: unresolved placeholder in $src" >&2
    grep -n 'REPLACE_' "$WORK/${t}.rsc" >&2
    exit 1
  fi

  rm -f "$out"
  cp "$WORK/${t}.rsc" "$out"
  echo "rendered: $out"
done

cat <<'MSG'

Public keys are not kept in this repo. Fetch the one you need from the vault:

  pass-cli item view --vault-name "Spire (Homelab-K8s)" \
    --item-title "<device> (SSH key)" --field public_key > /tmp/<device>.pub

Next, against a device that still has its factory config:

  scp network/generated/<device>.rsc /tmp/<device>.pub <user>@<device>:/
  ssh <user>@<device> '/import file=<device>.rsc verbose=yes dry-run'

Only after a clean dry-run:

  /system reset-configuration no-defaults=yes keep-users=yes skip-backup=yes run-after-reset=<device>.rsc
MSG
