#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAMESPACE="artifactory"
RELEASE="nexus"
SERVICE="nexus"
LOCAL_PORT="18081"
ADMIN_SECRET="nexus-admin-credentials"
CA_SECRET="nexus-kind-local-ca"
PF_PID=""

info() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for command_name in kubectl helm curl python3 openssl; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done
kubectl cluster-info >/dev/null 2>&1 || fail "No reachable Kubernetes cluster"

info "Creating namespace and copying the local platform CA"
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml \
  | kubectl apply -f - >/dev/null

CA_CRT=$(kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' 2>/dev/null) \
  || fail "cert-manager/kind-local-ca-secret was not found; complete module 01 first"
kubectl create secret generic "${CA_SECRET}" \
  --namespace "${NAMESPACE}" \
  --from-literal=tls.crt="$(printf '%s' "${CA_CRT}" | base64 --decode)" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null

if ! kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  GENERATED_ADMIN_PASSWORD=$(openssl rand -base64 36 | tr -d '\n')
  kubectl create secret generic "${ADMIN_SECRET}" \
    --namespace "${NAMESPACE}" \
    --from-literal=username=admin \
    --from-literal=password="${GENERATED_ADMIN_PASSWORD}" >/dev/null
  unset GENERATED_ADMIN_PASSWORD
  info "Generated the runtime Nexus admin credential in Secret/${ADMIN_SECRET}"
fi

info "Installing or upgrading Nexus Repository"
helm upgrade --install "${RELEASE}" "${MODULE_DIR}/nexus-chart" \
  --namespace "${NAMESPACE}" \
  --values "${MODULE_DIR}/values.yaml" \
  --wait \
  --timeout 15m

kubectl rollout status deployment/nexus -n "${NAMESPACE}" --timeout=15m
NEXUS_POD=$(kubectl get pods -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=nexus,app.kubernetes.io/instance="${RELEASE}" \
  -o jsonpath='{.items[0].metadata.name}')

NEXUS_ADMIN_PASSWORD=$(kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 --decode)

info "Starting a temporary Nexus API port-forward"
kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE}" \
  "${LOCAL_PORT}:8081" >/tmp/nexus-port-forward.log 2>&1 &
PF_PID=$!

for _ in $(seq 1 120); do
  if curl --fail --silent --show-error \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kill -0 "${PF_PID}" 2>/dev/null || fail "Nexus port-forward exited unexpectedly"

INITIAL_ADMIN_PASSWORD=""
if kubectl exec -n "${NAMESPACE}" "${NEXUS_POD}" -- \
  test -f /nexus-data/admin.password >/dev/null 2>&1; then
  INITIAL_ADMIN_PASSWORD=$(kubectl exec -n "${NAMESPACE}" "${NEXUS_POD}" -- \
    cat /nexus-data/admin.password)
fi

nexus_status() {
  local password=$1
  curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "admin:${password}" \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/security/users"
}

if [[ "$(nexus_status "${NEXUS_ADMIN_PASSWORD}")" != "200" ]]; then
  [[ -n "${INITIAL_ADMIN_PASSWORD}" ]] \
    || fail "Stored admin password is invalid and the initial password file is absent"
  [[ "$(nexus_status "${INITIAL_ADMIN_PASSWORD}")" == "200" ]] \
    || fail "Neither the stored nor initial Nexus admin password is valid"

  info "Replacing the one-time Nexus admin password"
  curl --fail --silent --show-error \
    --request PUT \
    --user "admin:${INITIAL_ADMIN_PASSWORD}" \
    --header 'Content-Type: text/plain' \
    --data-binary "${NEXUS_ADMIN_PASSWORD}" \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/security/users/admin/change-password"
fi
unset INITIAL_ADMIN_PASSWORD

nexus_api() {
  local method=$1
  local path=$2
  shift 2
  curl --fail-with-body --silent --show-error \
    --request "${method}" \
    --user "admin:${NEXUS_ADMIN_PASSWORD}" \
    --header 'Accept: application/json' \
    "http://127.0.0.1:${LOCAL_PORT}${path}" "$@"
}

EULA_DOCUMENT=$(nexus_api GET /service/rest/v1/system/eula)
EULA_ACCEPTED=$(EULA_DOCUMENT="${EULA_DOCUMENT}" python3 - <<'PY'
import json
import os
print(str(json.loads(os.environ["EULA_DOCUMENT"])["accepted"]).lower())
PY
)
if [[ "${EULA_ACCEPTED}" != "true" ]]; then
  if [[ "${ACCEPT_NEXUS_EULA:-false}" != "true" ]]; then
    fail "Nexus is deployed, but repository provisioning requires EULA acceptance. Read the EULA and rerun with ACCEPT_NEXUS_EULA=true."
  fi
  info "Accepting the Nexus Community Edition EULA as explicitly requested"
  EULA_PAYLOAD=$(EULA_DOCUMENT="${EULA_DOCUMENT}" python3 - <<'PY'
import json
import os
document = json.loads(os.environ["EULA_DOCUMENT"])
document["accepted"] = True
print(json.dumps(document, separators=(",", ":")))
PY
)
  nexus_api POST /service/rest/v1/system/eula \
    --header 'Content-Type: application/json' \
    --data-binary "${EULA_PAYLOAD}" >/dev/null
fi

repository_exists() {
  local name=$1
  nexus_api GET /service/rest/v1/repositories \
    | REPOSITORY_NAME="${name}" python3 -c \
      'import json,os,sys; raise SystemExit(0 if any(r["name"] == os.environ["REPOSITORY_NAME"] for r in json.load(sys.stdin)) else 1)'
}

