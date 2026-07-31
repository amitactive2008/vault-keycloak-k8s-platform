#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="artifactory"
ADMIN_SECRET="nexus-admin-credentials"
OIDC_SECRET="nexus-oidc-client"
LOCAL_PORT="18081"
PF_PID=""
KEYCLOAK_BASE_URL="https://keycloak.kind.local"
REALM="kind"

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

for command_name in kubectl curl python3; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done
kubectl cluster-info >/dev/null 2>&1 || fail "No reachable Kubernetes cluster"
kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Missing Secret/${ADMIN_SECRET}; run ./setup.sh first"
kubectl get secret "${OIDC_SECRET}" -n "${NAMESPACE}" >/dev/null 2>&1 \
  || fail "Missing Secret/${OIDC_SECRET}; run ./configure-keycloak.sh first"

NEXUS_ADMIN_PASSWORD=$(kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 --decode)
OIDC_CLIENT_ID=$(kubectl get secret "${OIDC_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.client-id}' | base64 --decode)
OIDC_CLIENT_SECRET=$(kubectl get secret "${OIDC_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.client-secret}' | base64 --decode)

kubectl port-forward -n "${NAMESPACE}" service/nexus \
  "${LOCAL_PORT}:8081" >/tmp/nexus-oidc-port-forward.log 2>&1 &
PF_PID=$!
for _ in $(seq 1 60); do
  if curl --fail --silent \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
kill -0 "${PF_PID}" 2>/dev/null || fail "Nexus port-forward exited unexpectedly"

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

LICENSE_STATUS=$(curl --silent --output /tmp/nexus-license-check.json \
  --write-out '%{http_code}' \
  --user "admin:${NEXUS_ADMIN_PASSWORD}" \
  "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/system/license")
if [[ "${LICENSE_STATUS}" != "200" ]]; then
  fail "No valid Nexus Repository Pro license is installed. Run ./install-license.sh /path/to/license.lic first."
fi

OIDC_PAYLOAD=$(
  OIDC_CLIENT_ID="${OIDC_CLIENT_ID}" \
  OIDC_CLIENT_SECRET="${OIDC_CLIENT_SECRET}" \
  KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL}" \
  REALM="${REALM}" \
  python3 <<'PY'
import json
import os

base = os.environ["KEYCLOAK_BASE_URL"]
realm = os.environ["REALM"]
protocol = f"{base}/realms/{realm}/protocol/openid-connect"
print(json.dumps({
    "idpJwksUrl": f"{protocol}/certs",
    "idpJwsAlgorithm": "RS256",
    "idpJwks": "",
    "usernameClaim": "preferred_username",
    "firstNameClaim": "given_name",
    "lastNameClaim": "family_name",
    "emailClaim": "email",
    "groupsClaim": "groups",
    "exactMatchClaims": {},
    "clientId": os.environ["OIDC_CLIENT_ID"],
    "clientSecret": os.environ["OIDC_CLIENT_SECRET"],
    "idpAuthorizationUrl": f"{protocol}/auth",
    "idpLogoutUrl": f"{protocol}/logout",
    "idpTokenUrl": f"{protocol}/token",
    "authorizationCustomParams": {},
    "tokenRequestCustomParams": {},
    "useTrustStore": False,
}, separators=(",", ":")))
PY
)

nexus_api PUT /service/rest/v1/security/oauth2 \
  --header 'Content-Type: application/json' \
  --data-binary "${OIDC_PAYLOAD}" >/dev/null

ACTIVE_REALMS=$(nexus_api GET /service/rest/v1/security/realms/active)
UPDATED_REALMS=$(ACTIVE_REALMS="${ACTIVE_REALMS}" python3 - <<'PY'
import json
import os

current = json.loads(os.environ["ACTIVE_REALMS"])
required = [
    "User-Token-Realm",
    "DockerToken",
    "OAuth2Realm",
    "NexusAuthenticatingRealm",
    "DefaultRole",
]
remaining = [realm for realm in current if realm not in required]
print(json.dumps(required + remaining, separators=(",", ":")))
PY
)
nexus_api PUT /service/rest/v1/security/realms/active \
  --header 'Content-Type: application/json' \
  --data-binary "${UPDATED_REALMS}" >/dev/null

OIDC_EFFECTIVE=$(nexus_api GET /service/rest/v1/security/oauth2)
OIDC_EFFECTIVE="${OIDC_EFFECTIVE}" python3 <<'PY'
import json
import os

configuration = json.loads(os.environ["OIDC_EFFECTIVE"])
expected = {
    "usernameClaim": "preferred_username",
    "groupsClaim": "groups",
    "idpJwsAlgorithm": "RS256",
}
for key, value in expected.items():
    if configuration.get(key) != value:
        raise SystemExit(f"OIDC verification failed: {key}")
print("OIDC configuration verified")
PY

unset NEXUS_ADMIN_PASSWORD OIDC_CLIENT_SECRET
info "Nexus Keycloak authentication is configured"
info "Role IDs devops, team-a, and team-b match the Keycloak group claim"
