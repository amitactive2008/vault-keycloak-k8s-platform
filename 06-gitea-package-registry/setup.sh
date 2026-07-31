#!/usr/bin/env bash
set -euo pipefail

MODULE_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NAMESPACE="artifactory"
RELEASE="gitea"
SERVICE="gitea"
LOCAL_PORT="13000"
RUNTIME_SECRET="gitea-runtime-credentials"
CA_SECRET="gitea-kind-local-ca"
PF_PID=""
PF_LOG=""

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
  if [[ -n "${PF_LOG}" ]]; then
    rm -f "${PF_LOG}"
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
unset CA_CRT

if ! kubectl get secret "${RUNTIME_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1; then
  GENERATED_ADMIN_PASSWORD=$(openssl rand -base64 36 | tr -d '\n')
  GENERATED_SECRET_KEY=$(openssl rand -hex 32)
  GENERATED_INTERNAL_TOKEN=$(openssl rand -hex 64)
  GENERATED_OIDC_SECRET=$(openssl rand -base64 48 | tr -d '\n')
  kubectl create secret generic "${RUNTIME_SECRET}" \
    --namespace "${NAMESPACE}" \
    --from-literal=admin-username=admin \
    --from-literal=admin-password="${GENERATED_ADMIN_PASSWORD}" \
    --from-literal=secret-key="${GENERATED_SECRET_KEY}" \
    --from-literal=internal-token="${GENERATED_INTERNAL_TOKEN}" \
    --from-literal=oidc-client-id=gitea-package-registry \
    --from-literal=oidc-client-secret="${GENERATED_OIDC_SECRET}" >/dev/null
  unset GENERATED_ADMIN_PASSWORD GENERATED_SECRET_KEY
  unset GENERATED_INTERNAL_TOKEN GENERATED_OIDC_SECRET
  info "Generated runtime credentials in Secret/${RUNTIME_SECRET}"
fi

info "Installing or upgrading Gitea Package Registry"
helm upgrade --install "${RELEASE}" "${MODULE_DIR}/gitea-chart" \
  --namespace "${NAMESPACE}" \
  --values "${MODULE_DIR}/values.yaml" \
  --wait \
  --timeout 10m

kubectl rollout status deployment/gitea -n "${NAMESPACE}" --timeout=10m
GITEA_POD=$(kubectl get pods -n "${NAMESPACE}" \
  -l app.kubernetes.io/name=gitea,app.kubernetes.io/instance="${RELEASE}" \
  -o jsonpath='{.items[0].metadata.name}')

info "Creating or reconciling the local recovery administrator"
if ! kubectl exec -n "${NAMESPACE}" "${GITEA_POD}" -- /bin/sh -ec '
  password=$(cat /run/secrets/gitea/admin-password)
  gitea --config /etc/gitea/app.ini admin user create \
    --username admin \
    --password "${password}" \
    --email admin@kind.local \
    --admin \
    --must-change-password=false
' >/dev/null 2>&1; then
  kubectl exec -n "${NAMESPACE}" "${GITEA_POD}" -- /bin/sh -ec '
    password=$(cat /run/secrets/gitea/admin-password)
    gitea --config /etc/gitea/app.ini admin user change-password \
      --username admin \
      --password "${password}"
  ' >/dev/null
fi
kubectl exec -n "${NAMESPACE}" "${GITEA_POD}" -- \
  gitea --config /etc/gitea/app.ini admin user must-change-password \
  --unset admin >/dev/null

PF_LOG=$(mktemp "${TMPDIR:-/tmp}/gitea-port-forward.XXXXXX")
info "Starting a temporary Gitea API port-forward"
kubectl port-forward -n "${NAMESPACE}" "service/${SERVICE}" \
  "${LOCAL_PORT}:3000" >"${PF_LOG}" 2>&1 &
PF_PID=$!

for _ in $(seq 1 120); do
  if curl --fail --silent --show-error \
    "http://127.0.0.1:${LOCAL_PORT}/api/healthz" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kill -0 "${PF_PID}" 2>/dev/null || fail "Gitea port-forward exited unexpectedly"

