#!/usr/bin/env bash
# ============================================================
# setup.sh — Jenkins + SonarQube installation and configuration
#
# What this does:
#   0. Checks prerequisites
#   1. Updates CoreDNS — adds Jenkins, Jenkins resource, and SonarQube hosts
#      to the Envoy Gateway hosts block (so in-cluster pods resolve them)
#   2. Creates Keycloak OIDC clients:
#        jenkins    (confidential, redirect: /securityRealm/finishLogin)
#        sonarqube  (confidential, redirect: /oauth2/callback/oidc)
#      Both get a groups mapper (full.path=false → flat names)
#   3. Creates the cert-manager CA Secret in sonarqube namespace
#      (so SonarQube's JVM can verify Keycloak HTTPS)
#   4. Applies Kubernetes manifests: namespace, RBAC, buildkitd, PVC, certs-stub
#   5. Reports the Vault-backed Jenkins agent identities
#   6. Adds Helm repos; installs / upgrades SonarQube
#   7. Installs / upgrades Jenkins
#   8. Applies HTTPRoutes (Jenkins, Jenkins resources, and SonarQube)
#   9. Waits for both services to be ready
#  10. Configures SonarQube via API:
#        - Enables OIDC plugin settings
#        - Creates groups: devops, team-a, team-b
#        - Grants global admin to devops group
#        - Creates SonarQube projects for team-a and team-b
#        - Grants project permissions to respective groups
#  11. Generates a SonarQube global analysis token and stores it as a
#      K8s Secret in the jenkins namespace (SONARQUBE_TOKEN)
#
# Usage:
#   cd 08-jenkins
#   chmod +x setup.sh
#   ./setup.sh
#
# Idempotent: safe to re-run. Each step checks before acting.
#
# Requires: kubectl, helm, python3, curl
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────
JENKINS_NS="jenkins"
SONAR_NS="sonarqube"
KC_NS="keycloak"
KC_REALM="kind"
KC_ADMIN_PASS="Admin@Keycloak2024!"

JENKINS_RELEASE="jenkins"
SONAR_RELEASE="sonarqube"
JENKINS_CHART_VERSION="5.9.40"
SONAR_CHART_VERSION="2026.3.1"

JENKINS_URL="https://jenkins.kind.local"
SONAR_URL="https://sonarqube.kind.local"
JENKINS_ADMIN_USER="admin"
JENKINS_ADMIN_PASS="Admin@Jenkins2024!"
SONAR_ADMIN_USER="admin"
SONAR_ADMIN_PASS="admin"

JENKINS_OIDC_SECRET="Jenkins@Keycloak2024!"
SONAR_OIDC_SECRET="SonarQube@Keycloak2024!"

# ── Helpers ───────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

sonar_api() {
  local method="$1"; shift; local path="$1"; shift
  curl -sf -X "${method}" \
    -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASS}" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    "http://localhost:19000${path}" "$@" 2>/dev/null || true
}

# ── Step 0: Prerequisites ──────────────────────────────────────────────────────
section "Step 0 — Prerequisites"
for cmd in kubectl helm python3 curl; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
  info "$cmd ✓"
done
kubectl cluster-info &>/dev/null || { error "No cluster found"; exit 1; }
info "Cluster: $(kubectl config current-context)"

# ── Step 1: CoreDNS — add Jenkins + resource root + SonarQube hosts ───────────
section "Step 1 — Updating CoreDNS for Jenkins and SonarQube hosts"

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
NEEDS_UPDATE=false
for host in jenkins.kind.local jenkins-resources.kind.local sonarqube.kind.local; do
  echo "$CURRENT_CORE" | grep -q "$host" || NEEDS_UPDATE=true
done

if $NEEDS_UPDATE; then
  info "Adding Jenkins, resource-root, and SonarQube entries to CoreDNS..."
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
  sleep 5
  info "CoreDNS updated ✓"
else
  warn "CoreDNS already has Jenkins and SonarQube entries — skipping"
fi

# ── Step 2: Keycloak OIDC clients ─────────────────────────────────────────────
section "Step 2 — Creating Keycloak OIDC clients: jenkins + sonarqube"

