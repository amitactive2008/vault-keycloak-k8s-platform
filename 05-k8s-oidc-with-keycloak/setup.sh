#!/usr/bin/env bash
# ============================================================
# setup.sh — Kubernetes API server OIDC → Keycloak kind realm
#
# What this does:
#   1. Extracts the wildcard *.kind.local CA cert from the cert-manager
#      secret (kind-local-ca-secret) and copies it into the control-plane
#      PKI directory so kube-apiserver can verify Keycloak's TLS cert.
#      Also saves a local copy as keycloak-local-ca.crt for kubelogin.
#   2. Adds keycloak.kind.local → Envoy Gateway ClusterIP to the
#      control-plane /etc/hosts so kube-apiserver reaches Keycloak
#      over HTTPS (TLS terminated by the Envoy Gateway).
#   3. Creates a public OIDC client "kubernetes" in the Keycloak
#      kind realm with a groups claim mapper (flat names, no slash).
#   4. Patches /etc/kubernetes/manifests/kube-apiserver.yaml inside
#      the vault-control-plane container to enable OIDC auth.
#      kubelet detects the change and restarts the API server.
#   5. Waits for the API server to come back healthy.
#   6. Applies RBAC (namespaces + role-bindings).
#   7. Generates kubeconfig-oidc.yaml with devops/team-a/team-b contexts.
#
# Access matrix after setup:
#   devops  → cluster-admin  (all namespaces, all resources)
#   team-a  → admin          (team-a namespace only)
#   team-b  → admin          (team-b namespace only)
#
# Usage:
#   cd 05-k8s-oidc-with-keycloak/
#   chmod +x setup.sh
#   ./setup.sh
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────
KC_NS="keycloak"
KC_REALM="kind"
KC_ADMIN_PASS="Admin@Keycloak2024!"
KIND_CONTROL_PLANE="vault-control-plane"
OIDC_CLIENT_ID="kubernetes"
OIDC_ISSUER="https://keycloak.kind.local/realms/${KC_REALM}"

# cert-manager CA secret — stores the CA that signs the *.kind.local wildcard cert.
# kube-apiserver needs this CA to verify https://keycloak.kind.local.
# Extracted at runtime from the Kubernetes secret; no file path dependency.
_CM_CA_SECRET="kind-local-ca-secret"
_CM_NS="cert-manager"
CA_CERT="/tmp/kind-local-ca-k8soidc.crt"

# Path inside the control-plane container (mounted into kube-apiserver pod)
APISERVER_CA_FILE="/etc/kubernetes/pki/kind.localCA.crt"

# ── Helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# ── Step 0: Prerequisites ─────────────────────────────────────
section "Step 0 — Prerequisites"
for cmd in kubectl podman python3; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
  info "$cmd → $(command -v "$cmd")"
done
kubectl cluster-info &>/dev/null || { error "Cluster not reachable"; exit 1; }
info "Cluster  : $(kubectl config current-context)"
info "OIDC     : $OIDC_ISSUER"

# ── Step 1: Extract CA from cert-manager and copy to control-plane PKI ────────
# cert-manager stores the root CA that signed the *.kind.local wildcard cert in the
# kind-local-ca-secret (cert-manager namespace). kube-apiserver needs this CA to
# verify Keycloak's HTTPS cert via --oidc-ca-file. The same cert is saved locally
# for kubelogin to verify the Keycloak HTTPS connection from the developer's machine.
section "Step 1 — Extracting wildcard CA from cert-manager and copying to control-plane PKI"

info "Extracting CA cert from cert-manager secret ${_CM_NS}/${_CM_CA_SECRET}..."
if ! kubectl get secret "${_CM_CA_SECRET}" -n "${_CM_NS}" &>/dev/null; then
  error "cert-manager CA secret '${_CM_CA_SECRET}' not found in namespace '${_CM_NS}'"
  error "Ensure cert-manager is installed and 01-cloud-provider-kind-setup-with-gw-api"
  error "setup is complete (kubectl apply -f cert-manager.yaml)."
  exit 1
fi
kubectl get secret "${_CM_CA_SECRET}" -n "${_CM_NS}" \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > "${CA_CERT}"
info "CA cert extracted → ${CA_CERT} ✓"

