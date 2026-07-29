#!/usr/bin/env bash
# Build a restricted static kubeconfig from the remote cluster deployer token.
# The output contains a bearer token. Keep it outside Git and store it in Vault.
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <administrator-context> <output-kubeconfig>" >&2
  exit 1
fi

ADMIN_CONTEXT="$1"
OUTPUT_KUBECONFIG="$2"
TARGET_NAMESPACE="team-a"
TOKEN_SECRET="jenkins-deployer-token"
OUTPUT_CONTEXT="external"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"

if [[ -e "$OUTPUT_KUBECONFIG" ]]; then
  echo "ERROR: refusing to overwrite $OUTPUT_KUBECONFIG" >&2
  exit 1
fi

OUTPUT_DIR="$(dirname "$OUTPUT_KUBECONFIG")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "ERROR: output directory does not exist: $OUTPUT_DIR" >&2
  exit 1
fi

OUTPUT_ABSOLUTE="$(cd "$OUTPUT_DIR" && pwd -P)/$(basename "$OUTPUT_KUBECONFIG")"
if [[ "$OUTPUT_ABSOLUTE" == "$REPOSITORY_ROOT/"* ]]; then
  echo "ERROR: write generated kubeconfigs outside the Git repository." >&2
  exit 1
fi

SERVER="$(
  kubectl --context "$ADMIN_CONTEXT" config view --raw --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.server}'
)"
CA_DATA="$(
  kubectl --context "$ADMIN_CONTEXT" config view --raw --minify --flatten \
    -o jsonpath='{.clusters[0].cluster.certificate-authority-data}'
)"

TOKEN=""
for _ in 1 2 3 4 5; do
  TOKEN="$(
    kubectl --context "$ADMIN_CONTEXT" get secret "$TOKEN_SECRET" \
      -n "$TARGET_NAMESPACE" -o jsonpath='{.data.token}' 2>/dev/null |
      base64 -d || true
  )"
  [[ -n "$TOKEN" ]] && break
  sleep 2
done

if [[ -z "$SERVER" || -z "$CA_DATA" || -z "$TOKEN" ]]; then
  echo "ERROR: cluster server, CA, or deployer token is unavailable." >&2
  exit 1
fi

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
CA_FILE="${TEMP_DIR}/ca.crt"
printf '%s' "$CA_DATA" | base64 -d > "$CA_FILE"

kubectl config --kubeconfig "$OUTPUT_KUBECONFIG" set-cluster "$OUTPUT_CONTEXT" \
  --server="$SERVER" \
  --certificate-authority="$CA_FILE" \
  --embed-certs=true >/dev/null
kubectl config --kubeconfig "$OUTPUT_KUBECONFIG" set-credentials jenkins-deployer \
  --token="$TOKEN" >/dev/null
kubectl config --kubeconfig "$OUTPUT_KUBECONFIG" set-context "$OUTPUT_CONTEXT" \
  --cluster="$OUTPUT_CONTEXT" \
  --user=jenkins-deployer \
  --namespace="$TARGET_NAMESPACE" >/dev/null
kubectl config --kubeconfig "$OUTPUT_KUBECONFIG" \
  use-context "$OUTPUT_CONTEXT" >/dev/null

chmod 600 "$OUTPUT_KUBECONFIG"
unset TOKEN

echo "Created restricted kubeconfig: $OUTPUT_KUBECONFIG"
echo "Context: $OUTPUT_CONTEXT | Namespace: $TARGET_NAMESPACE"
echo "Store its raw contents at secret/devops/jenkins/clusters/external."