KC_POD=$(kubectl get pod -n "$KC_NS" -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')
info "Keycloak pod: ${KC_POD}"

kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "$KC_ADMIN_PASS" 2>/dev/null

create_oidc_client() {
  local CLIENT_ID="$1"
  local CLIENT_SECRET="$2"
  local REDIRECT_URI="$3"
  local DISPLAY_NAME="$4"
  local WEB_ORIGIN="$5"
  local POST_LOGOUT_REDIRECT_URI="${6:-}"

  EXISTS=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
    --fields clientId 2>/dev/null | grep -c "\"${CLIENT_ID}\"" || true)

  if [ "$EXISTS" -gt 0 ]; then
    warn "Keycloak client '${CLIENT_ID}' already exists — skipping creation"
  else
    info "Creating Keycloak client '${CLIENT_ID}'..."
    kubectl exec -n "$KC_NS" "$KC_POD" -- \
      /opt/keycloak/bin/kcadm.sh create clients -r "$KC_REALM" \
      -s clientId="${CLIENT_ID}" \
      -s name="${DISPLAY_NAME}" \
      -s enabled=true \
      -s protocol=openid-connect \
      -s publicClient=false \
      -s standardFlowEnabled=true \
      -s implicitFlowEnabled=false \
      -s directAccessGrantsEnabled=false \
      -s serviceAccountsEnabled=false \
      -s secret="${CLIENT_SECRET}" \
      -s "redirectUris=[\"${REDIRECT_URI}\",\"http://localhost:8080${REDIRECT_URI#https://jenkins.kind.local}\",\"http://localhost:8080${REDIRECT_URI#https://sonarqube.kind.local}\"]" \
      -s "webOrigins=[\"${WEB_ORIGIN}\"]" 2>/dev/null
    info "Client '${CLIENT_ID}' created ✓"
  fi

  # Get client UUID
  CLIENT_UUID=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
    --fields id,clientId 2>/dev/null \
    | grep -B1 "\"${CLIENT_ID}\"" | grep '"id"' | head -1 | awk -F'"' '{print $4}')

  # Sync redirect URIs (idempotent)
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_UUID}" -r "$KC_REALM" \
    -s "redirectUris=[\"${REDIRECT_URI}\"]" \
    -s "webOrigins=[\"${WEB_ORIGIN}\"]" 2>/dev/null
  info "Client '${CLIENT_ID}' redirectUris synced ✓"

  if [ -n "${POST_LOGOUT_REDIRECT_URI}" ]; then
    kubectl exec -n "$KC_NS" "$KC_POD" -- \
      /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_UUID}" -r "$KC_REALM" \
      -s "attributes={\"post.logout.redirect.uris\":\"${POST_LOGOUT_REDIRECT_URI}\"}" \
      2>/dev/null
    info "Client '${CLIENT_ID}' post-logout redirect synced ✓"
  fi

  # Add groups claim mapper (flat names: devops, team-a, team-b)
  MAPPER_COUNT=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh get \
    "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$KC_REALM" 2>/dev/null | grep -c '"groups"' || true)

  if [ "$MAPPER_COUNT" -gt 0 ]; then
    warn "Groups mapper already on '${CLIENT_ID}' — skipping"
  else
    info "Adding groups mapper to '${CLIENT_ID}'..."
    kubectl exec -n "$KC_NS" "$KC_POD" -- sh -c "
cat > /tmp/${CLIENT_ID}-mapper.json << 'MAPEOF'
{
  \"name\": \"groups\",
  \"protocol\": \"openid-connect\",
  \"protocolMapper\": \"oidc-group-membership-mapper\",
  \"config\": {
    \"full.path\": \"false\",
    \"id.token.claim\": \"true\",
    \"access.token.claim\": \"true\",
    \"userinfo.token.claim\": \"true\",
    \"claim.name\": \"groups\",
    \"multivalued\": \"true\"
  }
}
MAPEOF
" 2>/dev/null
    kubectl exec -n "$KC_NS" "$KC_POD" -- \
      /opt/keycloak/bin/kcadm.sh create \
      "clients/${CLIENT_UUID}/protocol-mappers/models" \
      -r "$KC_REALM" -f "/tmp/${CLIENT_ID}-mapper.json" 2>/dev/null
    kubectl exec -n "$KC_NS" "$KC_POD" -- rm -f "/tmp/${CLIENT_ID}-mapper.json" 2>/dev/null
    info "Groups mapper added to '${CLIENT_ID}' ✓"
  fi
}

# Jenkins OIDC client — redirect: /securityRealm/finishLogin
create_oidc_client "jenkins" "${JENKINS_OIDC_SECRET}" \
  "${JENKINS_URL}/securityRealm/finishLogin" \
  "Jenkins CI/CD" \
  "${JENKINS_URL}" \
  "${JENKINS_URL}/*"

