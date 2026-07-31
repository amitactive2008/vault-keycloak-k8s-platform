#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

info() { printf '[validate] %s\n' "$*"; }
fail() { printf '[validate] ERROR: %s\n' "$*" >&2; exit 1; }

info "checking for unresolved merge conflicts"
if rg -n --hidden -g '!.git/**' '^(<<<<<<<|=======|>>>>>>>)' .; then
  fail "unresolved merge-conflict marker found"
fi

info "checking for generated credentials and private keys"
for sensitive_file in \
  02-vault/cluster-keys.json \
  05-k8s-oidc-with-keycloak/kubeconfig-oidc.yaml \
  05-k8s-oidc-with-keycloak/keycloak-local-ca.crt \
  08-jenkins/setup/credentials.yaml; do
  if [[ -e "$sensitive_file" ]] && ! git check-ignore -q "$sensitive_file"; then
    fail "$sensitive_file exists but is not ignored"
  fi
done
if rg -n --hidden -g '!.git/**' -g '!*.example' -g '!*-template.yaml' \
  'BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY' .; then
  fail "private key material found"
fi

info "checking whitespace"
git diff --check

info "checking Bash syntax"
while IFS= read -r -d '' script; do
  bash -n "$script"
done < <(find . -type f -name '*.sh' -not -path './.git/*' -print0)

info "checking JSON syntax"
while IFS= read -r -d '' document; do
  python3 -m json.tool "$document" >/dev/null
done < <(find . -type f -name '*.json' -not -path './.git/*' -print0)

info "checking YAML syntax"
if command -v ruby >/dev/null 2>&1; then
  while IFS= read -r -d '' document; do
    ruby -e 'require "yaml"; YAML.load_stream(File.read(ARGV.fetch(0)))' "$document"
  done < <(
    find . -type f \( -name '*.yaml' -o -name '*.yml' \) \
      -not -path './.git/*' \
      -not -path '*/templates/*' \
      -print0
  )
else
  info "SKIP YAML syntax (ruby not installed)"
fi

info "checking local Markdown links"
python3 scripts/check_markdown_links.py

if command -v helm >/dev/null 2>&1; then
  info "linting Helm charts"
  helm lint 03-keycloak/keycloak-chart -f 03-keycloak/values.yaml
  helm lint 06-application/team-a-webapp/webapp-chart \
    -f 06-application/team-a-webapp/values.yaml
  helm lint 10-ai-bankapp/AI-BankApp-DevOps/helm/ai-bankapp \
    -f 10-ai-bankapp/AI-BankApp-DevOps/helm/team-b-values.yaml
  helm lint 14-sonatype-nexus/nexus-chart \
    -f 14-sonatype-nexus/values.yaml
else
  info "SKIP Helm lint (helm not installed)"
fi

if command -v kubectl >/dev/null 2>&1; then
  info "building Kustomize overlays"
  while IFS= read -r kustomization; do
    kubectl kustomize "$(dirname "$kustomization")" >/dev/null
  done < <(find . -type f -name 'kustomization.yaml' -not -path './.git/*' | sort)
else
  info "SKIP Kustomize builds (kubectl not installed)"
fi

info "all checks passed"