GITEA_ADMIN_USERNAME=$(kubectl get secret "${RUNTIME_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.admin-username}' | base64 --decode)
GITEA_ADMIN_PASSWORD=$(kubectl get secret "${RUNTIME_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.admin-password}' | base64 --decode)

gitea_api() {
  local method=$1
  local path=$2
  shift 2
  curl --fail-with-body --silent --show-error \
    --request "${method}" \
    --user "${GITEA_ADMIN_USERNAME}:${GITEA_ADMIN_PASSWORD}" \
    --header 'Accept: application/json' \
    "http://127.0.0.1:${LOCAL_PORT}${path}" "$@"
}

create_organization() {
  local name=$1
  local full_name=$2
  local description=$3
  local status
  status=$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "${GITEA_ADMIN_USERNAME}:${GITEA_ADMIN_PASSWORD}" \
    "http://127.0.0.1:${LOCAL_PORT}/api/v1/orgs/${name}")
  if [[ "${status}" == "200" ]]; then
    info "Package namespace ${name} already exists"
    return
  fi
  [[ "${status}" == "404" ]] \
    || fail "Unexpected HTTP ${status} while checking package namespace ${name}"
  gitea_api POST /api/v1/orgs \
    --header 'Content-Type: application/json' \
    --data-binary "{\"username\":\"${name}\",\"full_name\":\"${full_name}\",\"description\":\"${description}\",\"visibility\":\"private\",\"repo_admin_change_team_access\":true}" \
    >/dev/null
  info "Created package namespace ${name}"
}

team_id() {
  local organization=$1
  local team_name=$2
  gitea_api GET "/api/v1/orgs/${organization}/teams?limit=50" \
    | TEAM_NAME="${team_name}" python3 -c \
      'import json,os,sys; print(next((str(t["id"]) for t in json.load(sys.stdin) if t["name"] == os.environ["TEAM_NAME"]), ""))'
}

upsert_team() {
  local organization=$1
  local team_name=$2
  local permission=$3
  local description=$4
  local id
  local method
  local path
  id=$(team_id "${organization}" "${team_name}")
  if [[ -n "${id}" ]]; then
    method=PATCH
    path="/api/v1/teams/${id}"
  else
    method=POST
    path="/api/v1/orgs/${organization}/teams"
  fi
  gitea_api "${method}" "${path}" \
    --header 'Content-Type: application/json' \
    --data-binary "{\"name\":\"${team_name}\",\"description\":\"${description}\",\"permission\":\"${permission}\",\"can_create_org_repo\":false,\"includes_all_repositories\":true,\"units\":[\"repo.packages\"],\"units_map\":{\"repo.packages\":\"${permission}\"},\"visibility\":\"private\"}" \
    >/dev/null
  info "Configured ${organization}/${team_name}"
}

while IFS='|' read -r name full_name description; do
  create_organization "${name}" "${full_name}" "${description}"
  upsert_team "${name}" Readers read "Read packages in ${name}"
  upsert_team "${name}" Publishers write "Upload and delete packages in ${name}"
done <<'ORGANIZATIONS'
devops|DevOps artifacts|General DevOps packages and files
docker-image|Docker images|OCI container image namespace
helm-charts|Helm charts|Packaged Helm charts
extra|Extra artifacts|Miscellaneous generic packages
maven-snapshot-team-a|Team A Maven snapshots|Team A Maven and JAR snapshots
maven-snapshot-team-b|Team B Maven snapshots|Team B Maven and JAR snapshots
ORGANIZATIONS

unset GITEA_ADMIN_PASSWORD
info "Gitea package namespaces and teams are ready"
info "Run ./configure-keycloak.sh to enable Keycloak SSO and group synchronization"
info "Admin password: kubectl get secret ${RUNTIME_SECRET} -n ${NAMESPACE} -o jsonpath='{.data.admin-password}' | base64 --decode"