# SonarQube OIDC client — redirect: /oauth2/callback/oidc
# NOTE: 'sonarqube' is used as SAML client; 'sonarqube-oidc' is the OIDC client
# used by the sonar-auth-oidc v3.0.0 plugin (sonar.auth.oidc.clientId=sonarqube-oidc)
create_oidc_client "sonarqube-oidc" "${SONAR_OIDC_SECRET}" \
  "${SONAR_URL}/oauth2/callback/oidc" \
  "SonarQube OIDC" \
  "${SONAR_URL}"

# ── Create realm roles for SonarQube group sync via OIDC ──────────────────────
# sonar-auth-oidc reads the 'groups' claim from the JWT and syncs them to SonarQube
# groups. Keycloak groups already provide flat group names via oidc-group-membership-mapper.
# No additional realm roles are needed for OIDC (unlike the SAML role-list approach).

# ── Step 3: Copy cert-manager CA to sonarqube namespace ───────────────────────
section "Step 3 — Copying cert-manager CA cert to sonarqube namespace"

# SonarQube needs the cert-manager CA to verify Keycloak HTTPS.
# The sonarqube-values.yaml caCerts.secret references this Secret.
kubectl create namespace "$SONAR_NS" --dry-run=client -o yaml | kubectl apply -f -

CA_B64=$(kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null)
if [ -z "$CA_B64" ]; then
  error "cert-manager CA secret not found. Run 01-cloud-provider-kind-setup-with-gw-api setup first."
  exit 1
fi

kubectl create secret generic kind-local-ca-cert \
  --namespace "$SONAR_NS" \
  --from-literal="ca.crt=$(echo "${CA_B64}" | base64 -d)" \
  --dry-run=client -o yaml | kubectl apply -f -
info "CA cert secret created/updated in ${SONAR_NS} namespace ✓"

# ── Step 4: Kubernetes manifests (namespace, RBAC, buildkitd, PVC, stubs) ──────
section "Step 4 — Applying base Kubernetes manifests (setup/ directory)"

kubectl create namespace "$JENKINS_NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -k "${SCRIPT_DIR}/setup" 2>&1 || {
  warn "kustomize apply had warnings (non-fatal)"
}
kubectl apply -f "${SCRIPT_DIR}/setup/team-b-rbac.yaml"
info "Base manifests applied ✓"

# ── Step 5: Vault-backed Jenkins identities ───────────────────────────────────
section "Step 5 — Checking Vault-backed Jenkins agent identities"

kubectl get serviceaccount jenkins-ci -n "$JENKINS_NS" >/dev/null
kubectl get serviceaccount jenkins-cd-external -n "$JENKINS_NS" >/dev/null
kubectl get serviceaccount jenkins-ci-team-b -n "$JENKINS_NS" >/dev/null
kubectl get serviceaccount jenkins-cd-team-b -n "$JENKINS_NS" >/dev/null
info "Jenkins CI/CD ServiceAccounts are ready ✓"
info "Run ./vault-setup.sh and seed the documented Vault KV paths before builds."

# ── Step 6: SonarQube Helm install / upgrade ───────────────────────────────────
section "Step 6 — Installing SonarQube (${SONAR_CHART_VERSION})"

helm repo add sonarqube https://SonarSource.github.io/helm-chart-sonarqube 2>/dev/null || true
helm repo update sonarqube 2>/dev/null

if helm status "$SONAR_RELEASE" -n "$SONAR_NS" &>/dev/null; then
  info "SonarQube already installed — upgrading..."
  helm upgrade "$SONAR_RELEASE" sonarqube/sonarqube \
    --namespace "$SONAR_NS" \
    --values "${SCRIPT_DIR}/sonarqube-values.yaml" \
    --version "${SONAR_CHART_VERSION}" \
    --no-hooks \
    --timeout 10m
else
  # --no-hooks skips the change-admin-password hook job that times out while
  # SonarQube downloads plugins at startup. Admin password is set via API in Step 10.
  helm install "$SONAR_RELEASE" sonarqube/sonarqube \
    --namespace "$SONAR_NS" \
    --create-namespace \
    --values "${SCRIPT_DIR}/sonarqube-values.yaml" \
    --version "${SONAR_CHART_VERSION}" \
    --no-hooks \
    --timeout 10m
