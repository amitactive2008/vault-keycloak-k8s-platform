#!/usr/bin/env bash
# ============================================================
# setup.sh — Vault ↔ Keycloak OIDC integration
#
# What this does:
#   1. Patches CoreDNS so Vault pods can resolve keycloak.kind.local
#      (Vault's token exchange call must reach Keycloak internally)
#   2. Creates a confidential OIDC client "vault" in the kind realm
#      with a groups claim mapper (full path: /devops, /team-a, /team-b)
#   3. Enables KV v2 secret engine at path "secret/"
#   4. Writes Vault policies (devops / team-a / team-b)
#   5. Enables and configures the OIDC auth method pointing at Keycloak
#   6. Creates an OIDC role "default" that reads the "groups" JWT claim
#   7. Creates Vault external identity groups + OIDC group aliases so
#      Keycloak group membership drives Vault policy assignment
#   8. Seeds sample secrets for each team to verify access
#
# Access matrix after setup:
#   devops  group → devops-policy  → ALL paths  (*)
#   team-a  group → team-a-policy  → secret/data/team-a/*
#   team-b  group → team-b-policy  → secret/data/team-b/*
#
# Usage:
#   cd keycloak/vault-integration/
#   chmod +x setup.sh
#   ./setup.sh
#
# Requires: kubectl, python3
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="${SCRIPT_DIR}/../02-vault"