podman cp "${CA_CERT}" "${KIND_CONTROL_PLANE}:${APISERVER_CA_FILE}"
info "CA cert copied to control-plane: ${APISERVER_CA_FILE} ✓"

# Save local copy — referenced by kubeconfig-oidc.yaml for kubelogin
cp "${CA_CERT}" "${SCRIPT_DIR}/keycloak-local-ca.crt"
info "CA cert saved to ${SCRIPT_DIR}/keycloak-local-ca.crt ✓"

# ── Step 2: keycloak.kind.local → control-plane /etc/hosts ────────
# The kube-apiserver static pod cannot use CoreDNS — it reads /etc/hosts
# from the control-plane container. We add keycloak.kind.local pointing
# at the Envoy Gateway ClusterIP, which terminates TLS for *.kind.local
# and proxies to the Keycloak pod.
section "Step 2 — Pointing keycloak.kind.local → Envoy Gateway on control-plane"

GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=native-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$GW_SVC" ]; then
  GW_SVC=$(kubectl get svc -n envoy-gateway-system \
    --field-selector spec.type=LoadBalancer \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
GW_IP=$(kubectl get svc -n envoy-gateway-system "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
info "Envoy Gateway ClusterIP: $GW_IP"

CURRENT_ENTRY=$(podman exec "$KIND_CONTROL_PLANE" \
  grep "keycloak.kind.local" /etc/hosts 2>/dev/null || echo "")

if echo "$CURRENT_ENTRY" | grep -q "^${GW_IP}"; then
  warn "keycloak.kind.local already → ${GW_IP} in control-plane /etc/hosts — skipping"
else
  podman exec "$KIND_CONTROL_PLANE" python3 -c "
import re
with open('/etc/hosts', 'r') as f:
    content = f.read()
content = re.sub(r'.*keycloak\.kind\.local.*\n?', '', content)
content += '${GW_IP} keycloak.kind.local\n'
with open('/etc/hosts', 'w') as f:
    f.write(content)
"
  info "Set: ${GW_IP} keycloak.kind.local"
fi

RESOLVED=$(podman exec "$KIND_CONTROL_PLANE" \
  sh -c "getent hosts keycloak.kind.local 2>/dev/null || echo FAILED")
if echo "$RESOLVED" | grep -q "$GW_IP"; then
  info "DNS check: keycloak.kind.local → $GW_IP ✓"
else
  warn "DNS check inconclusive ($RESOLVED) — proceeding"
fi

# Verify OIDC discovery endpoint returns https:// issuer
ISSUER_FROM_DISCO=$(podman exec "$KIND_CONTROL_PLANE" sh -c \
  "curl -sf --cacert ${APISERVER_CA_FILE} --max-time 10 \
  https://keycloak.kind.local/realms/${KC_REALM}/.well-known/openid-configuration \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)[\"issuer\"])'" \
  2>/dev/null || echo "FAILED")
if [ "$ISSUER_FROM_DISCO" = "$OIDC_ISSUER" ]; then
  info "OIDC discovery issuer: $ISSUER_FROM_DISCO ✓"
else
  error "OIDC discovery issuer mismatch: got '$ISSUER_FROM_DISCO', expected '$OIDC_ISSUER'"
  error "Check Keycloak / Envoy Gateway / TLS configuration"
  exit 1
fi

# ── Step 3: Keycloak 'kubernetes' OIDC client ─────────────────
# Public client (no secret) — users authenticate in the browser or via
# kubelogin.  Groups mapper uses full.path=false so claim values are
# plain "devops", "team-a", "team-b" (matches the RBAC subject names).
section "Step 3 — Creating Keycloak OIDC client 'kubernetes'"

KC_POD=$(kubectl get pod -n "$KC_NS" -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')

kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "$KC_ADMIN_PASS"

# Idempotent check
CLIENT_EXISTS=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
  --fields clientId 2>/dev/null | grep -c '"kubernetes"' || true)

if [ "$CLIENT_EXISTS" -gt 0 ]; then
  warn "Keycloak client 'kubernetes' already exists — skipping creation"
else
  info "Creating public OIDC client 'kubernetes'..."
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh create clients -r "$KC_REALM" \
    -s clientId="$OIDC_CLIENT_ID" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=true \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s "redirectUris=[\"http://localhost:8000\",\"http://localhost:8000/*\"]" \
    -s "webOrigins=[\"http://localhost:8000\"]"
  info "Client 'kubernetes' created."
fi

# Get client UUID
CLIENT_UUID=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
  --fields id,clientId 2>/dev/null \
  | grep -B1 '"kubernetes"' | grep '"id"' | head -1 | awk -F'"' '{print $4}')
info "Client UUID: $CLIENT_UUID"

# Groups claim mapper: full.path=false → "devops", "team-a", "team-b"
MAPPER_EXISTS=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get \
  "clients/${CLIENT_UUID}/protocol-mappers/models" \
  -r "$KC_REALM" 2>/dev/null | grep -c '"groups"' || true)

