#!/usr/bin/env bash
# ============================================================
# install.sh — Production-grade Keycloak on local kind cluster
#
# What this script does:
#   1. Validates prerequisites (kubectl)
#   2. Creates the keycloak namespace
#   3. Creates a ConfigMap with the "kind" realm definition
#      (groups: devops / team-a / team-b and 6 users)
#   4. Deploys PostgreSQL 17 (official image, StatefulSet + PVC)
#   5. Deploys Keycloak 26.3.3 (official quay.io image)
#      - production start mode with --import-realm
#      - nginx Ingress at http://keycloak.local
#   6. Waits for all pods to be ready and prints access info
#
# Images used (no Docker Hub auth required):
#   - quay.io/keycloak/keycloak:26.3.3
#   - docker.io/library/postgres:17
#
# Usage:
#   cd keycloak/
#   chmod +x install.sh
#   ./install.sh
#
# Uninstall:
#   kubectl delete ns keycloak
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="keycloak"
ADMIN_PASS="Admin@Keycloak2024!"

# ── ANSI helpers ──────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# ── Step 0: Prerequisites ────────────────────────────────────
section "Step 0 — Checking prerequisites"
if ! command -v kubectl &>/dev/null; then
  error "kubectl is not installed or not in PATH."
  exit 1
fi
info "kubectl → $(command -v kubectl)"

if ! kubectl cluster-info &>/dev/null 2>&1; then
  error "No reachable Kubernetes cluster found."
  error "Start your kind cluster first:"
  error "  kind create cluster --config ../deploy/kind.yaml"
  exit 1
fi
info "Cluster: $(kubectl config current-context)"

# ── Step 1: Namespace ────────────────────────────────────────
section "Step 1 — Creating namespace '$NAMESPACE'"
kubectl apply -f "$SCRIPT_DIR/namespace.yaml"

# ── Step 2: Realm ConfigMap ──────────────────────────────────
section "Step 2 — Creating realm ConfigMap (keycloak-realm-import)"
# Keycloak mounts this at /opt/keycloak/data/import/ and picks it up
# on startup via the --import-realm flag.
kubectl create configmap keycloak-realm-import \
  --from-file=kind-realm.json="$SCRIPT_DIR/kind-realm.json" \
  --namespace "$NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -
info "ConfigMap 'keycloak-realm-import' applied."

# ── Step 3: PostgreSQL ───────────────────────────────────────
section "Step 3 — Deploying PostgreSQL 17"
kubectl apply -f "$SCRIPT_DIR/postgres.yaml"

info "Waiting for PostgreSQL StatefulSet to be ready..."
kubectl rollout status statefulset/keycloak-postgresql \
  --namespace "$NAMESPACE" \
  --timeout=120s

# ── Step 4: Keycloak ─────────────────────────────────────────
section "Step 4 — Deploying Keycloak 26.3.3 (this takes ~3–5 min)"
info "Image: quay.io/keycloak/keycloak:26.3.3"
kubectl apply -f "$SCRIPT_DIR/keycloak.yaml"

info "Waiting for Keycloak Deployment to be ready (DB init + realm import)..."
kubectl rollout status deployment/keycloak \
  --namespace "$NAMESPACE" \
  --timeout=600s

kubectl wait pod \
  --selector "app=keycloak" \
  --for condition=Ready \
  --namespace "$NAMESPACE" \
  --timeout=600s

# ── Step 5: Ingress ──────────────────────────────────────────
section "Step 5 — Applying Ingress (keycloak.local)"
kubectl apply -f "$SCRIPT_DIR/ingress.yaml"

# ── Step 6: Done ─────────────────────────────────────────────
section "Step 6 — Deployment complete"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║             KEYCLOAK — Access Information                ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║                                                          ║"
echo "║  1. Add to /etc/hosts (run once, requires sudo):        ║"
echo "║     sudo sh -c 'echo \"127.0.0.1  keycloak.local\"        ║"
echo "║     >> /etc/hosts'                                      ║"
echo "║                                                          ║"
echo "║  2. Admin Console:  http://keycloak.local/admin         ║"
echo "║     Username : admin                                     ║"
echo "║     Password : $ADMIN_PASS               ║"
echo "║                                                          ║"
echo "║  3. Realm     :  kind                                    ║"
echo "║     Realm URL :  http://keycloak.local/realms/kind      ║"
echo "║                                                          ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Groups & Users  (password for all users: password)     ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Group: devops   → devops-user-1, devops-user-2         ║"
echo "║  Group: team-a   → team-a-user-1, team-a-user-2         ║"
echo "║  Group: team-b   → team-b-user-1, team-b-user-2         ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

# ── Helpful debugging commands ───────────────────────────────
info "Useful commands:"
echo "  # Check pod status"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "  # Stream Keycloak logs (realm import visible here)"
echo "  kubectl logs -n $NAMESPACE -l app=keycloak -f"
echo ""
echo "  # Check Ingress"
echo "  kubectl get ingress -n $NAMESPACE"
echo ""
echo "  # Uninstall everything"
echo "  kubectl delete ns $NAMESPACE"
