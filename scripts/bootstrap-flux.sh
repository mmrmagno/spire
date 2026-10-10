#!/usr/bin/env bash
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPERATOR_VERSION="0.61.0"
VAULT="${SPIRE_VAULT:-Spire (Homelab-K8s)}"
AGE_ITEM="${SPIRE_FLUX_AGE_ITEM:-spire flux age key}"

export KUBECONFIG="${KUBECONFIG:-$REPO/kubeconfig}"

helm upgrade --install flux-operator \
  oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator \
  --version "$OPERATOR_VERSION" \
  --namespace flux-system --create-namespace --wait

if kubectl -n flux-system get secret sops-age >/dev/null 2>&1; then
  echo "sops-age secret exists, leaving it alone"
else
  key="$(pass-cli item view --vault-name "$VAULT" --item-title "$AGE_ITEM" --field note)"
  [[ "$key" == AGE-SECRET-KEY-* ]] || { echo "no age key in Proton Pass item '$AGE_ITEM'" >&2; exit 1; }
  kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=/dev/stdin <<<"$key"
  unset key
fi

kubectl apply --server-side -f "$REPO/kubernetes/flux/flux-instance.yaml"
kubectl -n flux-system wait fluxinstance/flux --for=condition=Ready --timeout=10m
flux get all -A