create_repository() {
  local name=$1
  local endpoint=$2
  local payload=$3
  if repository_exists "${name}"; then
    info "Repository ${name} already exists"
  else
    nexus_api POST "${endpoint}" \
      --header 'Content-Type: application/json' \
      --data-binary "${payload}" >/dev/null
    info "Created repository ${name}"
  fi
}

STORAGE='"storage":{"blobStoreName":"default","strictContentTypeValidation":true,"writePolicy":"ALLOW"}'
CLEANUP='"cleanup":{"policyNames":[]}'

create_repository devops /service/rest/v1/repositories/raw/hosted \
  "{\"name\":\"devops\",\"online\":true,${STORAGE},${CLEANUP},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"
create_repository extra /service/rest/v1/repositories/raw/hosted \
  "{\"name\":\"extra\",\"online\":true,${STORAGE},${CLEANUP},\"raw\":{\"contentDisposition\":\"ATTACHMENT\"}}"
create_repository helm-charts /service/rest/v1/repositories/helm/hosted \
  "{\"name\":\"helm-charts\",\"online\":true,${STORAGE},${CLEANUP}}"
create_repository docker-image /service/rest/v1/repositories/docker/hosted \
  "{\"name\":\"docker-image\",\"online\":true,${STORAGE},${CLEANUP},\"docker\":{\"v1Enabled\":false,\"forceBasicAuth\":true,\"pathEnabled\":true}}"

for team in team-a team-b; do
  repository_name="maven-snapshot-${team}"
  create_repository "${repository_name}" /service/rest/v1/repositories/maven/hosted \
    "{\"name\":\"${repository_name}\",\"online\":true,${STORAGE},${CLEANUP},\"component\":{\"proprietaryComponents\":true},\"maven\":{\"versionPolicy\":\"SNAPSHOT\",\"layoutPolicy\":\"STRICT\",\"contentDisposition\":\"ATTACHMENT\"}}"
done

upsert_role() {
  local role_id=$1
  local role_name=$2
  local description=$3
  local privileges_json=$4
  local roles_json=${5:-'[]'}
  local method=POST
  local path=/service/rest/v1/security/roles
  local status
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "admin:${NEXUS_ADMIN_PASSWORD}" \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/security/roles/${role_id}")
  if [[ "${status}" == "200" ]]; then
    method=PUT
    path="${path}/${role_id}"
  fi
  nexus_api "${method}" "${path}" \
    --header 'Content-Type: application/json' \
    --data-binary "{\"id\":\"${role_id}\",\"name\":\"${role_name}\",\"description\":\"${description}\",\"privileges\":${privileges_json},\"roles\":${roles_json}}" >/dev/null
  info "Configured role ${role_id}"
}

READ_PRIVILEGES='["nx-search-read","nx-repository-view-*-*-browse","nx-repository-view-*-*-read"]'
DEVOPS_PRIVILEGES='["nx-search-read","nx-component-upload","nx-repository-view-*-*-add","nx-repository-view-*-*-browse","nx-repository-view-*-*-delete","nx-repository-view-*-*-edit","nx-repository-view-*-*-read"]'
upsert_role nexus-read-all "All repositories - read" \
  "Read and browse every repository" "${READ_PRIVILEGES}"
upsert_role devops "DevOps - all repositories" \
  "Manage components in every repository without Nexus system administration" \
  "${DEVOPS_PRIVILEGES}" '["nexus-read-all"]'

for team in team-a team-b; do
  repository_name="maven-snapshot-${team}"
  privileges="[\"nx-component-upload\",\"nx-search-read\",\"nx-repository-view-maven2-${repository_name}-add\",\"nx-repository-view-maven2-${repository_name}-browse\",\"nx-repository-view-maven2-${repository_name}-delete\",\"nx-repository-view-maven2-${repository_name}-edit\",\"nx-repository-view-maven2-${repository_name}-read\"]"
  upsert_role "${team}" "${team} Maven snapshots" \
    "Manage ${repository_name}" "${privileges}" '["nexus-read-all"]'
done

nexus_api PUT /service/rest/v1/security/anonymous \
  --header 'Content-Type: application/json' \
  --data-binary '{"enabled":false,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' >/dev/null

CAPABILITIES=$(nexus_api GET /service/rest/v1/capabilities)
DEFAULT_ROLE_CAPABILITY_ID=$(CAPABILITIES="${CAPABILITIES}" python3 - <<'PY'
import json
import os
for capability in json.loads(os.environ["CAPABILITIES"]):
    if capability.get("type") == "defaultrole":
        print(capability["id"])
        break
PY
)
DEFAULT_ROLE_PAYLOAD='{"enabled":true,"notes":"Read access for every authenticated user","properties":{"role":"nexus-read-all"}}'
if [[ -n "${DEFAULT_ROLE_CAPABILITY_ID}" ]]; then
  nexus_api PUT "/service/rest/v1/capabilities/${DEFAULT_ROLE_CAPABILITY_ID}" \
    --header 'Content-Type: application/json' \
    --data-binary "${DEFAULT_ROLE_PAYLOAD}" >/dev/null
else
  nexus_api POST /service/rest/v1/capabilities \
    --header 'Content-Type: application/json' \
    --data-binary "{\"type\":\"defaultrole\",${DEFAULT_ROLE_PAYLOAD#\{}" >/dev/null
fi

info "Nexus repositories and local roles are ready"
info "Run ./configure-keycloak.sh, then ./configure-oidc.sh after installing a Nexus Pro license"
info "Admin password: kubectl get secret ${ADMIN_SECRET} -n ${NAMESPACE} -o jsonpath='{.data.password}' | base64 --decode"
