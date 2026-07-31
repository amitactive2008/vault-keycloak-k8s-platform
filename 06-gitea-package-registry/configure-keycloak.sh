#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_NAMESPACE="keycloak"
GITEA_NAMESPACE="artifactory"
REALM="kind"
CLIENT_ID="gitea-package-registry"
RUNTIME_SECRET="gitea-runtime-credentials"
GITEA_URL="https://gitea.kind.local"
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD="Admin@Keycloak2024!"
READERS_GROUP="artifact-readers"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in kubectl python3; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done
kubectl cluster-info >/dev/null 2>&1 || fail "No reachable Kubernetes cluster"
kubectl get secret "${RUNTIME_SECRET}" -n "${GITEA_NAMESPACE}" >/dev/null 2>&1 \
  || fail "Secret/${RUNTIME_SECRET} was not found; run ./setup.sh first"

KEYCLOAK_POD=$(kubectl get pods -n "${KEYCLOAK_NAMESPACE}" \
  -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "${KEYCLOAK_POD}" ]] || fail "No Keycloak pod was found"
GITEA_POD=$(kubectl get pods -n "${GITEA_NAMESPACE}" \
  -l app.kubernetes.io/name=gitea,app.kubernetes.io/instance=gitea \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "${GITEA_POD}" ]] || fail "No Gitea pod was found"

kcadm() {
  kubectl exec -n "${KEYCLOAK_NAMESPACE}" "${KEYCLOAK_POD}" -- \
    /opt/keycloak/bin/kcadm.sh "$@"
}

CLIENT_SECRET=$(kubectl get secret "${RUNTIME_SECRET}" -n "${GITEA_NAMESPACE}" \
  -o jsonpath='{.data.oidc-client-secret}' | base64 --decode)
STORED_CLIENT_ID=$(kubectl get secret "${RUNTIME_SECRET}" -n "${GITEA_NAMESPACE}" \
  -o jsonpath='{.data.oidc-client-id}' | base64 --decode)
[[ "${STORED_CLIENT_ID}" == "${CLIENT_ID}" ]] \
  || fail "Runtime Secret client ID does not match ${CLIENT_ID}"

kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "${KEYCLOAK_ADMIN_USER}" \
  --password "${KEYCLOAK_ADMIN_PASSWORD}" >/dev/null

CLIENT_UUID=$(kcadm get clients -r "${REALM}" -q "clientId=${CLIENT_ID}" \
  --fields id,clientId 2>/dev/null \
  | python3 -c 'import json,sys; clients=json.load(sys.stdin); print(clients[0]["id"] if clients else "")')

