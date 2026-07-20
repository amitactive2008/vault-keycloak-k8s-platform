#!/usr/bin/env bash
# ============================================================
# create-realm.sh — Idempotent Keycloak realm + user setup
#
# Uses kcadm.sh (Keycloak Admin CLI) via kubectl exec to create
# or update the "kind" realm, groups, and users.
#
# Safe to re-run: every resource is checked before creation.
#
# What this creates in the "kind" realm:
#   Groups : devops, team-a, team-b
#   Users  : devops-user-1/2  → /devops
#            team-a-user-1/2  → /team-a
#            team-b-user-1/2  → /team-b
#   All user passwords default to "password"
#
# Prerequisites:
#   - Keycloak is deployed and healthy
#   - kubectl points at the correct cluster
#
# Usage:
#   cd 03-keycloak/
#   chmod +x create-realm.sh
#   ./create-realm.sh
# ============================================================
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────
KC_NS="keycloak"
KC_REALM="kind"
KC_ADMIN_USER="admin"
KC_ADMIN_PASS="Admin@Keycloak2024!"   # must match values.yaml keycloak.auth.adminPassword
USER_PASSWORD="password"              # default password for all demo users

# ── ANSI helpers ──────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
section() { echo -e "\n${GREEN}===== $* =====${NC}"; }

# ── kcadm wrapper — runs kcadm.sh inside the Keycloak pod ─────
kcadm() {
  kubectl exec -n "$KC_NS" "$KC_POD" -- \
    /opt/keycloak/bin/kcadm.sh "$@"
}

# ── Prerequisite checks ───────────────────────────────────────
section "Step 0 — Prerequisites"
command -v kubectl &>/dev/null || { error "kubectl not found"; exit 1; }
kubectl cluster-info &>/dev/null  || { error "No reachable cluster"; exit 1; }
info "Cluster: $(kubectl config current-context)"