# ── Configuration ──────────────────────────────────────────────
ROOT_TOKEN=$(python3 -c "
import json
with open('${DEPLOY_DIR}/cluster-keys.json') as f:
    print(json.load(f)['root_token'])
")
VAULT_NS="vault"
KC_NS="keycloak"
KC_REALM="kind"
KC_ADMIN_PASS="Admin@Keycloak2024!"
KC_EXTERNAL_URL="https://keycloak.kind.local"
VAULT_EXTERNAL_URL="https://vault.kind.local"
OIDC_CLIENT_ID="vault"
OIDC_CLIENT_SECRET="Vault@Keycloak2024!"
# CA cert for Keycloak's TLS — issued by cert-manager (kind-local-ca-issuer).
# Vault needs it to verify HTTPS connections to Keycloak from inside the cluster.
# Extracted from the cert-manager CA secret at runtime (no file path dependency).
_CM_CA_SECRET="kind-local-ca-secret"
_CM_NS="cert-manager"
OIDC_CA_CERT_FILE="/tmp/kind-local-ca-oidc.crt"
# vault-active service — always points to the active Vault node
VAULT_ACTIVE_ADDR="http://vault-active.vault.svc.cluster.local:8200"

# ── Helpers ────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# ── Step 0: Prereqs ─────────────────────────────────────────────
section "Step 0 — Checking prerequisites"
for cmd in kubectl python3; do
  command -v "$cmd" &>/dev/null || { error "$cmd not found"; exit 1; }
  info "$cmd → $(command -v "$cmd")"
done
kubectl cluster-info &>/dev/null || { error "No cluster found. Is kind running?"; exit 1; }
info "Cluster : $(kubectl config current-context)"
info "Vault NS: $VAULT_NS  |  Keycloak NS: $KC_NS"

# Extract the CA cert from cert-manager's CA secret.
# cert-manager stores the CA in the cert-manager namespace (required for ClusterIssuer).
# Vault uses this to verify HTTPS connections to keycloak.kind.local.
info "Extracting CA cert from cert-manager secret ${_CM_NS}/${_CM_CA_SECRET}..."
if kubectl get secret "${_CM_CA_SECRET}" -n "${_CM_NS}" &>/dev/null; then
  kubectl get secret "${_CM_CA_SECRET}" -n "${_CM_NS}" \
    -o jsonpath='{.data.tls\.crt}' | base64 -d > "${OIDC_CA_CERT_FILE}"
  _CA_FP=$(openssl x509 -noout -fingerprint -sha256 < "${OIDC_CA_CERT_FILE}" 2>/dev/null | sed 's/.*=//')
  info "CA cert extracted → ${OIDC_CA_CERT_FILE} ($(wc -l < "${OIDC_CA_CERT_FILE}") lines) SHA256: ${_CA_FP} ✓"
  # Warn if the CA cert in Vault is already configured but differs from the current one.
  # This indicates a CA rotation — Vault's OIDC config must be updated (which this script does).
  _VAULT_CA_FP=$(kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
    export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
    export VAULT_TOKEN=${ROOT_TOKEN:-placeholder}
    vault read -field=oidc_discovery_ca_pem auth/oidc/config 2>/dev/null
  " 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' || true)
  if [ -n "$_VAULT_CA_FP" ] && [ "$_VAULT_CA_FP" != "$_CA_FP" ]; then
    warn "CA cert mismatch detected! Vault OIDC config has a stale CA (fingerprint: ${_VAULT_CA_FP})."
    warn "The cert-manager CA was rotated. This script will update Vault's OIDC config with the new CA."
  fi
else
  warn "cert-manager CA secret '${_CM_CA_SECRET}' not found in '${_CM_NS}' — OIDC TLS verification will be skipped"
  warn "Ensure cert-manager is installed and 01-cloud-provider-kind-setup-with-gw-api setup is complete."
  OIDC_CA_CERT_FILE=""
fi

# ── Step 1: CoreDNS patch ───────────────────────────────────────
# Vault pods are in-cluster and cannot resolve "keycloak.kind.local" (host /etc/hosts
# is not visible inside pods). We inject a hosts entry into CoreDNS so that
# https://keycloak.kind.local resolves to the Envoy Gateway ClusterIP from any pod.
section "Step 1 — Patching CoreDNS to resolve keycloak.kind.local inside the cluster"

# Vault pods need to reach https://keycloak.kind.local. CoreDNS must resolve
# keycloak.kind.local to the Envoy Gateway ClusterIP — the only endpoint that
# handles HTTPS (TLS termination on port 443) for *.kind.local.
GW_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=native-gateway \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$GW_SVC" ]; then
  GW_SVC=$(kubectl get svc -n envoy-gateway-system \
    --field-selector spec.type=LoadBalancer \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
fi
GW_IP=$(kubectl get svc -n envoy-gateway-system "$GW_SVC" -o jsonpath='{.spec.clusterIP}')
info "Envoy Gateway ClusterIP: $GW_IP  (handles HTTPS for *.kind.local)"

# If keycloak.kind.local is already in CoreDNS and points to the correct GW IP, skip.
CURRENT_CORE_ENTRY=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' 2>/dev/null | grep "keycloak.kind.local" || true)
if echo "$CURRENT_CORE_ENTRY" | grep -q "$GW_IP"; then
  warn "CoreDNS already has keycloak.kind.local → $GW_IP — skipping patch"
else
  info "Writing CoreDNS ConfigMap with keycloak.kind.local → $GW_IP (Envoy Gateway, HTTPS)..."

  # Write the full Corefile using kubectl apply (safe, no variable-in-heredoc issues).
  # This is the standard kind CoreDNS config with an added hosts block.
  kubectl apply -f - << YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
           lameduck 5s
        }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
           pods insecure
           fallthrough in-addr.arpa ip6.arpa
           ttl 30
        }
        hosts {
           ${GW_IP} keycloak.kind.local
           fallthrough
        }
        prometheus :9153
        forward . /etc/resolv.conf {
           max_concurrent 1000
        }
        cache 30
        loop
        reload
        loadbalance
    }
YAML

  info "CoreDNS ConfigMap applied. Restarting CoreDNS..."
  kubectl rollout restart deployment/coredns -n kube-system
  kubectl rollout status deployment/coredns -n kube-system --timeout=120s
  info "CoreDNS restarted. Waiting 5 s for DNS propagation..."
  sleep 5
fi

# Quick smoke-test: can a vault pod resolve keycloak.kind.local?
RESOLVE_RESULT=$(kubectl exec -n "$VAULT_NS" vault-0 -- \
  sh -c "nslookup keycloak.kind.local 2>&1 || getent hosts keycloak.kind.local 2>&1 || echo UNRESOLVED")
if echo "$RESOLVE_RESULT" | grep -qiE "$GW_IP|address"; then
  info "DNS check passed — keycloak.kind.local resolves from vault-0 ✓"
else
  warn "DNS check inconclusive ($RESOLVE_RESULT). Proceeding anyway..."
fi

# ── Step 2: Keycloak OIDC client ────────────────────────────────
section "Step 2 — Creating Keycloak OIDC client 'vault' in realm '$KC_REALM'"

KC_POD=$(kubectl get pod -n "$KC_NS" -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}')
info "Keycloak pod: $KC_POD"

# Authenticate kcadm
kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "$KC_ADMIN_PASS"