if [[ -z "${CLIENT_UUID}" ]]; then
  CLIENT_UUID=$(kcadm create clients -r "${REALM}" -i \
    -s clientId="${CLIENT_ID}" \
    -s name="Gitea Package Registry" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret="${CLIENT_SECRET}" \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["https://gitea.kind.local/user/oauth2/keycloak/callback"]' \
    -s 'webOrigins=["https://gitea.kind.local"]' \
    -s 'attributes={"post.logout.redirect.uris":"https://gitea.kind.local/*"}')
  info "Created Keycloak client ${CLIENT_ID}"
else
  kcadm update "clients/${CLIENT_UUID}" -r "${REALM}" \
    -s name="Gitea Package Registry" \
    -s enabled=true \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret="${CLIENT_SECRET}" \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["https://gitea.kind.local/user/oauth2/keycloak/callback"]' \
    -s 'webOrigins=["https://gitea.kind.local"]' \
    -s 'attributes={"post.logout.redirect.uris":"https://gitea.kind.local/*"}'
  info "Updated Keycloak client ${CLIENT_ID}"
fi

MAPPERS=$(kcadm get "clients/${CLIENT_UUID}/protocol-mappers/models" -r "${REALM}")
GROUPS_MAPPER_ID=$(MAPPERS="${MAPPERS}" python3 - <<'PY'
import json
import os
for mapper in json.loads(os.environ["MAPPERS"]):
    if mapper.get("name") == "groups":
        print(mapper["id"])
        break
PY
)
if [[ -n "${GROUPS_MAPPER_ID}" ]]; then
  kcadm update "clients/${CLIENT_UUID}/protocol-mappers/models/${GROUPS_MAPPER_ID}" \
    -r "${REALM}" \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s consentRequired=false \
    -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","claim.name":"groups"}' \
    >/dev/null
  info "Updated the flat groups claim mapper"
else
  kcadm create "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "${REALM}" \
    -s name=groups \
    -s protocol=openid-connect \
    -s protocolMapper=oidc-group-membership-mapper \
    -s consentRequired=false \
    -s 'config={"full.path":"false","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","claim.name":"groups"}' \
    >/dev/null
  info "Created the flat groups claim mapper"
fi

KEYCLOAK_GROUPS_JSON=$(kcadm get groups -r "${REALM}" -q "search=${READERS_GROUP}")
READERS_GROUP_ID=$(KEYCLOAK_GROUPS_JSON="${KEYCLOAK_GROUPS_JSON}" \
  READERS_GROUP="${READERS_GROUP}" python3 - <<'PY'
import json
import os
for group in json.loads(os.environ["KEYCLOAK_GROUPS_JSON"]):
    if group.get("name") == os.environ["READERS_GROUP"]:
        print(group["id"])
        break
PY
)
if [[ -z "${READERS_GROUP_ID}" ]]; then
  READERS_GROUP_ID=$(kcadm create groups -r "${REALM}" -i -s name="${READERS_GROUP}")
  info "Created Keycloak group ${READERS_GROUP}"
fi

DEFAULT_GROUPS=$(kcadm get default-groups -r "${REALM}")
if ! DEFAULT_GROUPS="${DEFAULT_GROUPS}" READERS_GROUP_ID="${READERS_GROUP_ID}" \
  python3 -c 'import json,os,sys; sys.exit(0 if any(g["id"] == os.environ["READERS_GROUP_ID"] for g in json.loads(os.environ["DEFAULT_GROUPS"])) else 1)'; then
  kcadm update "default-groups/${READERS_GROUP_ID}" -r "${REALM}" >/dev/null
  info "Configured ${READERS_GROUP} as a default group for new users"
fi

USERS=$(kcadm get users -r "${REALM}" -q max=1000 --fields id,username)
while IFS=$'\t' read -r user_id username; do
  [[ -n "${user_id}" ]] || continue
  kcadm update "users/${user_id}/groups/${READERS_GROUP_ID}" \
    -r "${REALM}" >/dev/null
  info "Ensured ${username} belongs to ${READERS_GROUP}"
done < <(
  USERS="${USERS}" python3 -c \
    'import json,os; [print(f"{u['"'"'id'"'"']}\t{u['"'"'username'"'"']}") for u in json.loads(os.environ["USERS"])]'
)

GROUP_TEAM_MAP='{"artifact-readers":{"devops":["Readers"],"docker-image":["Readers"],"helm-charts":["Readers"],"extra":["Readers"],"maven-snapshot-team-a":["Readers"],"maven-snapshot-team-b":["Readers"]},"devops":{"devops":["Publishers"],"docker-image":["Publishers"],"helm-charts":["Publishers"],"extra":["Publishers"],"maven-snapshot-team-a":["Publishers"],"maven-snapshot-team-b":["Publishers"]},"team-a":{"maven-snapshot-team-a":["Publishers"]},"team-b":{"maven-snapshot-team-b":["Publishers"]}}'
DISCOVERY_URL="https://keycloak.kind.local/realms/${REALM}/.well-known/openid-configuration"

kubectl exec -i -n "${GITEA_NAMESPACE}" "${GITEA_POD}" -- \
  /bin/sh -s -- "${DISCOVERY_URL}" "${GROUP_TEAM_MAP}" <<'POD_SCRIPT'
set -eu
discovery_url=$1
group_team_map=$2
client_id=$(cat /run/secrets/gitea/oidc-client-id)
client_secret=$(cat /run/secrets/gitea/oidc-client-secret)
config=/etc/gitea/app.ini

auth_id=$(
  gitea --config "${config}" admin auth list \
    | sed -n 's/^[^0-9]*\([0-9][0-9]*\)[^[:alnum:]]*keycloak.*/\1/p' \
    | head -n 1
)

if [ -n "${auth_id}" ]; then
  gitea --config "${config}" admin auth update-oauth \
    --id "${auth_id}" \
    --name keycloak \
    --provider openidConnect \
    --key "${client_id}" \
    --secret "${client_secret}" \
    --auto-discover-url "${discovery_url}" \
    --scopes profile,email \
    --group-claim-name groups \
    --group-team-map "${group_team_map}" \
    --group-team-map-removal
else
  gitea --config "${config}" admin auth add-oauth \
    --name keycloak \
    --provider openidConnect \
    --key "${client_id}" \
    --secret "${client_secret}" \
    --auto-discover-url "${discovery_url}" \
    --scopes profile,email \
    --group-claim-name groups \
    --group-team-map "${group_team_map}" \
    --group-team-map-removal
fi
POD_SCRIPT

unset CLIENT_SECRET
info "Restarting Gitea to reload the OIDC authentication source"
kubectl rollout restart deployment/gitea -n "${GITEA_NAMESPACE}" >/dev/null
kubectl rollout status deployment/gitea -n "${GITEA_NAMESPACE}" --timeout=10m
info "Keycloak SSO is ready for ${GITEA_URL}"