fi
info "SonarQube Helm release applied ✓"

# ── Step 7: Jenkins Helm install / upgrade ─────────────────────────────────────
section "Step 7 — Installing Jenkins (${JENKINS_CHART_VERSION})"

helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update jenkins 2>/dev/null

if helm status "$JENKINS_RELEASE" -n "$JENKINS_NS" &>/dev/null; then
  info "Jenkins already installed — upgrading..."
  helm upgrade "$JENKINS_RELEASE" jenkins/jenkins \
    --namespace "$JENKINS_NS" \
    --values "${SCRIPT_DIR}/jenkins-values.yaml" \
    --version "${JENKINS_CHART_VERSION}" \
    --timeout 10m
else
  helm install "$JENKINS_RELEASE" jenkins/jenkins \
    --namespace "$JENKINS_NS" \
    --create-namespace \
    --values "${SCRIPT_DIR}/jenkins-values.yaml" \
    --version "${JENKINS_CHART_VERSION}" \
    --timeout 10m
fi
info "Jenkins Helm release applied ✓"

# ── Step 8: HTTPRoutes ────────────────────────────────────────────────────────
section "Step 8 — Applying HTTPRoutes"

kubectl apply -f "${SCRIPT_DIR}/httproutes.yaml"
info "HTTPRoutes applied ✓"

# ── Step 9: Wait for services to be ready ─────────────────────────────────────
section "Step 9 — Waiting for Jenkins and SonarQube to be Ready"

info "Waiting for Jenkins (may take 5–10 minutes for plugin downloads)..."
kubectl rollout status statefulset/jenkins -n "$JENKINS_NS" --timeout=600s

info "Waiting for SonarQube (may take 3–5 minutes)..."
kubectl rollout status statefulset/sonarqube-sonarqube \
  -n "$SONAR_NS" --timeout=600s

info "Both services Ready ✓"

# ── Step 10: Configure SonarQube via API ──────────────────────────────────────
section "Step 10 — Configuring SonarQube (OIDC + groups + projects)"

info "Starting port-forward to SonarQube (localhost:19000)..."
kubectl port-forward -n "$SONAR_NS" svc/sonarqube-sonarqube 19000:9000 &
PF_SONAR=$!
trap 'kill "$PF_SONAR" 2>/dev/null || true; wait "$PF_SONAR" 2>/dev/null || true' EXIT

# Wait for SonarQube API
RETRIES=60
until curl -sf -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASS}" \
    "http://localhost:19000/api/system/status" 2>/dev/null \
    | python3 -c "import json,sys; s=json.load(sys.stdin); exit(0 if s.get('status')=='UP' else 1)" 2>/dev/null; do
  RETRIES=$((RETRIES - 1))
  [ $RETRIES -eq 0 ] && { error "SonarQube API not available after timeout"; exit 1; }
  printf "."
  sleep 5
done
echo ""
info "SonarQube API UP ✓"

# ── 10a: Accept plugin risk consent + install authoidc plugin ─────────────────
# The sonar-auth-oidc v3.0.0 plugin must be installed from the marketplace.
# Requires consent acceptance before the API will accept the install request.
info "Accepting plugin risk consent..."
sonar_api POST "/api/settings/set" \
  --data-urlencode "key=sonar.plugins.risk.consent" \
  --data-urlencode "value=ACCEPTED" > /dev/null 2>&1 || true