# Check if client already exists
CLIENT_EXISTS=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
  --fields clientId 2>/dev/null | grep -c '"vault"' || true)

if [ "$CLIENT_EXISTS" -gt 0 ]; then
  warn "Keycloak client 'vault' already exists — skipping creation"
else
  info "Creating confidential OIDC client 'vault'..."
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh create clients -r "$KC_REALM" \
    -s clientId="${OIDC_CLIENT_ID}" \
    -s enabled=true \
    -s protocol=openid-connect \
    -s publicClient=false \
    -s standardFlowEnabled=true \
    -s implicitFlowEnabled=false \
    -s directAccessGrantsEnabled=false \
    -s serviceAccountsEnabled=false \
    -s secret="${OIDC_CLIENT_SECRET}" \
    -s "redirectUris=[\"${VAULT_EXTERNAL_URL}/ui/vault/auth/oidc/oidc/callback\",\"http://localhost:8250/oidc/callback\"]" \
    -s "webOrigins=[\"${VAULT_EXTERNAL_URL}\"]"
  info "Client 'vault' created."
fi

# Retrieve client UUID
CLIENT_UUID=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get clients -r "$KC_REALM" \
  --fields id,clientId 2>/dev/null \
  | grep -B1 '"vault"' | grep '"id"' | head -1 | awk -F'"' '{print $4}')
info "Client UUID: $CLIENT_UUID"

# Always sync the redirect URIs — covers both fresh creates and re-runs where
# the client already existed with stale (http-only) redirect URIs.
info "Syncing redirectUris and webOrigins on client 'vault'..."
kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh update "clients/${CLIENT_UUID}" -r "$KC_REALM" \
  -s "redirectUris=[\"${VAULT_EXTERNAL_URL}/ui/vault/auth/oidc/oidc/callback\",\"http://vault.kind.local/ui/vault/auth/oidc/oidc/callback\",\"https://localhost:8250/oidc/callback\",\"http://localhost:8250/oidc/callback\"]" \
  -s "webOrigins=[\"${VAULT_EXTERNAL_URL}\",\"http://vault.kind.local\"]"
info "redirectUris updated."

# Add groups claim mapper (full path: /devops, /team-a, /team-b in the JWT)
MAPPER_COUNT=$(kubectl exec -n "$KC_NS" "$KC_POD" -- \
  /opt/keycloak/bin/kcadm.sh get \
  "clients/${CLIENT_UUID}/protocol-mappers/models" \
  -r "$KC_REALM" 2>/dev/null | grep -c '"groups"' || true)

if [ "$MAPPER_COUNT" -gt 0 ]; then
  warn "Groups mapper already exists on client 'vault' — skipping"
else
  info "Adding group-membership (full path) mapper to 'vault' client..."

  # Write mapper JSON to a temp file in the pod and apply it
  kubectl exec -n "$KC_NS" "$KC_POD" -- sh -c '
cat > /tmp/mapper.json << EOF
{
  "name": "groups",
  "protocol": "openid-connect",
  "protocolMapper": "oidc-group-membership-mapper",
  "config": {
    "full.path": "true",
    "id.token.claim": "true",
    "access.token.claim": "true",
    "userinfo.token.claim": "true",
    "claim.name": "groups",
    "multivalued": "true"
  }
}
EOF
'

  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh create \
    "clients/${CLIENT_UUID}/protocol-mappers/models" \
    -r "$KC_REALM" -f /tmp/mapper.json

  kubectl exec -n "$KC_NS" "$KC_POD" -- rm -f /tmp/mapper.json
  info "Groups mapper added. JWT will include 'groups': [\"/devops\", ...]"
fi

# ── Step 3: KV v2 secret engine ─────────────────────────────────
section "Step 3 — Enabling KV v2 at 'secret/'"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault secrets enable -path=secret kv-v2 2>/dev/null \
    && echo 'KV v2 enabled at secret/' \
    || echo 'KV v2 at secret/ already enabled'
"

# ── Step 4: Vault policies ──────────────────────────────────────
section "Step 4 — Writing Vault policies"

# Copy HCL policy files into the pod then write them
for TEAM in devops team-a team-b; do
  info "Writing policy: ${TEAM}-policy"
  kubectl cp "${SCRIPT_DIR}/policies/${TEAM}.hcl" \
    "${VAULT_NS}/vault-0:/tmp/${TEAM}.hcl"
  kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
    export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
    export VAULT_TOKEN=${ROOT_TOKEN}
    vault policy write ${TEAM}-policy /tmp/${TEAM}.hcl
    rm /tmp/${TEAM}.hcl
  "
