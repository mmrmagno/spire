#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER="spire"
ENDPOINT="https://spire.home.arpa:6443"
VERSION="v1.14.1"
CONTROL_PLANE_IP="192.168.0.213"

export SOPS_AGE_KEY_FILE="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"

cd "$REPO"

usage() { echo "usage: $0 architect|ironclad|all" >&2; exit 2; }

[ $# -eq 1 ] || usage
TARGET="$1"

case "$TARGET" in
  architect) NODES=(architect) ;;
  ironclad)  NODES=(ironclad) ;;
  all)       NODES=(architect ironclad) ;;
  *)         usage ;;
esac

check_placeholders() {
  local f="$1"
  if grep -q 'REPLACE_' "$f"; then
    echo "refusing: unresolved placeholder in $f" >&2
    grep -n 'REPLACE_' "$f" >&2
    exit 1
  fi
}

check_placeholders talos/patches/common.yaml
for n in "${NODES[@]}"; do check_placeholders "talos/patches/${n}.yaml"; done

WORK="$(mktemp -d)"
trap 'find "$WORK" -type f -exec shred -u {} + 2>/dev/null; rm -rf "$WORK"' EXIT

sops -d talos/secrets/secrets.enc.yaml > "$WORK/secrets.yaml"
mkdir -p talos/generated

for n in "${NODES[@]}"; do
  if [ "$n" = "architect" ]; then
    TYPE=controlplane
    PATCH_FLAG=--config-patch-control-plane
    EXTRA=(--config-patch-control-plane @talos/patches/cilium-prereq.yaml)
  else
    TYPE=worker
    PATCH_FLAG=--config-patch-worker
    EXTRA=()
  fi
  rm -f "talos/generated/${n}.yaml"
  talosctl gen config "$CLUSTER" "$ENDPOINT" \
    --with-secrets "$WORK/secrets.yaml" \
    --talos-version "$VERSION" \
    --config-patch @talos/patches/common.yaml \
    "$PATCH_FLAG" "@talos/patches/${n}.yaml" \
    "${EXTRA[@]}" \
    --output-types "$TYPE" \
    -o "talos/generated/${n}.yaml"
done

for n in "${NODES[@]}"; do
  if ! talosctl validate -m metal -c "talos/generated/${n}.yaml" >/dev/null 2>&1; then
    echo "generated config for ${n} failed validation:" >&2
    talosctl validate -m metal -c "talos/generated/${n}.yaml" >&2
    rm -f "talos/generated/${n}.yaml"
    exit 1
  fi
  echo "validated: ${n}"
done

rm -f talos/generated/talosconfig
talosctl gen config "$CLUSTER" "$ENDPOINT" \
  --with-secrets "$WORK/secrets.yaml" \
  --talos-version "$VERSION" \
  --output-types talosconfig \
  -o talos/generated/talosconfig

talosctl --talosconfig talos/generated/talosconfig config endpoint "$CONTROL_PLANE_IP"
talosctl --talosconfig talos/generated/talosconfig config node "$CONTROL_PLANE_IP"

echo "generated:"
ls -1 talos/generated/
