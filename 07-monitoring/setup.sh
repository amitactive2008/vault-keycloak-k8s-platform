#!/usr/bin/env bash
# ============================================================
# setup.sh — Monitoring stack post-install configuration
#
# What this does:
#   1. Updates CoreDNS so all *.kind.local hostnames resolve to the
#      Envoy Gateway ClusterIP from inside the cluster (needed for
#      blackbox probes and Grafana → Keycloak OAuth token exchange)
#   2. Creates a confidential OIDC client 'grafana' in Keycloak kind realm
#      with a groups claim mapper (full.path=false → flat names)
#   3. Waits for Grafana and the full monitoring stack to be Ready
#   4. Creates Grafana organizations: admin (rename Main Org.), team-a, team-b
#   5. Creates a Prometheus datasource in each organization
#   6. Imports a namespace-scoped dashboard into team-a and team-b orgs
#      (showing pod CPU/Memory/status filtered to each team's namespace)
#
# Access matrix after setup:
#   Keycloak devops group  → Grafana Admin in: admin, team-a, team-b orgs
#   Keycloak team-a group  → Grafana Admin in: team-a org only
#   Keycloak team-b group  → Grafana Admin in: team-b org only
#
# Prerequisites:
#   - Steps 01–04 complete (cluster, Envoy GW, cert-manager, Keycloak)
#   - kube-prometheus-stack installed (helm install kube-prom ...)
#   - blackbox exporter installed (helm install blackbox ...)
#   - HTTPRoutes applied (kubectl apply -f httproutes.yaml)
#   - /etc/hosts entries added for all monitoring hostnames
#
# Usage:
#   cd 07-monitoring
#   chmod +x setup.sh
#   ./setup.sh
#
# Requires: kubectl, python3, curl
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Configuration ─────────────────────────────────────────────
KC_NS="keycloak"
KC_REALM="kind"
KC_ADMIN_PASS="Admin@Keycloak2024!"
MONITORING_NS="monitoring"
GRAFANA_RELEASE="kube-prom"
GRAFANA_ADMIN_USER="admin"
GRAFANA_ADMIN_PASS="Admin@Grafana2024!"
GRAFANA_OIDC_CLIENT_ID="grafana"
GRAFANA_OIDC_CLIENT_SECRET="Grafana@Keycloak2024!"
GRAFANA_EXTERNAL_URL="https://grafana.kind.local"

# ── Helpers ───────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# Run curl against Grafana (port-forward must be active)
grafana_api() {
  local method="$1"; shift
  local path="$1";   shift
  curl -sf -X "${method}" \
    -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    "http://localhost:3000${path}" "$@"
}

# Run curl against Grafana with explicit org context (X-Grafana-Org-Id header).
# This is PER-REQUEST only — does NOT change the admin user's session org.
# Use this for all datasource/dashboard operations in specific orgs to prevent
# the Grafana sidecar (which also uses admin creds) from being affected.
grafana_api_org() {
  local org_id="$1"; shift
  local method="$1"; shift
  local path="$1";   shift
  curl -sf -X "${method}" \
    -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
    -H "Content-Type: application/json" \
    -H "X-Grafana-Org-Id: ${org_id}" \
    "http://localhost:3000${path}" "$@"
}

# ── Step 0: Prerequisites ─────────────────────────────────────
section "Step 0 — Checking prerequisites"
for cmd in kubectl python3 curl; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
  info "$cmd → $(command -v "$cmd")"
done
kubectl cluster-info &>/dev/null || { error "No cluster found. Is kind running?"; exit 1; }
info "Cluster: $(kubectl config current-context)"

# Verify monitoring namespace exists
kubectl get ns "${MONITORING_NS}" &>/dev/null || {
  error "Namespace '${MONITORING_NS}' not found."
  error "Install kube-prometheus-stack first: helm install kube-prom ..."
  exit 1
}
info "Namespace ${MONITORING_NS} ✓"

# ── Step 1: CoreDNS — resolve all *.kind.local inside the cluster ────────────
# Blackbox exporter pods and Grafana (for OAuth token exchange) need to reach
# *.kind.local endpoints. CoreDNS must resolve them to the Envoy Gateway ClusterIP.
# This replaces/extends the single keycloak entry added in step 04.
section "Step 1 — Updating CoreDNS: *.kind.local → Envoy Gateway ClusterIP"

GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=native-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$GW_SVC" ]; then
  GW_SVC=$(kubectl get svc -n envoy-gateway-system \
    --field-selector spec.type=LoadBalancer \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
GW_IP=$(kubectl get svc -n envoy-gateway-system "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
info "Envoy Gateway ClusterIP: ${GW_IP}"

# Check if all hosts are already present
CURRENT_CORE=$(kubectl get configmap coredns -n kube-system \
  -o jsonpath='{.data.Corefile}' 2>/dev/null)

ALL_HOSTS_PRESENT=true
for host in keycloak.kind.local vault.kind.local grafana.kind.local \
            prometheus.kind.local alertmanager.kind.local \
            blackbox-exporter.kind.local team-a-webapp.kind.local; do
  if ! echo "$CURRENT_CORE" | grep -q "${host}"; then
    ALL_HOSTS_PRESENT=false
    break
  fi
done

if $ALL_HOSTS_PRESENT && echo "$CURRENT_CORE" | grep -q "$GW_IP"; then
  warn "CoreDNS already has all *.kind.local → ${GW_IP} — skipping update"
else
  info "Writing updated CoreDNS ConfigMap with all *.kind.local hosts..."

  # Python constructs the config to safely handle GW_IP substitution
  python3 - << PYEOF
import subprocess, sys

gw_ip = "${GW_IP}"

# All *.kind.local hostnames that must be resolvable from inside the cluster
hosts = [
    "vault.kind.local",
    "keycloak.kind.local",
    "grafana.kind.local",
    "prometheus.kind.local",
    "alertmanager.kind.local",
    "blackbox-exporter.kind.local",
    "team-a-webapp.kind.local",
    "sample.kind.local",
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

result = subprocess.run(
    ["kubectl", "apply", "-f", "-"],
    input=configmap.encode(),
    capture_output=True
)
if result.returncode != 0:
    print("ERROR applying CoreDNS:", result.stderr.decode(), file=sys.stderr)
    sys.exit(1)
print(result.stdout.decode().strip())
PYEOF

  info "CoreDNS ConfigMap applied. Restarting CoreDNS..."
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=60s
  info "CoreDNS restarted. Waiting 5 s for DNS propagation..."
  sleep 5
fi

# Smoke-test: can a pod in monitoring resolve grafana.kind.local?
RESOLVE=$(kubectl run dns-test-mon --rm --restart=Never --image=busybox:latest \
  -n "${MONITORING_NS}" --quiet \
  --command -- nslookup grafana.kind.local 2>/dev/null \
  | grep "Address" | tail -1 || echo "SKIPPED")
info "DNS smoke-test: grafana.kind.local → ${RESOLVE:-CHECKED}"

# ── Step 2: Keycloak OIDC client 'grafana' ───────────────────────────────────
# Public-facing confidential client; groups claim uses full.path=false
# so JWT has flat group names: ["devops"], ["team-a"], etc.
section "Step 2 — Creating Keycloak OIDC client 'grafana' in realm '${KC_REALM}'"

KC_POD=$(kubectl get pod -n "${KC_NS}" -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')
info "Keycloak pod: ${KC_POD}"

# Authenticate kcadm
kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "${KC_ADMIN_PASS}"

# Idempotent: check if grafana client already exists
CLIENT_EXISTS=$(kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "${KC_REALM}" \
  --fields clientId 2>/dev/null | grep -c '"grafana"' || true)

if [ "${CLIENT_EXISTS}" -gt 0 ]; then
  warn "Keycloak client 'grafana' already exists — skipping creation"
else
  info "Creating confidential OIDC client 'grafana'..."
  kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh create clients -r "${KC_REALM}" \
    -s clientId="${GRAFANA_OIDC_CLIENT_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s secret="${GRAFANA_OIDC_CLIENT_SECRET}" \
    -s "redirectUris=[\"${GRAFANA_EXTERNAL_URL}/login/generic_oauth\"]" \
    -s "webOrigins=[\"${GRAFANA_EXTERNAL_URL}\"]"
  info "Client 'grafana' created."
fi

# Get client UUID
CLIENT_UUID=$(kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "${KC_REALM}" \
  --fields id,clientId 2>/dev/null \
  | grep -B1 '"grafana"' | grep '"id"' | head -1 | awk -F'"' '{print $4}')
info "Client UUID: ${CLIENT_UUID}"

# Sync redirect URIs (idempotent — covers re-runs)
kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_UUID}" -r "${KC_REALM}" \
  -s "redirectUris=[\"${GRAFANA_EXTERNAL_URL}/login/generic_oauth\",\"http://localhost:3000/login/generic_oauth\"]" \
  -s "webOrigins=[\"${GRAFANA_EXTERNAL_URL}\",\"http://localhost:3000\"]"
info "redirectUris synced."

# Add groups claim mapper (full.path=false → flat names: devops, team-a, team-b)
MAPPER_COUNT=$(kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
  /opt/keycloak/bin/kcadm.sh get \
  "clients/${CLIENT_UUID}/protocol-mappers/models" \
  -r "${KC_REALM}" 2>/dev/null | grep -c '"groups"' || true)

if [ "${MAPPER_COUNT}" -gt 0 ]; then
  warn "Groups mapper already exists on 'grafana' client — skipping"
else
  info "Adding group-membership mapper (full.path=false) to 'grafana' client..."
  kubectl exec -n "${KC_NS}" "${KC_POD}" -- sh -c '
cat > /tmp/grafana-mapper.json << EOF
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
  kubectl exec -n "${KC_NS}" "${KC_POD}" -- \
    /opt/keycloak/bin/kcadm.sh create \
    "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "${KC_REALM}" -f /tmp/grafana-mapper.json
  kubectl exec -n "${KC_NS}" "${KC_POD}" -- rm -f /tmp/grafana-mapper.json
  info "Groups mapper added (flat names: devops, team-a, team-b)"
fi

# ── Step 3: Wait for monitoring stack ────────────────────────────────────────
section "Step 3 — Waiting for monitoring stack to be Ready"

info "Waiting for kube-prom-grafana..."
kubectl rollout status deployment/${GRAFANA_RELEASE}-grafana \
  -n "${MONITORING_NS}" --timeout=300s

info "Waiting for Prometheus..."
kubectl rollout status statefulset/prometheus-kube-prom-kube-prometheus-prometheus \
  -n "${MONITORING_NS}" --timeout=300s 2>/dev/null \
  || kubectl wait pod -n "${MONITORING_NS}" \
     -l app.kubernetes.io/name=prometheus --for=condition=Ready --timeout=300s

info "Waiting for Alertmanager..."
kubectl rollout status statefulset/alertmanager-kube-prom-kube-prometheus-alertmanager \
  -n "${MONITORING_NS}" --timeout=180s 2>/dev/null \
  || kubectl wait pod -n "${MONITORING_NS}" \
     -l app.kubernetes.io/name=alertmanager --for=condition=Ready --timeout=180s

info "Waiting for Blackbox Exporter..."
kubectl rollout status deployment/blackbox-prometheus-blackbox-exporter \
  -n "${MONITORING_NS}" --timeout=120s

info "All monitoring components Ready ✓"

# ── Step 4: Grafana organizations + datasources + dashboards ─────────────────
# Uses kubectl port-forward for direct Grafana API access.
section "Step 4 — Configuring Grafana organizations, datasources, and dashboards"

# Start port-forward (background)
info "Starting port-forward for Grafana API access..."
kubectl port-forward -n "${MONITORING_NS}" \
  svc/${GRAFANA_RELEASE}-grafana 3000:80 &
PF_PID=$!
# Ensure port-forward is cleaned up on exit
trap 'kill $PF_PID 2>/dev/null; wait $PF_PID 2>/dev/null; true' EXIT

# Wait for Grafana to respond
RETRIES=30
until curl -sf -u "${GRAFANA_ADMIN_USER}:${GRAFANA_ADMIN_PASS}" \
    "http://localhost:3000/api/health" > /dev/null 2>&1; do
  RETRIES=$((RETRIES - 1))
  [ $RETRIES -eq 0 ] && { error "Grafana API did not respond in time"; exit 1; }
  printf "."
  sleep 2
done
echo ""
info "Grafana API reachable ✓"

# ── 4a: Create / rename organizations ────────────────────────────────────────
info "Configuring Grafana organizations..."

# Rename default org 1 from 'Main Org.' to 'admin'
CURRENT_NAME_1=$(grafana_api GET "/api/orgs/1" | python3 -c \
  "import json,sys; print(json.load(sys.stdin).get('name',''))" 2>/dev/null || echo "")
if [ "${CURRENT_NAME_1}" = "admin" ]; then
  warn "Org 1 already named 'admin' — skipping rename"
else
  grafana_api PUT "/api/orgs/1" -d '{"name":"admin"}' > /dev/null
  info "Org 1 renamed → 'admin'"
fi

# Create team-a and team-b orgs (idempotent)
for ORG_NAME in "team-a" "team-b"; do
  ORG_CHECK=$(grafana_api GET "/api/orgs/name/${ORG_NAME}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")
  if [ "${ORG_CHECK}" != "0" ] && [ -n "${ORG_CHECK}" ]; then
    warn "Org '${ORG_NAME}' already exists (id=${ORG_CHECK}) — skipping"
  else
    RESULT=$(grafana_api POST "/api/orgs" -d "{\"name\":\"${ORG_NAME}\"}")
    NEW_ID=$(echo "${RESULT}" | python3 -c \
      "import json,sys; print(json.load(sys.stdin)['orgId'])" 2>/dev/null)
    info "Org '${ORG_NAME}' created (id=${NEW_ID})"
  fi
done

# Clean up stale orgs with name "Main Org." that Grafana may have auto-created
# during initial startup (id > 1, name = "Main Org.")
STALE_ORGS=$(grafana_api GET "/api/orgs" 2>/dev/null \
  | python3 -c "
import json,sys
orgs=json.load(sys.stdin)
stale=[o['id'] for o in orgs if o['name']=='Main Org.' and o['id']!=1]
print(' '.join(map(str,stale)))
" 2>/dev/null || echo "")
for STALE_ID in ${STALE_ORGS}; do
  info "Removing stale 'Main Org.' (id=${STALE_ID})..."
  # Delete users from stale org first
  STALE_USERS=$(grafana_api_org "${STALE_ID}" GET "/api/org/users" 2>/dev/null \
    | python3 -c "import json,sys; us=json.load(sys.stdin); [print(u['userId']) for u in us]" 2>/dev/null || echo "")
  for UID in ${STALE_USERS}; do
    grafana_api_org "${STALE_ID}" DELETE "/api/org/users/${UID}" > /dev/null 2>&1 || true
  done
  # Now delete the org
  grafana_api DELETE "/api/orgs/${STALE_ID}" > /dev/null 2>&1 \
    && info "Stale org ${STALE_ID} deleted" \
    || warn "Could not delete stale org ${STALE_ID} — may need manual cleanup"
done

# Fetch org IDs after creation
ADMIN_ORG_ID=$(grafana_api GET "/api/orgs/name/admin" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
TEAM_A_ORG_ID=$(grafana_api GET "/api/orgs/name/team-a" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
TEAM_B_ORG_ID=$(grafana_api GET "/api/orgs/name/team-b" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
info "Org IDs: admin=${ADMIN_ORG_ID}  team-a=${TEAM_A_ORG_ID}  team-b=${TEAM_B_ORG_ID}"

# Grafana 13.1.1 documents organization names in org_mapping, but its running
# Generic OAuth mapper attempts to parse the destination as an integer. Build
# the mapping from the IDs discovered above and persist it with Grafana's SSO
# Settings API. Database-backed settings override grafana.ini and apply without
# a pod restart.
info "Configuring ID-based Generic OAuth organization mapping..."
SSO_CURRENT=$(grafana_api GET "/api/v1/sso-settings/generic_oauth")
SSO_PAYLOAD=$(
  SSO_CURRENT="${SSO_CURRENT}" \
  ADMIN_ORG_ID="${ADMIN_ORG_ID}" \
  TEAM_A_ORG_ID="${TEAM_A_ORG_ID}" \
  TEAM_B_ORG_ID="${TEAM_B_ORG_ID}" \
  GRAFANA_OIDC_CLIENT_SECRET="${GRAFANA_OIDC_CLIENT_SECRET}" \
  python3 <<'PYSSO'
import json
import os

document = json.loads(os.environ["SSO_CURRENT"])
settings = document["settings"]
settings["clientSecret"] = os.environ["GRAFANA_OIDC_CLIENT_SECRET"]
settings["groupsAttributePath"] = "groups"
settings["orgAttributePath"] = "groups"
settings["roleAttributePath"] = "contains(groups[*], 'devops') && 'Admin' || 'None'"
settings["orgMapping"] = " ".join([
    f"devops:{os.environ['ADMIN_ORG_ID']}:Admin",
    f"devops:{os.environ['TEAM_A_ORG_ID']}:Admin",
    f"devops:{os.environ['TEAM_B_ORG_ID']}:Admin",
    f"team-a:{os.environ['TEAM_A_ORG_ID']}:Admin",
    f"team-b:{os.environ['TEAM_B_ORG_ID']}:Admin",
])
print(json.dumps({"settings": settings}, separators=(",", ":")))
PYSSO
)
grafana_api PUT "/api/v1/sso-settings/generic_oauth" \
  -d "${SSO_PAYLOAD}" > /dev/null

SSO_EFFECTIVE=$(grafana_api GET "/api/v1/sso-settings/generic_oauth")
SSO_EFFECTIVE="${SSO_EFFECTIVE}" python3 <<'PYSSO'
import json
import os

settings = json.loads(os.environ["SSO_EFFECTIVE"])["settings"]
if settings.get("orgAttributePath") != "groups":
    raise SystemExit("Grafana orgAttributePath was not applied")
if any(name in settings.get("orgMapping", "") for name in (":admin:", ":team-a:", ":team-b:")):
    raise SystemExit("Grafana orgMapping still contains destination names")
print("Generic OAuth organization mapping applied:", settings["orgMapping"])
PYSSO

# ── 4b: Datasources — Prometheus in each org ─────────────────────────────────
PROM_URL="http://prometheus-operated.${MONITORING_NS}:9090"

add_datasource_if_missing() {
  local org_id="$1"
  local ds_name="$2"
  DS_CHECK=$(grafana_api_org "${org_id}" GET "/api/datasources/name/${ds_name}" 2>/dev/null \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('id',0))" 2>/dev/null || echo "0")
  if [ "${DS_CHECK}" != "0" ] && [ -n "${DS_CHECK}" ]; then
    warn "Datasource '${ds_name}' already exists in org ${org_id} — skipping"
  else
    grafana_api_org "${org_id}" POST "/api/datasources" -d "{
      \"name\":\"${ds_name}\",
      \"type\":\"prometheus\",
      \"url\":\"${PROM_URL}\",
      \"access\":\"proxy\",
      \"isDefault\":true,
      \"jsonData\":{\"timeInterval\":\"30s\"}
    }" > /dev/null
    info "Datasource '${ds_name}' created in org ${org_id}"
  fi
}

info "Adding Prometheus datasources..."
# admin org already has datasource from values.yaml additionalDataSources
# but we create it via API to ensure consistency
add_datasource_if_missing "${ADMIN_ORG_ID}" "Prometheus"
add_datasource_if_missing "${TEAM_A_ORG_ID}" "Prometheus"
add_datasource_if_missing "${TEAM_B_ORG_ID}" "Prometheus"

# ── 4c: Namespace dashboards for team-a and team-b ───────────────────────────
# Each team gets a dashboard pre-filtered to their namespace showing:
#   • Running pod count  • Pod restarts
#   • CPU usage by pod   • Memory usage by pod
# devops (admin org) uses the pre-built kube-prometheus-stack dashboards
# which cover the entire cluster and are auto-imported by the sidecar.

import_namespace_dashboard() {
  local org_id="$1"
  local namespace="$2"
  local org_label="$3"   # display name e.g. "Team A"
  local ds_uid             # fetched below

  # Get datasource UID for this org using X-Grafana-Org-Id header (no session change)
  ds_uid=$(grafana_api_org "${org_id}" GET "/api/datasources/name/Prometheus" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('uid',''))" 2>/dev/null || echo "")
  [ -z "${ds_uid}" ] && { warn "Could not get datasource UID for org ${org_id} — skipping dashboard"; return; }

  info "Importing namespace dashboard for '${namespace}' into org ${org_id}..."

  python3 - << PYEOF
import json, subprocess, sys

org_id    = ${org_id}
namespace = "${namespace}"
org_label = "${org_label}"
ds_uid    = "${ds_uid}"
grafana_user = "${GRAFANA_ADMIN_USER}"
grafana_pass = "${GRAFANA_ADMIN_PASS}"

dashboard = {
    "id": None,
    "uid": f"ns-overview-{namespace}",
    "title": f"{org_label} — Namespace Overview",
    "tags": ["kubernetes", "namespace", namespace],
    "timezone": "browser",
    "refresh": "30s",
    "schemaVersion": 36,
    "time": {"from": "now-1h", "to": "now"},
    "templating": {"list": []},
    "panels": [
        # ── Row 1: Stats ─────────────────────────────────────────
        {
            "id": 1, "type": "stat", "title": "Running Pods",
            "gridPos": {"h": 4, "w": 4, "x": 0, "y": 0},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
            "fieldConfig": {"defaults": {"color": {"mode": "thresholds"},
                "thresholds": {"steps": [{"color": "red","value": 0},{"color": "green","value": 1}]}}},
            "targets": [{"expr": f'count(kube_pod_status_phase{{namespace="{namespace}",phase="Running"}})',
                          "legendFormat": "", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        {
            "id": 2, "type": "stat", "title": "Total Pods",
            "gridPos": {"h": 4, "w": 4, "x": 4, "y": 0},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value"},
            "fieldConfig": {"defaults": {"color": {"mode": "fixed", "fixedColor": "blue"}}},
            "targets": [{"expr": f'count(kube_pod_info{{namespace="{namespace}"}})',
                          "legendFormat": "", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        {
            "id": 3, "type": "stat", "title": "Pod Restarts (last 1h)",
            "gridPos": {"h": 4, "w": 4, "x": 8, "y": 0},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "background"},
            "fieldConfig": {"defaults": {"color": {"mode": "thresholds"},
                "thresholds": {"steps": [{"color": "green","value": 0},{"color": "yellow","value": 1},{"color": "red","value": 5}]}}},
            "targets": [{"expr": f'sum(increase(kube_pod_container_status_restarts_total{{namespace="{namespace}"}}[1h]))',
                          "legendFormat": "", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        {
            "id": 4, "type": "stat", "title": "Namespace CPU Cores Used",
            "gridPos": {"h": 4, "w": 6, "x": 12, "y": 0},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value"},
            "fieldConfig": {"defaults": {"unit": "short", "decimals": 3,
                "color": {"mode": "fixed", "fixedColor": "orange"}}},
            "targets": [{"expr": f'sum(rate(container_cpu_usage_seconds_total{{namespace="{namespace}",container!="",container!="POD"}}[5m]))',
                          "legendFormat": "", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        {
            "id": 5, "type": "stat", "title": "Namespace Memory Used",
            "gridPos": {"h": 4, "w": 6, "x": 18, "y": 0},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"reduceOptions": {"calcs": ["lastNotNull"]}, "colorMode": "value"},
            "fieldConfig": {"defaults": {"unit": "bytes",
                "color": {"mode": "fixed", "fixedColor": "purple"}}},
            "targets": [{"expr": f'sum(container_memory_working_set_bytes{{namespace="{namespace}",container!="",container!="POD"}})',
                          "legendFormat": "", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        # ── Row 2: CPU time-series ────────────────────────────────
        {
            "id": 6, "type": "timeseries", "title": "CPU Usage by Pod",
            "gridPos": {"h": 8, "w": 12, "x": 0, "y": 4},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "fieldConfig": {"defaults": {"unit": "short", "custom": {"lineWidth": 2}}},
            "options": {"legend": {"displayMode": "table", "placement": "bottom"}},
            "targets": [{"expr": f'sum(rate(container_cpu_usage_seconds_total{{namespace="{namespace}",container!="",container!="POD"}}[5m])) by (pod)',
                          "legendFormat": "{{{{pod}}}}", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        # ── Row 2: Memory time-series ─────────────────────────────
        {
            "id": 7, "type": "timeseries", "title": "Memory Usage by Pod",
            "gridPos": {"h": 8, "w": 12, "x": 12, "y": 4},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "fieldConfig": {"defaults": {"unit": "bytes", "custom": {"lineWidth": 2}}},
            "options": {"legend": {"displayMode": "table", "placement": "bottom"}},
            "targets": [{"expr": f'sum(container_memory_working_set_bytes{{namespace="{namespace}",container!="",container!="POD"}}) by (pod)',
                          "legendFormat": "{{{{pod}}}}", "datasource": {"type": "prometheus", "uid": ds_uid}}]
        },
        # ── Row 3: Pod table ──────────────────────────────────────
        {
            "id": 8, "type": "table", "title": "Pod Status",
            "gridPos": {"h": 8, "w": 24, "x": 0, "y": 12},
            "datasource": {"type": "prometheus", "uid": ds_uid},
            "options": {"sortBy": [{"displayName": "Pod", "desc": False}]},
            "targets": [{"expr": f'kube_pod_status_phase{{namespace="{namespace}"}}',
                          "legendFormat": "{{{{pod}}}} — {{{{phase}}}}",
                          "instant": True,
                          "datasource": {"type": "prometheus", "uid": ds_uid},
                          "format": "table"}]
        },
    ]
}

payload = json.dumps({
    "dashboard": dashboard,
    "overwrite": True,
    "message": f"Namespace dashboard for {namespace} imported by setup.sh"
})

# Use X-Grafana-Org-Id header — per-request only, does NOT change the admin
# user's session org (safe to use while sidecar is running in background)
result = subprocess.run(
    ["curl", "--fail-with-body", "-sS", "-X", "POST",
     "-u", f"{grafana_user}:{grafana_pass}",
     "-H", "Content-Type: application/json",
     "-H", f"X-Grafana-Org-Id: {org_id}",
     "-d", payload,
     "http://localhost:3000/api/dashboards/db"],
    capture_output=True, text=True
)
if result.returncode == 0 and '"status":"success"' in result.stdout:
    print(f"Dashboard imported into org {org_id}: {result.stdout[:120]}")
else:
    print(f"Dashboard import failed: {result.stdout[:500]} | err: {result.stderr[:200]}", file=sys.stderr)
    raise SystemExit(1)
PYEOF

  grafana_api_org "${org_id}" GET \
    "/api/dashboards/uid/ns-overview-${namespace}" > /dev/null
  info "Dashboard verified in org ${org_id}: ns-overview-${namespace}"
}

import_namespace_dashboard "${TEAM_A_ORG_ID}" "team-a" "Team A"
import_namespace_dashboard "${TEAM_B_ORG_ID}" "team-b" "Team B"

# Stop port-forward
kill "$PF_PID" 2>/dev/null || true
wait "$PF_PID" 2>/dev/null || true
trap - EXIT
info "Port-forward stopped"

# ── Done ─────────────────────────────────────────────────────────────────────
section "Setup complete!"

cat << EOF

╔═══════════════════════════════════════════════════════════════════════╗
║              Monitoring Stack — Access Summary                        ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Grafana        : https://grafana.kind.local                         ║
║  Prometheus     : https://prometheus.kind.local                      ║
║  Alertmanager   : https://alertmanager.kind.local                    ║
║  Blackbox       : https://blackbox-exporter.kind.local               ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Grafana local admin  : admin / Admin@Grafana2024!                   ║
║  Grafana SSO          : click 'Sign in with Keycloak'                ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Keycloak group  →  Grafana organization(s)   :  Role                ║
║  ─────────────────────────────────────────────────────────           ║
║  devops          →  admin, team-a, team-b     :  Admin               ║
║  team-a          →  team-a only               :  Admin               ║
║  team-b          →  team-b only               :  Admin               ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Org: admin    — cluster-wide dashboards (pre-built by kube-prom)    ║
║  Org: team-a   — namespace dashboard: team-a pods/CPU/memory         ║
║  Org: team-b   — namespace dashboard: team-b pods/CPU/memory         ║
╠═══════════════════════════════════════════════════════════════════════╣
║  Test Keycloak users (password: password)                             ║
║   devops-user-1   →  can switch between all 3 Grafana orgs           ║
║   team-a-user-1   →  sees team-a org only                            ║
║   team-b-user-1   →  sees team-b org only                            ║
╚═══════════════════════════════════════════════════════════════════════╝

Add to /etc/hosts if not already present:
  127.0.0.1 prometheus.kind.local grafana.kind.local alertmanager.kind.local blackbox-exporter.kind.local

EOF