done

# ── Step 5: OIDC auth method ────────────────────────────────────
section "Step 5 — Enabling and configuring OIDC auth method"

# Build the OIDC config as a JSON file locally so the multiline CA cert PEM is
# correctly JSON-encoded (inline shell expansion breaks on cert newlines).
OIDC_CONFIG_JSON=$(mktemp /tmp/vault-oidc-config.XXXXXX.json)
python3 - << PYEOF
import json
ca = open("${OIDC_CA_CERT_FILE}").read() if __import__('os').path.exists("${OIDC_CA_CERT_FILE}") else ""
cfg = {
    "oidc_discovery_url":    "${KC_EXTERNAL_URL}/realms/${KC_REALM}",
    "oidc_discovery_ca_pem": ca,
    "oidc_client_id":        "${OIDC_CLIENT_ID}",
    "oidc_client_secret":    "${OIDC_CLIENT_SECRET}",
    "default_role":          "default"
}
with open("${OIDC_CONFIG_JSON}", "w") as f:
    json.dump(cfg, f)
PYEOF
info "OIDC config JSON built (CA cert lines: $(python3 -c "import json; d=json.load(open('${OIDC_CONFIG_JSON}')); print(d['oidc_discovery_ca_pem'].count(chr(10)))"))"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault auth enable oidc 2>/dev/null \
    && echo 'OIDC auth method enabled' \
    || echo 'OIDC auth method already enabled'
"

# Copy the JSON config into the pod and apply it with @file (safe multiline handling)
kubectl cp "${OIDC_CONFIG_JSON}" "${VAULT_NS}/vault-0:/tmp/vault-oidc-config.json"
kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}
  vault write auth/oidc/config @/tmp/vault-oidc-config.json
  rm /tmp/vault-oidc-config.json
"
rm -f "${OIDC_CONFIG_JSON}"
info "OIDC auth configured → ${KC_EXTERNAL_URL}/realms/${KC_REALM}"

# ── Step 6: OIDC role ───────────────────────────────────────────
section "Step 6 — Creating OIDC role 'default'"
# This role:
#   • extracts the user subject from the 'sub' claim
#   • reads group membership from the 'groups' claim (set by Keycloak mapper)
#   • grants only the base 'default' policy; group-specific policies are
#     attached via the external group aliases created in the next step

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c '
  export VAULT_ADDR='"${VAULT_ACTIVE_ADDR}"'
  export VAULT_TOKEN='"${ROOT_TOKEN}"'

  cat > /tmp/oidc-role.json << EOF
{
  "bound_audiences": ["'"${OIDC_CLIENT_ID}"'"],
  "allowed_redirect_uris": [
    "'"${VAULT_EXTERNAL_URL}"'/ui/vault/auth/oidc/oidc/callback",
    "https://vault.kind.local/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
    "https://localhost:8250/oidc/callback"
  ],
  "user_claim": "sub",
  "groups_claim": "groups",
  "token_ttl": "1h",
  "token_max_ttl": "24h",
  "token_policies": ["default"]
}
EOF

  vault write auth/oidc/role/default @/tmp/oidc-role.json
  rm /tmp/oidc-role.json
  echo "OIDC role default written"
'

