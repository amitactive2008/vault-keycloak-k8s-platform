#!/usr/bin/env bash
# ============================================================
# vault-setup.sh — Vault configuration for sample-react-app (team-a)
#
# What this does:
#   1. Writes DB credentials and JWT secret to Vault KV:
#        secret/data/team-a/sample-react-app/api   (API secrets)
#        secret/data/team-a/sample-react-app/client (client secrets)
#   2. Creates a Vault policy: team-a-sample-react-app
#        read-only access to secret/data/team-a/sample-react-app/*
#   3. Enables Kubernetes auth method (if not already enabled)
#   4. Creates K8s auth role 'team-a-sample-react-app':
#        bound to ServiceAccount sample-react-app-backend / namespace team-a
#   5. Creates K8s Secret 'sample-react-app-mysql' in team-a namespace
#        used by the MySQL StatefulSet for initial DB bootstrapping
#   6. Adds sample-react-app.kind.local to CoreDNS hosts block
#      so in-cluster pods (Vault Agent, Blackbox) can resolve it
#
# Usage:
#   cd 10-sample-app-react-and-nodejs
#   chmod +x vault-setup.sh
#   ./vault-setup.sh
#
# Requires: kubectl, python3
# Prerequisites:
#   - Steps 01-04 complete (Vault initialized + unsealed, Keycloak running)
#   - 02-vault/cluster-keys.json with root_token
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEYS_FILE="${PROJECT_ROOT}/02-vault/cluster-keys.json"

# ── Configuration ─────────────────────────────────────────────────────────────
VAULT_NS="vault"
APP_NS="team-a"
SA_NAME="sample-react-app-backend"
VAULT_ACTIVE_ADDR="http://vault-active.vault.svc.cluster.local:8200"

# Vault KV secret paths
API_SECRET_PATH="secret/data/team-a/sample-react-app/api"
CLIENT_SECRET_PATH="secret/data/team-a/sample-react-app/client"

# MySQL bootstrap credentials (stored in K8s Secret for MySQL init)
MYSQL_ROOT_PASS="RootPassword@2024!"
MYSQL_DATABASE="sample_app_db"
MYSQL_USER="appuser"
MYSQL_PASSWORD="AppUser@SecurePass2024!"

# App secrets written to Vault KV. Preserve the JWT signing secret on reruns so
# existing user sessions do not become invalid every time setup is reconciled.
JWT_SECRET=""

ROOT_TOKEN=$(python3 -c "
import json
with open('${KEYS_FILE}') as f:
    print(json.load(f)['root_token'])
")

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

vault_exec() {
  kubectl exec -n "$VAULT_NS" vault-0 -- \
    sh -c "export VAULT_ADDR=${VAULT_ACTIVE_ADDR} VAULT_TOKEN=${ROOT_TOKEN}; vault $*"
}

# ── Step 0: Prerequisites ─────────────────────────────────────────────────────
section "Step 0 — Prerequisites"
for cmd in kubectl python3; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
done
kubectl cluster-info &>/dev/null || { error "No cluster found"; exit 1; }
[ -f "$KEYS_FILE" ] || { error "cluster-keys.json not found at $KEYS_FILE"; exit 1; }
info "Cluster: $(kubectl config current-context)"
info "Vault NS: $VAULT_NS  |  App NS: $APP_NS"

# ── Step 1: Write secrets to Vault KV ────────────────────────────────────────
section "Step 1 — Writing secrets to Vault KV"

# Ensure KV v2 is enabled at secret/ (already done in step 04, but idempotent)
vault_exec "secrets enable -path=secret kv-v2 2>/dev/null \
  && echo 'KV v2 enabled at secret/' \
  || echo 'KV v2 already enabled'"

# Preserve an existing JWT secret when this idempotent script is rerun.
JWT_SECRET=$(vault_exec "kv get -field=JWT_SECRET secret/team-a/sample-react-app/api" \
  2>/dev/null || true)
if [ -z "$JWT_SECRET" ]; then
  JWT_SECRET="sample-react-app-jwt-secret-$(date +%s)"
fi

# API secrets: DB credentials + JWT secret
info "Writing API secrets → secret/data/team-a/sample-react-app/api"
vault_exec "kv put secret/team-a/sample-react-app/api \
  DB_HOST=mysql \
  DB_PORT=3306 \
  DB_USER=${MYSQL_USER} \
  DB_PASSWORD=${MYSQL_PASSWORD} \
  DB_NAME=${MYSQL_DATABASE} \
  JWT_SECRET=${JWT_SECRET}"
info "API secrets written ✓"

# Client secrets: API endpoint (stable K8s service name + external URL for reference)
info "Writing client secrets → secret/data/team-a/sample-react-app/client"
vault_exec "kv put secret/team-a/sample-react-app/client \
  REACT_APP_API_URL=https://sample-react-app.kind.local/api \
  REACT_APP_ENV=production"
info "Client secrets written ✓"

# ── Step 2: Vault policy for the app ─────────────────────────────────────────
section "Step 2 — Creating Vault policy: team-a-sample-react-app"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}

  cat > /tmp/team-a-sample-react-app.hcl << 'POLICY'
