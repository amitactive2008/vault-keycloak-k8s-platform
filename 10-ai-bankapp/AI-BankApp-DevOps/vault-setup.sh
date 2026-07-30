#!/usr/bin/env bash
# Configure the Team B AI BankApp Vault policy, Kubernetes-auth role, and
# generated database values. Secret values are preserved across reruns.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KEYS_FILE="${PROJECT_ROOT}/02-vault/cluster-keys.json"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR_INTERNAL="${VAULT_ADDR_INTERNAL:-http://vault-active.vault.svc.cluster.local:8200}"
APP_NAMESPACE="team-b"
APP_SERVICE_ACCOUNT="ai-bankapp"
APP_ROLE="team-b-ai-bankapp"
APP_SECRET="secret/team-b/ai-bankapp"

for command_name in kubectl python3; do
  command -v "$command_name" >/dev/null 2>&1 || {
    echo "ERROR: required command not found: $command_name" >&2
    exit 1
  }
done

[[ -f "$KEYS_FILE" ]] || {
  echo "ERROR: Vault key file not found: $KEYS_FILE" >&2
  exit 1
}

VAULT_TOKEN="$(
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["root_token"])' \
    "$KEYS_FILE"
)"

vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR_INTERNAL" VAULT_TOKEN="$VAULT_TOKEN" \
    vault "$@"
}

read_existing() {
  vault_exec kv get -field="$1" "$APP_SECRET" 2>/dev/null || true
}

random_value() {
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
}

kubectl get namespace "$VAULT_NAMESPACE" >/dev/null
kubectl create namespace "$APP_NAMESPACE" --dry-run=client -o yaml |
  kubectl apply -f -

if ! vault_exec auth list -format=json | grep -q '"kubernetes/"'; then
  vault_exec auth enable kubernetes
fi

KV_VERSION="$(
  vault_exec secrets list -format=json |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret/", {}).get("options", {}).get("version", ""))'
)"
if [[ -z "$KV_VERSION" ]]; then
  vault_exec secrets enable -path=secret -version=2 kv
elif [[ "$KV_VERSION" != "2" ]]; then
  echo "ERROR: secret/ exists but is not a KV v2 mount." >&2
  exit 1
fi

DB_ROOT_PASSWORD="$(read_existing DB_ROOT_PASSWORD)"
DB_NAME="$(read_existing DB_NAME)"
DB_USER="$(read_existing DB_USER)"
DB_PASSWORD="$(read_existing DB_PASSWORD)"

[[ -n "$DB_ROOT_PASSWORD" ]] || DB_ROOT_PASSWORD="$(random_value)"
[[ -n "$DB_NAME" ]] || DB_NAME="bankappdb"
[[ -n "$DB_USER" ]] || DB_USER="bankuser"
[[ -n "$DB_PASSWORD" ]] || DB_PASSWORD="$(random_value)"

vault_exec kv put "$APP_SECRET" \
  DB_ROOT_PASSWORD="$DB_ROOT_PASSWORD" \
  DB_NAME="$DB_NAME" \
  DB_USER="$DB_USER" \
  DB_PASSWORD="$DB_PASSWORD" >/dev/null

kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  env VAULT_ADDR="$VAULT_ADDR_INTERNAL" VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write "$APP_ROLE" - < "${SCRIPT_DIR}/vault/policy.hcl"

KUBERNETES_CA_CERT="$(
  kubectl get configmap kube-root-ca.crt -n "$VAULT_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}'
)"
vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert="$KUBERNETES_CA_CERT" >/dev/null

vault_exec write "auth/kubernetes/role/${APP_ROLE}" \
  bound_service_account_names="$APP_SERVICE_ACCOUNT" \
  bound_service_account_namespaces="$APP_NAMESPACE" \
  policies="$APP_ROLE" \
  ttl="1h" >/dev/null

unset VAULT_TOKEN DB_ROOT_PASSWORD DB_PASSWORD

echo "Team B AI BankApp Vault configuration is ready."
echo "Runtime path: secret/data/team-b/ai-bankapp"
echo "Vault role: $APP_ROLE"
echo "Kubernetes identity: ${APP_NAMESPACE}/${APP_SERVICE_ACCOUNT}"
