#!/usr/bin/env bash
# ============================================================
# vault-setup.sh — Vault configuration for team-a webapp
#
# What this does:
#   1. Writes DB credentials to Vault at secret/data/team-a/webapp/db
#      (already accessible by team-a group users via team-a-policy)
#   2. Writes a Vault policy for the webapp backend service account
#   3. Enables and configures the Kubernetes auth method so the backend
#      pod (via Vault Agent) can authenticate using its service account token
#   4. Creates a Kubernetes auth role bound to the webapp-backend SA
#   5. Enables the Kubernetes secrets engine
#      → Vault can dynamically generate short-lived K8s service account tokens
#   6. Configures the Kubernetes secrets engine (in-cluster)
#   7. Creates a Kubernetes secrets engine role for the webapp-backend SA
#
# DB secret path : secret/data/team-a/webapp/db
# Vault auth role: auth/kubernetes/role/team-a-webapp
# K8s secret role: kubernetes/roles/team-a-webapp-sa
#
# Usage:
#   cd application/team-a-webapp/
#   chmod +x vault-setup.sh
#   ./vault-setup.sh
#
# Requires: kubectl, python3
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KEYS_FILE="${SCRIPT_DIR}/../../02-vault/cluster-keys.json"

# ── Configuration ──────────────────────────────────────────────
VAULT_NS="vault"
APP_NS="team-a"
SA_NAME="webapp-backend"
VAULT_ACTIVE_ADDR="http://vault-active.vault.svc.cluster.local:8200"