# ── Locate the Keycloak pod ───────────────────────────────────
section "Step 1 — Locating Keycloak pod"
KC_POD=$(kubectl get pod -n "$KC_NS" \
  -l app=keycloak \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$KC_POD" ]; then
  error "No Keycloak pod found in namespace '$KC_NS'."
  error "Deploy Keycloak first:"
  error "  helm install keycloak ./keycloak-chart -f ./values.yaml -n keycloak --create-namespace"
  exit 1
fi
info "Keycloak pod: $KC_POD"

# Wait for pod to be Ready
kubectl wait pod "$KC_POD" -n "$KC_NS" \
  --for=condition=Ready \
  --timeout=300s \
  && info "Pod is Ready ✓"

# Pod Ready condition means the readiness probe (/health/ready) already passed —
# Keycloak is up. No additional health check needed.
info "Keycloak is ready ✓"

# ── Authenticate kcadm ────────────────────────────────────────
section "Step 2 — Authenticating kcadm (master realm admin)"
kcadm config credentials \
  --server http://localhost:8080 \
  --realm master \
  --user "$KC_ADMIN_USER" \
  --password "$KC_ADMIN_PASS"
info "kcadm authenticated ✓"

# ── Create / verify realm ─────────────────────────────────────
section "Step 3 — Realm: $KC_REALM"
REALM_EXISTS=$(kcadm get realms \
  --fields realm 2>/dev/null | grep -c "\"${KC_REALM}\"" || true)

if [ "$REALM_EXISTS" -gt 0 ]; then
  warn "Realm '$KC_REALM' already exists — skipping creation"
else
  info "Creating realm '$KC_REALM'..."
  kcadm create realms \
    -s realm="${KC_REALM}" \
    -s enabled=true \
    -s displayName="Kind Realm" \
    -s displayNameHtml="<b>Kind</b> Realm" \
    -s sslRequired=external \
    -s registrationAllowed=false \
    -s loginWithEmailAllowed=true \
    -s duplicateEmailsAllowed=false \
    -s resetPasswordAllowed=true \
    -s editUsernameAllowed=false \
    -s bruteForceProtected=true \
    -s 'passwordPolicy=length(8)' \
    -s 'defaultRoles=["offline_access","uma_authorization"]'
  info "Realm '$KC_REALM' created ✓"
fi

# ── Helper: create or skip a group ───────────────────────────
create_group() {
  local GROUP_NAME="$1"
  local EXISTS
  EXISTS=$(kcadm get groups -r "$KC_REALM" \
    --fields name 2>/dev/null | grep -c "\"${GROUP_NAME}\"" || true)
  if [ "$EXISTS" -gt 0 ]; then
    warn "Group '$GROUP_NAME' already exists — skipping"
  else
    kcadm create groups -r "$KC_REALM" -s name="${GROUP_NAME}"
    info "Group '$GROUP_NAME' created ✓"
  fi
}

# ── Create groups ─────────────────────────────────────────────
section "Step 4 — Groups"
create_group "devops"
create_group "team-a"
create_group "team-b"

# Assign realm-admin role to devops group (mirrors kind-realm.json)
DEVOPS_GID=$(kcadm get groups -r "$KC_REALM" \
  --fields id,name 2>/dev/null \
  | grep -B1 '"devops"' | grep '"id"' | awk -F'"' '{print $4}')

if [ -n "$DEVOPS_GID" ]; then
  ROLE_ASSIGNED=$(kcadm get-roles \
    -r "$KC_REALM" \
    --gid "$DEVOPS_GID" \
    --cclientid realm-management 2>/dev/null | grep -c '"realm-admin"' || true)
  if [ "$ROLE_ASSIGNED" -gt 0 ]; then
    warn "devops group already has realm-admin role — skipping"
  else
    kcadm add-roles \
      -r "$KC_REALM" \
      --gid "$DEVOPS_GID" \
      --cclientid realm-management \
      --rolename realm-admin
    info "realm-admin role assigned to devops group ✓"
  fi
fi

# ── Helper: get group ID by name ────────────────────────────
get_group_id() {
  local GROUP_NAME="$1"
  kcadm get groups -r "$KC_REALM" --fields id,name 2>/dev/null \
    | grep -B1 "\"name\" : \"${GROUP_NAME}\"" \
    | grep '"id"' \
    | awk -F'"' '{print $4}'
}

# ── Helper: create a user and assign to a group ───────────────
create_user() {
  local USERNAME="$1"
  local FIRST="$2"
  local LAST="$3"
  local EMAIL="$4"
  local GROUP_NAME="$5"   # plain group name, e.g. "devops" (not "/devops")

  local EXISTS
  EXISTS=$(kcadm get users -r "$KC_REALM" \
    -q "username=${USERNAME}" --fields username 2>/dev/null \
    | grep -c "\"${USERNAME}\"" || true)

  if [ "$EXISTS" -gt 0 ]; then
    warn "User '$USERNAME' already exists — skipping"
    return
  fi

  # Create the user (kcadm does not support group assignment at creation time)
  kcadm create users -r "$KC_REALM" \
    -s username="${USERNAME}" \
    -s enabled=true \
    -s emailVerified=true \
    -s firstName="${FIRST}" \
    -s lastName="${LAST}" \
    -s email="${EMAIL}"

  # Set permanent password
  kcadm set-password -r "$KC_REALM" \
    --username "${USERNAME}" \
    --new-password "${USER_PASSWORD}" \
    --temporary false

  # Fetch IDs and add user to group as a separate API call
  local USER_ID GROUP_ID
  USER_ID=$(kcadm get users -r "$KC_REALM" \
    -q "username=${USERNAME}" --fields id 2>/dev/null \
    | grep '"id"' | awk -F'"' '{print $4}')

  GROUP_ID=$(get_group_id "${GROUP_NAME}")

  if [ -n "$USER_ID" ] && [ -n "$GROUP_ID" ]; then
    kcadm update "users/${USER_ID}/groups/${GROUP_ID}" \
      -r "$KC_REALM" \
      -s realm="$KC_REALM" \
      -s userId="$USER_ID" \
      -s groupId="$GROUP_ID"
    info "User '${USERNAME}' created ✓  (group: ${GROUP_NAME})"
  else
    warn "User '${USERNAME}' created but group assignment failed"
    warn "  USER_ID='${USER_ID}'  GROUP_ID='${GROUP_ID}'"
  fi
}

# ── Create users ──────────────────────────────────────────────
section "Step 5 — Users"
create_user "devops-user-1" "DevOps"  "User1" "devops-user-1@kind.local" "devops"
create_user "devops-user-2" "DevOps"  "User2" "devops-user-2@kind.local" "devops"
create_user "team-a-user-1" "Team-A"  "User1" "team-a-user-1@kind.local" "team-a"
create_user "team-a-user-2" "Team-A"  "User2" "team-a-user-2@kind.local" "team-a"
create_user "team-b-user-1" "Team-B"  "User1" "team-b-user-1@kind.local" "team-b"
create_user "team-b-user-2" "Team-B"  "User2" "team-b-user-2@kind.local" "team-b"

# ── Summary ───────────────────────────────────────────────────
section "Done"
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║         Keycloak 'kind' realm — ready                ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║  Admin Console : https://keycloak.kind.local/admin        ║"
echo "║  Realm         : ${KC_REALM}                              ║"
echo "╠═══════════════════════════════════════════════════════╣"
echo "║  Group         Users              Password           ║"
echo "║  ──────────    ────────────────   ────────────────   ║"
echo "║  devops        devops-user-1/2    password           ║"
echo "║  team-a        team-a-user-1/2    password           ║"
echo "║  team-b        team-b-user-1/2    password           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
info "Run 'kubectl get pods -n $KC_NS' to confirm all pods are Running."