if [ "$MAPPER_EXISTS" -gt 0 ]; then
  warn "Groups mapper already exists on 'kubernetes' client — skipping"
else
  info "Adding groups claim mapper (full.path=false → plain group names)..."
  kubectl exec -n "$KC_NS" "$KC_POD" -- sh -c '
cat > /tmp/k8s-groups-mapper.json << EOF
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "full.path": "false",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "claim.name": "groups",
    "multivalued": "true"
  }
}
EOF
'
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh create \
    "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$KC_REALM" -f /tmp/k8s-groups-mapper.json
  kubectl exec -n "$KC_NS" "$KC_POD" -- rm -f /tmp/k8s-groups-mapper.json
  info "Groups mapper added."
fi

# Audience mapper: Kubernetes 1.30+ validates aud == oidc-client-id.
# Keycloak 20+ does NOT include aud by default — must add explicit mapper.
AUD_MAPPER_EXISTS=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get \
  "clients/${CLIENT_UUID}/protocol-mappers/models" \
  -r "$KC_REALM" 2>/dev/null | grep -c '"kubernetes-audience"' || true)

if [ "$AUD_MAPPER_EXISTS" -gt 0 ]; then
  warn "Audience mapper already exists on 'kubernetes' client — skipping"
else
  info "Adding audience mapper (aud=kubernetes — required by kube-apiserver)..."
  kubectl exec -n "$KC_NS" "$KC_POD" -- sh -c 'cat > /tmp/k8s-aud-mapper.json << '"'"'EOF'"'"'
{
  "name": "kubernetes-audience",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-audience-mapper",
  "config": {
    "included.client.audience": "kubernetes",
    "id.token.claim": "true",
    "access.token.claim": "true"
  }
}
EOF'
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh create \
    "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$KC_REALM" -f /tmp/k8s-aud-mapper.json
  kubectl exec -n "$KC_NS" "$KC_POD" -- rm -f /tmp/k8s-aud-mapper.json
  info "Audience mapper added."
fi

# ── Step 4: Patch kube-apiserver static pod ──────────────────
# The API server must be restarted to pick up OIDC configuration.
# kubelet automatically restarts the static pod when the manifest changes.
# NOTE: kubectl will be unavailable for ~30-60 s during the restart.
section "Step 4 — Patching kube-apiserver OIDC flags (HTTPS)"

APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

if podman exec "$KIND_CONTROL_PLANE" grep -q "oidc-issuer-url" "$APISERVER_MANIFEST" 2>/dev/null; then
  warn "OIDC flags already present in kube-apiserver manifest — skipping"
else
  info "Copying kube-apiserver manifest from control-plane..."
  podman cp "${KIND_CONTROL_PLANE}:${APISERVER_MANIFEST}" /private/tmp/kube-apiserver-original.yaml

  info "Adding OIDC flags (Python patch on host)..."
  python3 << PYEOF
import re

with open('/private/tmp/kube-apiserver-original.yaml') as f:
    content = f.read()

if '--oidc-issuer-url' in content:
    print('Already contains OIDC flags — nothing to do')
    exit(0)

oidc_flags = [
    '    - --oidc-issuer-url=https://keycloak.kind.local/realms/kind',
    '    - --oidc-client-id=kubernetes',
    '    - --oidc-username-claim=preferred_username',
    '    - --oidc-groups-claim=groups',
    '    - --oidc-ca-file=${APISERVER_CA_FILE}',
]