# ── Step 7: External groups + group aliases ─────────────────────
# An external group in Vault identity maps to a group in an external auth system.
# A group alias links the JWT group name (e.g. "/devops") to the Vault group so
# that when the OIDC token arrives with "groups":["/devops"], Vault automatically
# assigns the devops-policy to the identity.
section "Step 7 — Creating external identity groups and OIDC group aliases"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c '
  export VAULT_ADDR='"${VAULT_ACTIVE_ADDR}"'
  export VAULT_TOKEN='"${ROOT_TOKEN}"'

  # Get the OIDC auth mount accessor (needed for group aliases)
  OIDC_ACCESSOR=$(vault auth list | awk "/^oidc\// {print \$3}")
  echo "OIDC accessor: $OIDC_ACCESSOR"

  ensure_group_and_alias() {
    GROUP_NAME="$1"
    POLICY_NAME="$2"
    ALIAS_NAME="$3"
    DESCRIPTION="$4"

    GROUP_ID=$(vault write -field=id identity/lookup/group \
      name="$GROUP_NAME" 2>/dev/null || true)
    if [ -n "$GROUP_ID" ]; then
      vault write "identity/group/id/${GROUP_ID}" \
        name="$GROUP_NAME" type=external policies="$POLICY_NAME" \
        metadata=description="$DESCRIPTION" >/dev/null
    else
      GROUP_ID=$(vault write -field=id identity/group \
        name="$GROUP_NAME" type=external policies="$POLICY_NAME" \
        metadata=description="$DESCRIPTION")
    fi

    ALIAS_ID=""
    for CANDIDATE_ID in $(vault list identity/group-alias/id 2>/dev/null |
      awk "NR > 2 {print \$1}"); do
      CANDIDATE_NAME=$(vault read -field=name \
        "identity/group-alias/id/${CANDIDATE_ID}" 2>/dev/null || true)
      CANDIDATE_ACCESSOR=$(vault read -field=mount_accessor \
        "identity/group-alias/id/${CANDIDATE_ID}" 2>/dev/null || true)
      if [ "$CANDIDATE_NAME" = "$ALIAS_NAME" ] &&
         [ "$CANDIDATE_ACCESSOR" = "$OIDC_ACCESSOR" ]; then
        ALIAS_ID="$CANDIDATE_ID"
        break
      fi
    done

    if [ -n "$ALIAS_ID" ]; then
      vault write "identity/group-alias/id/${ALIAS_ID}" \
        name="$ALIAS_NAME" \
        mount_accessor="$OIDC_ACCESSOR" \
        canonical_id="$GROUP_ID" >/dev/null
    else
      vault write identity/group-alias \
        name="$ALIAS_NAME" \
        mount_accessor="$OIDC_ACCESSOR" \
        canonical_id="$GROUP_ID" >/dev/null
    fi

    echo "Group ${GROUP_NAME} → ${POLICY_NAME} (alias: ${ALIAS_NAME})"
  }

  ensure_group_and_alias \
    devops devops-policy /devops "DevOps engineers — full Vault admin"
  ensure_group_and_alias \
    team-a team-a-policy /team-a "Team A — scoped to secret/data/team-a/*"
  ensure_group_and_alias \
    team-b team-b-policy /team-b "Team B — scoped to secret/data/team-b/*"
'

# ── Step 8: Seed sample secrets ─────────────────────────────────
section "Step 8 — Seeding sample secrets for each team"

kubectl exec -n "$VAULT_NS" vault-0 -- sh -c "
  export VAULT_ADDR=${VAULT_ACTIVE_ADDR}
  export VAULT_TOKEN=${ROOT_TOKEN}

  vault kv put secret/team-a/config  app=team-a-service  env=kind  owner=team-a
  vault kv put secret/team-a/db      host=db.team-a      port=5432 password=changeme
  vault kv put secret/team-b/config  app=team-b-service  env=kind  owner=team-b
  vault kv put secret/team-b/db      host=db.team-b      port=5432 password=changeme
  vault kv put secret/devops/cluster name=kind-vault     region=local nodes=4
  echo 'Sample secrets seeded'
"

# ── Done ────────────────────────────────────────────────────────
section "Setup complete!"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║        Vault ↔ Keycloak OIDC Integration Summary            ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Vault UI    : https://vault.kind.local/ui                 ║"
echo "║  Login method: OIDC  (select from dropdown)                 ║"
echo "║  Role        : default                                      ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Group       Policy          Allowed Paths                  ║"
echo "║  ─────────── ─────────────── ──────────────────────────     ║"
echo "║  devops    → devops-policy → ALL paths  (*)                 ║"
echo "║  team-a    → team-a-policy → secret/data/team-a/*           ║"
echo "║  team-b    → team-b-policy → secret/data/team-b/*           ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Test users  (Keycloak password: password)                  ║"
echo "║   devops-user-1 / devops-user-2  → full admin               ║"
echo "║   team-a-user-1 / team-a-user-2  → secret/data/team-a/*     ║"
echo "║   team-b-user-1 / team-b-user-2  → secret/data/team-b/*     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Seeded secrets:                                            ║"
echo "║   secret/team-a/config  secret/team-a/db                   ║"
echo "║   secret/team-b/config  secret/team-b/db                   ║"
echo "║   secret/devops/cluster                                     ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  CLI login:                                                 ║"
echo "║   vault login -method=oidc \\                                ║"
echo "║     -address=http://vault.kind.local role=default          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