ROOT_TOKEN=$(python3 -c "
import json
with open('${KEYS_FILE}') as f:
    print(json.load(f)['root_token'])
")

# ── Helpers ────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# Run a vault command inside vault-0 with root token
vault_exec() {
  kubectl exec -n "$VAULT_NS" vault-0 -- \
    sh -c "export VAULT_ADDR=${VAULT_ACTIVE_ADDR} VAULT_TOKEN=${ROOT_TOKEN}; vault $*"
}

# ── Prereq check ───────────────────────────────────────────────
section "Checking prerequisites"
for cmd in kubectl python3; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
done
kubectl cluster-info &>/dev/null || { error "No cluster found. Is kind running?"; exit 1; }
[ -f "$KEYS_FILE" ] || { error "cluster-keys.json not found at $KEYS_FILE"; exit 1; }
info "Cluster : $(kubectl config current-context)"
info "Vault NS: $VAULT_NS  |  App NS: $APP_NS"

# ── Step 1: Write DB credentials to Vault ──────────────────────
# Path: secret/data/team-a/webapp/db
# team-a group already has read/write on secret/data/team-a/* via team-a-policy
section "Step 1 — Writing DB credentials to secret/data/team-a/webapp/db"

vault_exec "kv put secret/team-a/webapp/db \
  username=webapp_user \
  password='S3cur3P@ssw0rd' \
  host=postgres.team-a.svc.cluster.local \
  port=5432 \
  database=webapp_db"

info "DB credentials written → secret/data/team-a/webapp/db"

# ── Step 2: Vault policy for webapp backend ─────────────────────
section "Step 2 — Writing Vault policy 'team-a-webapp'"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  cat > /tmp/team-a-webapp.hcl << 'POLICY'
# team-a-webapp-policy — scoped to webapp secrets only
# Bound to: webapp-backend service account in team-a namespace

# Read DB and other webapp secrets (injected by Vault Agent)
path \"secret/data/team-a/webapp/*\" {
  capabilities = [\"read\"]
}

# Allow metadata read for KV v2
path \"secret/metadata/team-a/webapp/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY
  vault policy write team-a-webapp /tmp/team-a-webapp.hcl
  rm /tmp/team-a-webapp.hcl
"
info "Policy 'team-a-webapp' written"

# ── Step 3: Kubernetes auth method ─────────────────────────────
section "Step 3 — Enabling Kubernetes auth method"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault auth enable kubernetes 2>/dev/null \
    && echo 'Kubernetes auth method enabled' \
    || echo 'Kubernetes auth method already enabled — skipping'
"

# ── Step 4: Configure Kubernetes auth ──────────────────────────
section "Step 4 — Configuring Kubernetes auth method"

# Read the cluster CA cert from the vault pod's own service account mount
K8S_CA=$(kubectl exec -n "$VAULT_NS" vault-0 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc.cluster.local:443' \
    kubernetes_ca_cert='${K8S_CA}'
"
info "Kubernetes auth configured → https://kubernetes.default.svc.cluster.local:443"

# ── Step 5: Kubernetes auth role for webapp-backend SA ──────────
section "Step 5 — Creating Kubernetes auth role 'team-a-webapp'"

vault_exec "write auth/kubernetes/role/team-a-webapp \
  bound_service_account_names=${SA_NAME} \
  bound_service_account_namespaces=${APP_NS} \
  policies=team-a-webapp \
  ttl=1h"

info "Auth role 'team-a-webapp' created"
info "  SA: ${SA_NAME} | Namespace: ${APP_NS} | Policy: team-a-webapp"

# ── Step 6: Enable Kubernetes secrets engine ───────────────────
section "Step 6 — Enabling Kubernetes secrets engine"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault secrets enable kubernetes 2>/dev/null \
    && echo 'Kubernetes secrets engine enabled at kubernetes/' \
    || echo 'Kubernetes secrets engine already enabled — skipping'
"

# ── Step 7: Configure Kubernetes secrets engine (in-cluster) ───
section "Step 7 — Configuring Kubernetes secrets engine"

# Uses Vault pod's own service account token for in-cluster API access.
# The vault SA needs additional RBAC to create TokenRequests — see vault-rbac.yaml.
vault_exec "write kubernetes/config \
  kubernetes_host='https://kubernetes.default.svc.cluster.local:443'"

info "Kubernetes secrets engine configured (in-cluster)"

# ── Step 8: Kubernetes secrets engine role ─────────────────────
section "Step 8 — Creating Kubernetes secrets engine role 'team-a-webapp-sa'"

# This role allows Vault to dynamically generate short-lived SA tokens for
# the webapp-backend service account in the team-a namespace.
vault_exec "write kubernetes/roles/team-a-webapp-sa \
  allowed_kubernetes_namespaces=${APP_NS} \
  service_account_name=${SA_NAME} \
  token_default_ttl=1h \
  token_max_ttl=24h"

info "Kubernetes secrets engine role 'team-a-webapp-sa' created"

# ── Summary ────────────────────────────────────────────────────
section "Setup Complete"
echo ""
echo "  DB credentials (team-a viewable/writable)"
echo "    Vault path : secret/data/team-a/webapp/db"
echo "    Accessible : all team-a group members (via team-a-policy)"
echo ""
echo "  Vault Agent injection (used by backend pod)"
echo "    Auth method: auth/kubernetes/role/team-a-webapp"
echo "    Policy     : team-a-webapp"
echo "    Injected to: /vault/secrets/db.env inside the backend container"
echo ""
echo "  Kubernetes secrets engine (dynamic SA tokens)"
echo "    Mount      : kubernetes/"
echo "    Role       : kubernetes/roles/team-a-webapp-sa"
echo "    Usage      : vault read kubernetes/creds/team-a-webapp-sa"
echo ""
echo "Next steps:"
echo "  cd 06-application/team-a-webapp"
echo ""
echo "  # Install (first time):"
echo "  helm install team-a-webapp ./webapp-chart \\"
echo "    -f ./values.yaml \\"
echo "    --namespace team-a --create-namespace"
echo ""
echo "  # Upgrade (subsequent runs):"
echo "  helm upgrade team-a-webapp ./webapp-chart \\"
echo "    -f ./values.yaml \\"
echo "    --namespace team-a"
echo ""
  echo "  # Add DNS entry (one-time):"
  echo "  echo '127.0.0.1 team-a-webapp.kind.local' | sudo tee -a /etc/hosts"
