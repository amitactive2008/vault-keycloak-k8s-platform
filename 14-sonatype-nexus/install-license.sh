#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="artifactory"
ADMIN_SECRET="nexus-admin-credentials"
LOCAL_PORT="18081"
PF_PID=""

info() { printf '[INFO] %s\n' "$*"; }
fail() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "${PF_PID}" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    wait "${PF_PID}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

[[ $# -eq 1 ]] || fail "Usage: $0 /absolute/path/to/nexus-license.lic"
LICENSE_FILE=$1
[[ "${LICENSE_FILE}" = /* ]] || fail "Use an absolute license file path"
[[ -f "${LICENSE_FILE}" ]] || fail "License file not found: ${LICENSE_FILE}"

for command_name in kubectl curl; do
  command -v "${command_name}" >/dev/null 2>&1 \
    || fail "Required command not found: ${command_name}"
done

NEXUS_ADMIN_PASSWORD=$(kubectl get secret "${ADMIN_SECRET}" -n "${NAMESPACE}" \
  -o jsonpath='{.data.password}' | base64 --decode)
kubectl port-forward -n "${NAMESPACE}" service/nexus \
  "${LOCAL_PORT}:8081" >/tmp/nexus-license-port-forward.log 2>&1 &
PF_PID=$!
for _ in $(seq 1 60); do
  if curl --fail --silent \
    "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/status" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

info "Installing the supplied Nexus Repository license"
curl --fail-with-body --silent --show-error \
  --request POST \
  --user "admin:${NEXUS_ADMIN_PASSWORD}" \
  --header 'Content-Type: application/octet-stream' \
  --header 'Accept: application/json' \
  --data-binary "@${LICENSE_FILE}" \
  "http://127.0.0.1:${LOCAL_PORT}/service/rest/v1/system/license" >/dev/null

cleanup
PF_PID=""
kubectl rollout restart deployment/nexus -n "${NAMESPACE}"
kubectl rollout status deployment/nexus -n "${NAMESPACE}" --timeout=15m
unset NEXUS_ADMIN_PASSWORD
info "Nexus Repository Pro license installed and deployment restarted"