lines = content.split('\n')

# Find the last "    - --flag" line in the command list
last_cmd_idx = -1
for i, line in enumerate(lines):
    if re.match(r'^    - --', line):
        last_cmd_idx = i

if last_cmd_idx == -1:
    print('ERROR: could not locate command flags in manifest')
    exit(1)

new_lines = lines[:last_cmd_idx + 1] + oidc_flags + lines[last_cmd_idx + 1:]

with open('/private/tmp/kube-apiserver-patched.yaml', 'w') as f:
    f.write('\n'.join(new_lines))

print('Manifest patched — OIDC flags appended to command list')
PYEOF

  info "Copying patched manifest back to control-plane..."
  podman cp /private/tmp/kube-apiserver-patched.yaml \
    "${KIND_CONTROL_PLANE}:${APISERVER_MANIFEST}"

  info "Manifest updated. kubelet will restart kube-apiserver automatically."
fi

# ── Step 5: Wait for API server to recover ───────────────────
section "Step 5 — Waiting for API server to restart (~30-60 s)"
info "The API server restarts when its static pod manifest changes..."
sleep 10  # Give kubelet time to detect the change
MAX_WAIT=120
WAITED=0
until kubectl cluster-info &>/dev/null 2>&1; do
  if [ $WAITED -ge $MAX_WAIT ]; then
    error "API server did not recover after ${MAX_WAIT}s"
    error "Check: podman exec ${KIND_CONTROL_PLANE} crictl ps | grep apiserver"
    exit 1
  fi
  printf "."
  sleep 5
  WAITED=$((WAITED + 5))
done
echo ""
info "API server is back ✓ (waited ${WAITED}s)"

# ── Step 6: Apply RBAC ───────────────────────────────────────
section "Step 6 — Applying RBAC (namespaces + role-bindings)"
kubectl apply -f "${SCRIPT_DIR}/rbac/devops-cluster-admin.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/team-a.yaml"
kubectl apply -f "${SCRIPT_DIR}/rbac/team-b.yaml"
info "RBAC applied ✓"

# ── Step 7: Verify ───────────────────────────────────────────
section "Step 7 — Verifying OIDC configuration"
info "Checking kube-apiserver flags..."
podman exec "$KIND_CONTROL_PLANE" grep "oidc" "$APISERVER_MANIFEST" | head -6

info "Checking namespaces..."
kubectl get ns team-a team-b

info "Checking ClusterRoleBinding (devops)..."
kubectl get clusterrolebinding keycloak-devops-cluster-admin

info "Checking RoleBindings..."
kubectl get rolebinding -n team-a keycloak-team-a-admin
kubectl get rolebinding -n team-b keycloak-team-b-admin

# ── Done ─────────────────────────────────────────────────────
section "Setup complete!"

cat << 'EOF'

╔══════════════════════════════════════════════════════════════════╗
║      Kubernetes SSO via Keycloak — Access Matrix                ║
╠══════════════════════════════════════════════════════════════════╣
║  Group   Cluster Access      Namespace Access                   ║
║  ─────── ─────────────────── ────────────────────────────────   ║
║  devops  cluster-admin       ALL namespaces (full admin)        ║
║  team-a  —                   team-a namespace only (admin)      ║
║  team-b  —                   team-b namespace only (admin)      ║
╠══════════════════════════════════════════════════════════════════╣
║  Keycloak users  (password: password)                           ║
║   devops-user-1, devops-user-2  → group: devops                 ║
║   team-a-user-1, team-a-user-2  → group: team-a                 ║
║   team-b-user-1, team-b-user-2  → group: team-b                 ║
╚══════════════════════════════════════════════════════════════════╝

