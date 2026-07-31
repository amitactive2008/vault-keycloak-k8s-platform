#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_NAMESPACE="keycloak"
NEXUS_NAMESPACE="artifactory"
REALM="kind"
CLIENT_ID="nexus-repository"
CLIENT_SECRET_NAME="nexus-oidc-client"
NEXUS_URL="https://nexus.kind.local"
KEYCLOAK_ADMIN_USER="admin"
KEYCLOAK_ADMIN_PASSWORD="Admin@Keycloak2024!"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

for command_name in kubectl openssl python3; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done
kubectl cluster-info >/dev/null 2>&1 || fail "No reachable Kubernetes cluster"
kubectl get namespace "${NEXUS_NAMESPACE}" >/dev/null 2>&1 \
  || fail "Namespace ${NEXUS_NAMESPACE} does not exist; run ./setup.sh first"

KEYCLOAK_POD=$(kubectl get pods -n "${KEYCLOAK_NAMESPACE}" \
  -l app=keycloak -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[[ -n "${KEYCLOAK_POD}" ]] || fail "No Keycloak pod was found"

kcadm() {
  kubectl exec -i -n "${KEYCLOAK_NAMESPACE}" "${KEYCLOAK_POD}" -- \
    /opt/keycloak/bin/kcadm.sh "$@"
}

if ! kubectl get secret "${CLIENT_SECRET_NAME}" -n "${NEXUS_NAMESPACE}" >/dev/null 2>&1; then
  CLIENT_SECRET=$(openssl rand -base64 48 | tr -d '\n')
  kubectl create secret generic "${CLIENT_SECRET_NAME}" \
    --namespace "${NEXUS_NAMESPACE}" \
    --from-literal=client-id="${CLIENT_ID}" \
    --from-literal=client-secret="${CLIENT_SECRET}" >/dev/null
  unset CLIENT_SECRET
  info "Generated OIDC client credentials in Secret/${CLIENT_SECRET_NAME}"
fi

CLIENT_SECRET=$(kubectl get secret "${CLIENT_SECRET_NAME}" -n "${NEXUS_NAMESPACE}" \
  -o jsonpath='{.data.client-secret}' | base64 --decode)

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
    -s name="Sonatype Nexus Repository" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret="${CLIENT_SECRET}" \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["https://nexus.kind.local/oidc/callback*"]' \
    -s 'webOrigins=["https://nexus.kind.local"]' \
    -s 'attributes={"post.logout.redirect.uris":"https://nexus.kind.local/*"}')
  info "Created Keycloak client ${CLIENT_ID}"
else
  kcadm update "clients/${CLIENT_UUID}" -r "${REALM}" \
    -s name="Sonatype Nexus Repository" \
    -s enabled=true \
    -s publicClient=false \
    -s clientAuthenticatorType=client-secret \
    -s secret="${CLIENT_SECRET}" \
    -s standardFlowEnabled=true \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s 'redirectUris=["https://nexus.kind.local/oidc/callback*"]' \
    -s 'webOrigins=["https://nexus.kind.local"]' \
    -s 'attributes={"post.logout.redirect.uris":"https://nexus.kind.local/*"}'
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

unset CLIENT_SECRET
info "Keycloak OIDC client is ready for ${NEXUS_URL}"
