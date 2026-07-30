#!/usr/bin/env bash
# Configure Vault policies and Kubernetes-auth roles for Jenkins agent pods.
# This script never writes runtime credentials. Seed the documented KV paths
# separately after the policies and roles exist.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_NAMESPACE="${VAULT_NAMESPACE:-vault}"
VAULT_POD="${VAULT_POD:-vault-0}"
VAULT_ADDR_INTERNAL="${VAULT_ADDR_INTERNAL:-http://127.0.0.1:8200}"
JENKINS_NAMESPACE="${JENKINS_NAMESPACE:-jenkins}"

if [[ -z "${VAULT_TOKEN:-}" ]]; then
  echo "ERROR: VAULT_TOKEN must contain a Vault administrator token." >&2
  echo "Export it only for this shell, run the script, then unset it." >&2
  exit 1
fi

vault_exec() {
  kubectl exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR_INTERNAL" VAULT_TOKEN="$VAULT_TOKEN" \
    vault "$@"
}

write_policy() {
  local policy_name="$1"
  local policy_file="$2"

  kubectl exec -i -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
    env VAULT_ADDR="$VAULT_ADDR_INTERNAL" VAULT_TOKEN="$VAULT_TOKEN" \
    vault policy write "$policy_name" - < "$policy_file"
}

kubectl get namespace "$VAULT_NAMESPACE" >/dev/null
kubectl get namespace "$JENKINS_NAMESPACE" >/dev/null
kubectl get serviceaccount jenkins-ci -n "$JENKINS_NAMESPACE" >/dev/null
kubectl get serviceaccount jenkins-cd-external -n "$JENKINS_NAMESPACE" >/dev/null
kubectl get serviceaccount jenkins-ci-team-b -n "$JENKINS_NAMESPACE" >/dev/null

if ! vault_exec auth list -format=json | grep -q '"kubernetes/"'; then
  vault_exec auth enable kubernetes
fi

KV_VERSION="$(
  vault_exec secrets list -format=json |
    python3 -c 'import json,sys; print(json.load(sys.stdin).get("secret/", {}).get("options", {}).get("version", ""))'
)"
if [[ -z "$KV_VERSION" ]]; then
  vault_exec secrets enable -path=secret -version=2 kv
elif [[ "$KV_VERSION" != "2" ]]; then
  echo "ERROR: Vault mount secret/ exists but is not KV v2." >&2
  exit 1
fi

KUBERNETES_CA_CERT="$(
  kubectl get configmap kube-root-ca.crt -n "$VAULT_NAMESPACE" \
    -o jsonpath='{.data.ca\.crt}'
)"

vault_exec write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc.cluster.local:443" \
  kubernetes_ca_cert="$KUBERNETES_CA_CERT"

write_policy "jenkins-ci" \
  "${SCRIPT_DIR}/vault/policies/jenkins-ci.hcl"
write_policy "jenkins-cd-external" \
  "${SCRIPT_DIR}/vault/policies/jenkins-cd-external.hcl"
write_policy "jenkins-ci-team-b" \
  "${SCRIPT_DIR}/vault/policies/jenkins-ci-team-b.hcl"

vault_exec write auth/kubernetes/role/jenkins-ci \
  bound_service_account_names="jenkins-ci" \
  bound_service_account_namespaces="$JENKINS_NAMESPACE" \
  policies="jenkins-ci" \
  ttl="30m"

vault_exec write auth/kubernetes/role/jenkins-cd-external \
  bound_service_account_names="jenkins-cd-external" \
  bound_service_account_namespaces="$JENKINS_NAMESPACE" \
  policies="jenkins-cd-external" \
  ttl="30m"

vault_exec write auth/kubernetes/role/jenkins-ci-team-b \
  bound_service_account_names="jenkins-ci-team-b" \
  bound_service_account_namespaces="$JENKINS_NAMESPACE" \
  policies="jenkins-ci-team-b" \
  ttl="30m"

echo
echo "Vault policies and Kubernetes-auth roles configured."
echo "Seed these KV v2 paths before starting Jenkins jobs:"
echo "  secret/devops/jenkins/ci"
echo "  secret/devops/jenkins/clusters/external"
echo "  secret/team-b/jenkins/ci"
echo
echo "Required CI keys: dockerhub_username, dockerhub_token, nvd_api_key"
echo "Required CD key:  kubeconfig"
echo "Required Team B CI keys: dockerhub_username, dockerhub_token"