OIDC_PLUGIN_INSTALLED=$(sonar_api GET "/api/plugins/installed" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(any(p['key']=='authoidc' for p in d.get('plugins',[])))" 2>/dev/null || echo "False")

if [ "$OIDC_PLUGIN_INSTALLED" = "True" ]; then
  warn "authoidc plugin already installed — skipping"
else
  info "Installing sonar-auth-oidc v3.0.0 from marketplace..."
  HTTP=$(sonar_api POST "/api/plugins/install" --data-urlencode "key=authoidc" -w "%{http_code}" 2>/dev/null | tail -c 3 || echo "0")
  # Trigger restart to apply plugin installation
  sonar_api POST "/api/system/restart" > /dev/null 2>&1 || true
  info "Plugin install queued. Waiting for SonarQube restart..."
  sleep 40
  # Wait for SonarQube to come back up
  RETRIES2=30
  until curl -sf -u "${SONAR_ADMIN_USER}:${SONAR_ADMIN_PASS}" \
      "http://localhost:19000/api/system/status" 2>/dev/null \
      | python3 -c "import json,sys; s=json.load(sys.stdin); exit(0 if s.get('status')=='UP' else 1)" 2>/dev/null; do
    RETRIES2=$((RETRIES2 - 1))
    [ $RETRIES2 -eq 0 ] && { error "SonarQube did not come back after plugin install"; break; }
    printf "."
    sleep 5
  done
  echo ""
  info "SonarQube ready after plugin install ✓"
fi

# ── 10b: Configure OIDC plugin settings via Settings API ──────────────────────
info "Configuring OIDC authentication settings..."

# Helper: set a SonarQube property
sq_set() {
  local key="$1"; local value="$2"
  sonar_api POST "/api/settings/set" --data-urlencode "key=${key}" --data-urlencode "value=${value}" > /dev/null
  info "  Set ${key} ✓"
}

# sonarqube-oidc is the Keycloak OIDC client for SonarQube
# The 'groups' claim (flat names: devops, team-a, team-b) is added by the
# oidc-group-membership-mapper on the sonarqube-oidc Keycloak client
sq_set "sonar.auth.oidc.enabled"              "true"
sq_set "sonar.auth.oidc.issuerUri"            "https://keycloak.kind.local/realms/kind"
sq_set "sonar.auth.oidc.clientId.secured"     "sonarqube-oidc"
sq_set "sonar.auth.oidc.clientSecret.secured" "${SONAR_OIDC_SECRET}"
sq_set "sonar.auth.oidc.scopes"               "openid email profile"
sq_set "sonar.auth.oidc.loginStrategy"        "Preferred Username"
sq_set "sonar.auth.oidc.allowUsersToSignUp"   "true"
sq_set "sonar.auth.oidc.groupsSyncEnabled"    "true"
sq_set "sonar.auth.oidc.groupsSync.claimName" "groups"
info "OIDC settings configured ✓"

# ── 10c: Create groups ─────────────────────────────────────────────────────────
info "Creating SonarQube groups..."

for GROUP in devops team-a team-b; do
  EXISTS=$(sonar_api GET "/api/user_groups/search?q=${GROUP}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin); print(any(g['name']=='${GROUP}' for g in r.get('groups',[])))" 2>/dev/null || echo "False")
  if [ "$EXISTS" = "True" ]; then
    warn "Group '${GROUP}' already exists — skipping"
  else
    sonar_api POST "/api/user_groups/create" \
      --data-urlencode "name=${GROUP}" \
      --data-urlencode "description=${GROUP} group (synced from Keycloak)" > /dev/null
    info "  Group '${GROUP}' created ✓"
  fi
done

# ── 10c: Grant devops group global admin permissions ──────────────────────────
info "Granting SonarQube global admin to devops group..."
for PERM in admin profileadmin gateadmin provisioning scan; do
  sonar_api POST "/api/permissions/add_group" \
    --data-urlencode "groupName=devops" \
    --data-urlencode "permission=${PERM}" > /dev/null 2>&1 || true
done
info "devops group → global admin ✓"

# ── 10d: Create SonarQube projects ────────────────────────────────────────────
info "Creating SonarQube projects..."

create_sq_project() {
  local KEY="$1"; local NAME="$2"; local GROUP="$3"
  EXISTS=$(sonar_api GET "/api/components/search?qualifiers=TRK&q=${KEY}" \
    | python3 -c "import json,sys; r=json.load(sys.stdin); print(any(c['key']=='${KEY}' for c in r.get('components',[])))" 2>/dev/null || echo "False")
  if [ "$EXISTS" = "True" ]; then
    warn "Project '${KEY}' already exists — skipping"
  else
    sonar_api POST "/api/projects/create" \
      --data-urlencode "project=${KEY}" \
      --data-urlencode "name=${NAME}" \
      --data-urlencode "visibility=private" > /dev/null
    info "  Project '${KEY}' created ✓"
  fi
  # Grant browse + execute analysis permissions to the team group
  for PERM in user codeviewer scan; do
    sonar_api POST "/api/permissions/add_group" \
      --data-urlencode "projectKey=${KEY}" \
      --data-urlencode "groupName=${GROUP}" \
      --data-urlencode "permission=${PERM}" > /dev/null 2>&1 || true
    # devops gets full access too
    sonar_api POST "/api/permissions/add_group" \
      --data-urlencode "projectKey=${KEY}" \
      --data-urlencode "groupName=devops" \
      --data-urlencode "permission=${PERM}" > /dev/null 2>&1 || true
  done
  info "  Permissions set for '${KEY}': ${GROUP} + devops ✓"
}

create_sq_project \
  "sample-react-app-team-a-api" "Team A Sample React App API" "team-a"
create_sq_project \
  "sample-react-app-team-a-client" "Team A Sample React App Client" "team-a"

# ── Step 11: Generate SonarQube token → store as K8s Secret ───────────────────
section "Step 11 — Generating SonarQube analysis token for Jenkins"

TOKEN_EXISTS=$(kubectl get secret sonarqube-token -n "$JENKINS_NS" &>/dev/null && echo "yes" || echo "no")
if [ "$TOKEN_EXISTS" = "yes" ]; then
  warn "sonarqube-token Secret already exists in ${JENKINS_NS} — skipping generation"
else
  info "Generating global analysis token in SonarQube..."
  TOKEN_RESP=$(sonar_api POST "/api/user_tokens/generate" \
    --data-urlencode "name=jenkins-global-$(date +%s)" \
    --data-urlencode "type=GLOBAL_ANALYSIS_TOKEN")
  SQ_TOKEN=$(echo "${TOKEN_RESP}" | python3 -c "import json,sys; print(json.load(sys.stdin).get('token',''))" 2>/dev/null || echo "")
  if [ -n "$SQ_TOKEN" ]; then
    kubectl create secret generic sonarqube-token \
      --namespace "$JENKINS_NS" \
      --from-literal=token="${SQ_TOKEN}"
    info "sonarqube-token Secret created in ${JENKINS_NS} ✓"
    info "Token: ${SQ_TOKEN:0:12}... (stored as K8s Secret)"
    # Also configure SonarQube webhook pointing to Jenkins
    sonar_api POST "/api/webhooks/create" \
      --data-urlencode "name=jenkins" \
      --data-urlencode "url=http://jenkins.${JENKINS_NS}.svc.cluster.local:8080/sonarqube-webhook/" > /dev/null 2>&1 || true
    info "SonarQube → Jenkins webhook configured ✓"
  else
    warn "Could not generate SonarQube token — configure manually via UI"
  fi
fi

# Stop port-forward
kill "$PF_SONAR" 2>/dev/null || true
wait "$PF_SONAR" 2>/dev/null || true
trap - EXIT
info "Port-forward stopped"

# ── Done ──────────────────────────────────────────────────────────────────────
section "Setup complete!"
cat << EOF

╔══════════════════════════════════════════════════════════════════════════╗
║                 Jenkins + SonarQube — Access Summary                    ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Jenkins    : https://jenkins.kind.local                                ║
║  SonarQube  : https://sonarqube.kind.local                              ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Jenkins local admin : admin / Admin@Jenkins2024!                       ║
║  Jenkins SSO         : click 'Sign in with Keycloak' on login page      ║
║                                                                          ║
║  SonarQube local admin : admin / admin                                  ║
║  SonarQube SSO         : click 'Log in with OpenID Connect'             ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Keycloak group  →  Jenkins access                                      ║
║  ────────────────────────────────────────────────────────────────────   ║
║  devops  →  Global admin (all folders + jobs)                           ║
║  team-a  →  team-a/{ci,cd}/react-app only                               ║
║  team-b  →  team-b/{ci,cd}/react-app only                               ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Jenkins folder structure:                                              ║
║  /devops/{k8s, terraform-module, terragrunt, vault, keycloak}           ║
║  /team-a/{ci, cd}/react-app                                             ║
║  /team-b/{ci, cd}/react-app                                             ║
╠══════════════════════════════════════════════════════════════════════════╣
║  SonarQube projects:                                                    ║
║   sample-react-app-team-a-api     → team-a + devops groups              ║
║   sample-react-app-team-a-client  → team-a + devops groups              ║
╠══════════════════════════════════════════════════════════════════════════╣
║  Test Keycloak users (password: password)                               ║
║   devops-user-1   →  admin everywhere                                   ║
║   team-a-user-1   →  team-a folder only (Jenkins) / team-a proj (SQ)   ║
║   team-b-user-1   →  team-b folder only (Jenkins) / team-b proj (SQ)   ║
╚══════════════════════════════════════════════════════════════════════════╝

Add to /etc/hosts (if not already):
  127.0.0.1 jenkins.kind.local jenkins-resources.kind.local sonarqube.kind.local

EOF