╔══════════════════════════════════════════════════════════════════╗
║  kubectl Setup for OIDC Login                                   ║
╠══════════════════════════════════════════════════════════════════╣
║  1. Install kubelogin:                                          ║
║     brew install int128/kubelogin/kubelogin                     ║
║                                                                 ║
║  2. Add to /etc/hosts (if not already):                         ║
║     sudo sh -c 'echo "127.0.0.1  keycloak.kind.local" >> /etc/hosts' ║
║                                                                 ║
║  3. Trust the self-signed CA cert (browser + kubelogin):        ║
║     # macOS: add to system keychain                             ║
║     sudo security add-trusted-cert -d -r trustRoot \           ║
║       -k /Library/Keychains/System.keychain \                  ║
║       05-k8s-oidc-with-keycloak/keycloak-local-ca.crt          ║
║                                                                 ║
║  4. Use kubeconfig-oidc.yaml:                                   ║
║     export KUBECONFIG=~/.kube/config:05-k8s-oidc-with-keycloak/kubeconfig-oidc.yaml ║
║     kubectl config use-context team-a                          ║
║     kubectl get pods -n team-a        # ✓ allowed               ║
║     kubectl get pods -n team-b        # ✗ forbidden             ║
║     kubectl config use-context devops                          ║
║     kubectl get nodes                 # ✓ cluster-admin         ║
╚══════════════════════════════════════════════════════════════════╝

EOF

echo "Kubeconfig snippet file: ${SCRIPT_DIR}/kubeconfig-oidc.yaml"

# ── Generate kubeconfig snippet ──────────────────────────────
CLUSTER_SERVER=$(kubectl config view \
  --minify -o jsonpath='{.clusters[0].cluster.server}')
CLUSTER_CA=$(kubectl config view \
  --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')

cat > "${SCRIPT_DIR}/kubeconfig-oidc.yaml" << KCEOF
# ============================================================
# OIDC kubeconfig snippet for kind-vault cluster
# Usage:
#   export KUBECONFIG=~/.kube/config:${SCRIPT_DIR}/kubeconfig-oidc.yaml
#   kubectl config use-context team-a
#
# First run: browser opens to https://keycloak.kind.local — login with
#   team-a-user-1 / password   (or devops-user-1 for cluster-admin)
#
# TLS: kubelogin verifies the cert using keycloak-local-ca.crt.
#      Trust the CA in macOS for browser too:
#   sudo security add-trusted-cert -d -r trustRoot \\
#     -k /Library/Keychains/System.keychain \\
#     ${SCRIPT_DIR}/keycloak-local-ca.crt
# ============================================================
apiVersion: v1
kind: Config
clusters:
- name: kind-vault
  cluster:
    server: ${CLUSTER_SERVER}
    certificate-authority-data: ${CLUSTER_CA}
contexts:
- name: devops
  context:
    cluster: kind-vault
    user: devops-oidc
    namespace: default
- name: team-a
  context:
    cluster: kind-vault
    user: team-a-oidc
    namespace: team-a
- name: team-b
  context:
    cluster: kind-vault
    user: team-b-oidc
    namespace: team-b
users:
- name: devops-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      env:
      - name: GODEBUG
        value: netdns=go
      args:
        - oidc-login
        - get-token
        - --oidc-issuer-url=https://keycloak.kind.local/realms/kind
        - --oidc-client-id=kubernetes
        - --oidc-auth-request-extra-params=prompt=login
        - --certificate-authority=${SCRIPT_DIR}/keycloak-local-ca.crt
- name: team-a-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      env:
      - name: GODEBUG
        value: netdns=go
      args:
        - oidc-login
        - get-token
        - --oidc-issuer-url=https://keycloak.kind.local/realms/kind
        - --oidc-client-id=kubernetes
        - --oidc-auth-request-extra-params=prompt=login
        - --certificate-authority=${SCRIPT_DIR}/keycloak-local-ca.crt
- name: team-b-oidc
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: kubectl
      env:
      - name: GODEBUG
        value: netdns=go
      args:
        - oidc-login
        - get-token
        - --oidc-issuer-url=https://keycloak.kind.local/realms/kind
        - --oidc-client-id=kubernetes
        - --oidc-auth-request-extra-params=prompt=login
        - --certificate-authority=${SCRIPT_DIR}/keycloak-local-ca.crt
KCEOF

echo ""
echo "[INFO]  kubeconfig-oidc.yaml written ✓"
echo "[INFO]  To use: export KUBECONFIG=~/.kube/config:${SCRIPT_DIR}/kubeconfig-oidc.yaml"
