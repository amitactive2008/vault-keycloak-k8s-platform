#!/usr/bin/env bash
# ============================================================
# vault-setup.sh — Vault + K8s bootstrap for team-b sample-react-app
#
# Mirrors 09-sample-react-app-react-and-nodejs/vault-setup.sh but for:
#   Namespace : team-b
#   Vault KV  : secret/data/team-b/sample-react-app/{api,client}
#   Policy    : team-b-sample-react-app
#   K8s role  : team-b-sample-react-app → SA sample-react-app-backend / team-b
#
# Usage:
#   cd 10-sample-react-app-team-b
#   chmod +x vault-setup.sh && ./vault-setup.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
KEYS_FILE="${PROJECT_ROOT}/02-vault/cluster-keys.json"

VAULT_NS="vault"
APP_NS="team-b"
SA_NAME="sample-react-app-backend"
VAULT_ACTIVE_ADDR="http://vault-active.vault.svc.cluster.local:8200"

MYSQL_ROOT_PASS="RootPasswordTeamB@2024!"
MYSQL_DATABASE="sample_app_db"
MYSQL_USER="appuser"
MYSQL_PASSWORD="AppUserTeamB@SecurePass2024!"
JWT_SECRET="team-b-sample-react-app-jwt-$(date +%s)"

ROOT_TOKEN=$(python3 -c "import json; print(json.load(open('${KEYS_FILE}'))['root_token'])")

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

vault_exec() { kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "export VAULT_ADDR=${VAULT_ACTIVE_ADDR} VAULT_TOKEN=${ROOT_TOKEN}; vault $*"; }

# ── Step 0: Prerequisites ──────────────────────────────────────────────────────
section "Step 0 — Prerequisites"
kubectl cluster-info &>/dev/null || { echo "No cluster"; exit 1; }
[ -f "$KEYS_FILE" ] || { echo "cluster-keys.json missing"; exit 1; }
info "Cluster: $(kubectl config current-context) | NS: $APP_NS"

# ── Step 1: Vault KV secrets ──────────────────────────────────────────────────
section "Step 1 — Writing team-b secrets to Vault KV"
vault_exec "secrets enable -path=secret kv-v2 2>/dev/null || true"

info "Writing → secret/data/team-b/sample-react-app/api"
vault_exec "kv put secret/team-b/sample-react-app/api \
  DB_HOST=mysql DB_PORT=3306 DB_USER=${MYSQL_USER} \
  DB_PASSWORD=${MYSQL_PASSWORD} DB_NAME=${MYSQL_DATABASE} \
  JWT_SECRET=${JWT_SECRET}"

info "Writing → secret/data/team-b/sample-react-app/client"
vault_exec "kv put secret/team-b/sample-react-app/client \
  REACT_APP_API_URL=https://sample-react-app-team-b.kind.local/api \
  REACT_APP_ENV=production"

# ── Step 2: Vault policy ──────────────────────────────────────────────────────
section "Step 2 — Creating Vault policy: team-b-sample-react-app"
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR} VAULT_TOKEN=${ROOT_TOKEN}
  cat > /tmp/team-b-sample-react-app.hcl << 'POLICY'
path \"secret/data/team-b/sample-react-app/*\" {
  capabilities = [\"read\"]
}
path \"secret/metadata/team-b/sample-react-app/*\" {
  capabilities = [\"read\", \"list\"]
}
POLICY
  vault policy write team-b-sample-react-app /tmp/team-b-sample-react-app.hcl
  rm /tmp/team-b-sample-react-app.hcl
"
info "Policy 'team-b-sample-react-app' created ✓"

# ── Step 3: Kubernetes auth ───────────────────────────────────────────────────
section "Step 3 — Kubernetes auth setup"
vault_exec "auth enable kubernetes 2>/dev/null || true"

K8S_CA=$(kubectl exec -n "$VAULT_NS" vault-0 -- cat /var/run/secrets/kubernetes.io/serviceaccount/ca.crt)
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR} VAULT_TOKEN=${ROOT_TOKEN}
  vault write auth/kubernetes/config \
    kubernetes_host='https://kubernetes.default.svc.cluster.local:443' \
    kubernetes_ca_cert='${K8S_CA}'