# team-a-sample-react-app policy
# Grants read-only access to secrets for the sample React + Node.js app.
# Bound to: sample-react-app-backend ServiceAccount in team-a namespace

# Read API secrets (DB credentials, JWT secret)
path \"secret/data/team-a/sample-react-app/*\" {
  capabilities = [\"read\"]
}

# Allow listing secret metadata (required by Vault Agent for lease management)
path \"secret/metadata/team-a/sample-react-app/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY

  vault policy write team-a-sample-react-app /tmp/team-a-sample-react-app.hcl
  rm /tmp/team-a-sample-react-app.hcl
"
info "Policy 'team-a-sample-react-app' written ✓"

# ── Step 3: Enable Kubernetes auth method ─────────────────────────────────────
section "Step 3 — Enabling Kubernetes auth method"

vault_exec "auth enable kubernetes 2>/dev/null \
  && echo 'Kubernetes auth enabled' \
  || echo 'Kubernetes auth already enabled'"

# ── Step 4: Configure Kubernetes auth ────────────────────────────────────────
section "Step 4 — Configuring Kubernetes auth method"

K8S_CA=$(kubectl exec -n "$VAULT_NS" vault-0 -- \
  cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc.cluster.local:443' \
    kubernetes_ca_cert='${K8S_CA}'
"
info "Kubernetes auth configured ✓"

# ── Step 5: Create K8s auth role ─────────────────────────────────────────────
section "Step 5 — Creating Kubernetes auth role: team-a-sample-react-app"

vault_exec "write auth/kubernetes/role/team-a-sample-react-app \
  bound_service_account_names=${SA_NAME} \
  bound_service_account_namespaces=${APP_NS} \
  policies=team-a-sample-react-app \
  ttl=1h"
info "Auth role 'team-a-sample-react-app' created ✓"
info "  ServiceAccount: ${SA_NAME} | Namespace: ${APP_NS} | TTL: 1h"

# ── Step 6: Create MySQL bootstrap Secret ────────────────────────────────────
section "Step 6 — Creating K8s Secret for MySQL bootstrap"

# This Secret is only used by the MySQL StatefulSet init.
# The API reads DB credentials from Vault, not from this Secret.
kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic sample-react-app-mysql \
  --namespace "$APP_NS" \
  --from-literal=MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASS}" \
  --from-literal=MYSQL_DATABASE="${MYSQL_DATABASE}" \
  --from-literal=MYSQL_USER="${MYSQL_USER}" \
  --from-literal=MYSQL_PASSWORD="${MYSQL_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
info "Secret 'sample-react-app-mysql' created in ${APP_NS} ✓"

# ── Step 7: Apply ServiceAccount ─────────────────────────────────────────────
section "Step 7 — Applying ServiceAccount for Vault Agent"

kubectl apply -f "${SCRIPT_DIR}/kubernetes/rbac.yaml"
info "ServiceAccount '${SA_NAME}' applied in ${APP_NS} ✓"

# ── Step 8: Update CoreDNS with sample-react-app.kind.local ──────────────────
section "Step 8 — Adding sample-react-app.kind.local to CoreDNS"

GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=native-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
[ -z "$GW_SVC" ] && GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  --field-selector spec.type=LoadBalancer \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
GW_IP=$(kubectl get svc -n envoy-gateway-system "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
info "Envoy Gateway ClusterIP: ${GW_IP}"

CURRENT_CORE=$(kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' 2>/dev/null)
if echo "$CURRENT_CORE" | grep -q "sample-react-app.kind.local"; then
  warn "CoreDNS already has sample-react-app.kind.local — skipping update"
else
  info "Adding sample-react-app.kind.local to CoreDNS..."
  python3 - << PYEOF
import subprocess, sys

gw_ip = "${GW_IP}"
hosts = [
    "vault.kind.local",
    "keycloak.kind.local",
    "grafana.kind.local",
    "prometheus.kind.local",
    "alertmanager.kind.local",
    "blackbox-exporter.kind.local",
    "team-a-webapp.kind.local",
    "sample.kind.local",
    "gitea.kind.local",
    "jenkins.kind.local",
    "jenkins-resources.kind.local",
    "sonarqube.kind.local",
    "sample-react-app.kind.local",
    "ai-bankapp.kind.local",
]
hosts_block = "\n".join(f"           {gw_ip} {h}" for h in hosts)

configmap = f"""apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {{
        errors
        health {{
           lameduck 5s
        }}
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {{
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }}
        hosts {{
{hosts_block}
           fallthrough
        }}
        prometheus :9153
        forward . /etc/resolv.conf {{
           max_concurrent 1000
        }}
        cache 30
        loop
        reload
        loadbalance
    }}
"""
r = subprocess.run(["kubectl","apply","-f","-"], input=configmap.encode(), capture_output=True)
if r.returncode != 0:
    print("ERROR:", r.stderr.decode(), file=sys.stderr); sys.exit(1)
print(r.stdout.decode().strip())
PYEOF
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s
  info "CoreDNS updated with sample-react-app.kind.local ✓"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
section "Vault Setup Complete!"

cat << EOF

╔════════════════════════════════════════════════════════════════════════╗
║        sample-react-app Vault Setup Summary                           ║
╠════════════════════════════════════════════════════════════════════════╣
║  Vault Secrets:                                                        ║
║   secret/data/team-a/sample-react-app/api   (DB + JWT credentials)   ║
║   secret/data/team-a/sample-react-app/client (frontend config)        ║
║                                                                        ║
║  Vault Policy:  team-a-sample-react-app (read above paths)            ║
║  K8s Auth Role: team-a-sample-react-app → SA sample-react-app-backend ║
║                                                                        ║
║  K8s Secret:   sample-react-app-mysql (team-a namespace, MySQL init)  ║
║  ServiceAccount: sample-react-app-backend (team-a namespace)          ║
╠════════════════════════════════════════════════════════════════════════╣
║  Next Steps:                                                           ║
║   1. Add to /etc/hosts:                                               ║
║       127.0.0.1 sample-react-app.kind.local                           ║
║   2. Run the Jenkins CI pipeline:                                     ║
║       team-a/sample-react-app/api/ci                                  ║
║       team-a/sample-react-app/client/ci                               ║
║   3. Or deploy directly (after images exist):                         ║
║       kubectl apply -f kubernetes/mysql/                              ║
║       kubectl apply -f kubernetes/api/                                ║
║       kubectl apply -f kubernetes/client/                             ║
║       kubectl apply -f kubernetes/httproute.yaml                      ║
║   4. Access the app:                                                   ║
║       https://sample-react-app.kind.local                             ║
╚════════════════════════════════════════════════════════════════════════╝

EOF