"

vault_exec "write auth/kubernetes/role/team-b-sample-react-app \
  bound_service_account_names=${SA_NAME} \
  bound_service_account_namespaces=${APP_NS} \
  policies=team-b-sample-react-app \
  ttl=1h"
info "K8s auth role 'team-b-sample-react-app' ✓"

# ── Step 4: K8s MySQL Secret ──────────────────────────────────────────────────
section "Step 4 — Creating MySQL bootstrap Secret in $APP_NS"
kubectl create namespace "$APP_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create secret generic sample-react-app-mysql \
  --namespace "$APP_NS" \
  --from-literal=MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASS}" \
  --from-literal=MYSQL_DATABASE="${MYSQL_DATABASE}" \
  --from-literal=MYSQL_USER="${MYSQL_USER}" \
  --from-literal=MYSQL_PASSWORD="${MYSQL_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
info "Secret 'sample-react-app-mysql' in $APP_NS ✓"

# ── Step 5: ServiceAccount ────────────────────────────────────────────────────
section "Step 5 — Applying ServiceAccount"
kubectl apply -f "${SCRIPT_DIR}/kubernetes/rbac.yaml"
info "ServiceAccount '${SA_NAME}' in $APP_NS ✓"

# ── Step 6: CoreDNS ───────────────────────────────────────────────────────────
section "Step 6 — Adding sample-react-app-team-b.kind.local to CoreDNS"
GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=native-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
  kubectl get svc -n envoy-gateway-system --field-selector spec.type=LoadBalancer \
  -o jsonpath='{.items[0].metadata.name}')
GW_IP=$(kubectl get svc -n envoy-gateway-system "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
info "Envoy Gateway ClusterIP: ${GW_IP}"

CURRENT=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null)
if echo "$CURRENT" | grep -q "sample-react-app-team-b.kind.local"; then
  warn "CoreDNS already has sample-react-app-team-b.kind.local — skipping"
else
  python3 - << PYEOF
import subprocess, sys

gw_ip = "${GW_IP}"
hosts = [
    "vault.kind.local", "keycloak.kind.local", "grafana.kind.local",
    "prometheus.kind.local", "alertmanager.kind.local", "blackbox-exporter.kind.local",
    "team-a-webapp.kind.local", "sample.kind.local", "jenkins.kind.local",
    "sonarqube.kind.local", "sample-react-app.kind.local",
    "sample-react-app-team-b.kind.local",
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
        health {{ lameduck 5s }}
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
        forward . /etc/resolv.conf {{ max_concurrent 1000 }}
        cache 30
        loop
        reload
        loadbalance
    }}
"""
r = subprocess.run(["kubectl","apply","-f","-"], input=configmap.encode(), capture_output=True)
print(r.stdout.decode().strip())
if r.returncode != 0:
    print(r.stderr.decode(), file=sys.stderr); sys.exit(1)
PYEOF
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s
  info "CoreDNS updated ✓"
fi

# ── Done ─────────────────────────────────────────────────────────────────────
section "Vault Setup Complete — team-b!"
cat << EOF

╔════════════════════════════════════════════════════════════════╗
║  team-b sample-react-app Vault Setup Summary                  ║
╠════════════════════════════════════════════════════════════════╣
║  Secrets:  secret/data/team-b/sample-react-app/{api,client}  ║
║  Policy:   team-b-sample-react-app                            ║
║  K8s Role: team-b-sample-react-app → SA sample-react-app-    ║
║             backend / team-b namespace                        ║
║  MySQL:    sample-react-app-mysql Secret in team-b            ║
╠════════════════════════════════════════════════════════════════╣
║  Next steps:                                                   ║
║   1. sudo sh -c 'echo "127.0.0.1 sample-react-app-team-b.kind.local" >> /etc/hosts'
║   2. Run Jenkins CI: team-b/sample-react-app/{api,client}/ci  ║
║   3. Access: https://sample-react-app-team-b.kind.local       ║
╚════════════════════════════════════════════════════════════════╝
EOF
