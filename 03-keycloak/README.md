# Keycloak Setup

Keycloak 26.x identity provider deployed via a local Helm chart into the `keycloak` namespace.
Backed by PostgreSQL 17, TLS-terminated by the shared Envoy Gateway, and pre-loaded with the
`kind` realm (groups + users) via a JSON import on first boot.

---

## Architecture

```
https://keycloak.kind.local
        │
        ▼
Envoy Gateway (native-gateway, default ns)
  HTTPS:443 → wildcard *.kind.local TLS termination
        │  HTTPRoute: keycloak (keycloak ns)
        ▼
keycloak service :80 (→ pod :8080)
        │  KC_HOSTNAME=keycloak.kind.local
        │  KC_PROXY_HEADERS=xforwarded
        ▼
keycloak Pod (quay.io/keycloak/keycloak:26.3.3)
        │
        ▼
keycloak-postgresql StatefulSet (postgres:17, 4 Gi PVC)
```

---

## Files

| File | Purpose |
|------|---------|
| `values.yaml` | User-facing Helm overrides (hostname, credentials, resources) |
| `keycloak-httproute.yaml` | HTTPRoute for `keycloak.kind.local` + HTTP→HTTPS redirect |
| `keycloak-chart/` | Local Helm chart (Keycloak + PostgreSQL) |
| `keycloak-chart/kind-realm.json` | Realm definition imported on first boot |
| `kind-realm.json` | Reference copy of the realm definition |
| `create-realm.sh` | Idempotent kcadm script to create/update realm resources at runtime |

---

## Prerequisites

- Kind cluster running with cloud-provider-kind (`01-cloud-provider-kind-setup-with-gw-api` complete)
- Envoy Gateway installed with `native-gateway` programmed and HTTPS on port 443
- Wildcard cert `*.kind.local` loaded as `wildcard-kind-local-tls` in `default` namespace

---

## Step 1 — Add DNS entry

```bash
echo "127.0.0.1 keycloak.kind.local" | sudo tee -a /etc/hosts
```

## Step 2 — Install Keycloak

```bash
cd 03-keycloak

helm upgrade --install keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak --create-namespace
```

Wait for both pods to be ready (first boot takes 2–5 min for DB schema creation + realm import):

```bash
kubectl rollout status deployment/keycloak -n keycloak --timeout=360s
kubectl get pods -n keycloak
# NAME                        READY   STATUS
# keycloak-xxxxx              1/1     Running
# keycloak-postgresql-0       1/1     Running
```

## Step 3 — Apply the HTTPRoute

```bash
kubectl apply -f keycloak-httproute.yaml
```

Verify routes are accepted:

```bash
kubectl get httproute -n keycloak
# NAME                     HOSTNAMES
# keycloak                 ["keycloak.kind.local"]
# keycloak-http-redirect   ["keycloak.kind.local"]
```

## Step 4 — Verify

```bash
# OIDC discovery — issuer must be https://keycloak.kind.local/realms/kind
# (CA is trusted in macOS System Keychain after Step 1 setup)
curl -s https://keycloak.kind.local/realms/kind/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
# "issuer": "https://keycloak.kind.local/realms/kind"

# HTTP -> HTTPS redirect
curl -v http://keycloak.kind.local/ 2>&1 | grep -E "HTTP|Location"
# < HTTP/1.1 301 Moved Permanently
```

Open the Admin Console: **https://keycloak.kind.local/admin**

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `Admin@Keycloak2024!` |
| Realm | Switch from `master` → `kind` |

---

## Realm: `kind`

Imported automatically from `keycloak-chart/kind-realm.json` on first boot.

### Groups and users

| Username | Group | Password |
|----------|-------|----------|
| `devops-user-1` | `devops` | `password` |
| `devops-user-2` | `devops` | `password` |
| `team-a-user-1` | `team-a` | `password` |
| `team-a-user-2` | `team-a` | `password` |
| `team-b-user-1` | `team-b` | `password` |
| `team-b-user-2` | `team-b` | `password` |

| Group | Keycloak role |
|-------|---------------|
| `devops` | `realm-admin` (full realm administration) |
| `team-a` | — |
| `team-b` | — |

### OIDC endpoints

```
Discovery:   https://keycloak.kind.local/realms/kind/.well-known/openid-configuration
Token:       https://keycloak.kind.local/realms/kind/protocol/openid-connect/token
Auth:        https://keycloak.kind.local/realms/kind/protocol/openid-connect/auth
JWKS:        https://keycloak.kind.local/realms/kind/protocol/openid-connect/certs
Userinfo:    https://keycloak.kind.local/realms/kind/protocol/openid-connect/userinfo
```

---

## Upgrade

Edit `values.yaml` (e.g. update `keycloak.image.tag`), then:

```bash
helm upgrade keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak
```

> Keycloak uses `strategy: Recreate` — expect ~30 s downtime during upgrades.

---

## Re-importing the realm

If you change `kind-realm.json` and need to re-import:

```bash
# 1. Update the ConfigMap
kubectl create configmap keycloak-realm-import \
  --from-file=kind-realm.json=keycloak-chart/kind-realm.json \
  --namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

# 2. Delete the existing realm inside Keycloak
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "Admin@Keycloak2024!"

kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh delete realms/kind

# 3. Restart Keycloak to trigger re-import
kubectl rollout restart deployment/keycloak -n keycloak
kubectl rollout status deployment/keycloak -n keycloak --timeout=360s
```

Alternatively, use `create-realm.sh` (kcadm-based, idempotent):

```bash
chmod +x create-realm.sh && ./create-realm.sh
```

---

## Uninstall

```bash
helm uninstall keycloak --namespace keycloak
kubectl delete namespace keycloak
```

---

## Useful commands

```bash
# Pod status
kubectl get pods -n keycloak -o wide

# Keycloak logs (realm import visible here on first boot)
kubectl logs -n keycloak -l app=keycloak -f

# PostgreSQL logs
kubectl logs -n keycloak keycloak-postgresql-0

# Helm release info
helm status keycloak -n keycloak
helm history keycloak -n keycloak

# HTTPRoutes
kubectl get httproute -n keycloak

# Open kcadm session
kubectl exec -it -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "Admin@Keycloak2024!"

# List users in the kind realm
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get users -r kind

# Get an access token (useful for API testing)
curl -s -X POST \
  https://keycloak.kind.local/realms/kind/protocol/openid-connect/token \
  -d "client_id=admin-cli&grant_type=password&username=devops-user-1&password=password" \
  | python3 -m json.tool | grep access_token
```

---

## Troubleshooting

**`INSTALLATION FAILED: Namespace "keycloak" … invalid ownership metadata`**

The namespace was pre-created without Helm labels. Patch it and re-install:

```bash
kubectl patch namespace keycloak --type=merge -p '{
  "metadata": {
    "labels":      {"app.kubernetes.io/managed-by": "Helm"},
    "annotations": {
      "meta.helm.sh/release-name":      "keycloak",
      "meta.helm.sh/release-namespace": "keycloak"
    }
  }
}'
helm upgrade --install keycloak ./keycloak-chart -f ./values.yaml --namespace keycloak
```

**Keycloak pod stuck in `Init:0/1`**

PostgreSQL is not ready yet. Check: `kubectl logs -n keycloak keycloak-postgresql-0`

**OIDC issuer is `http://` instead of `https://`**

`KC_HOSTNAME` must be set to `https://keycloak.kind.local`. This is set in the chart template
via `keycloak.hostname`. Verify: `kubectl exec -n keycloak deployment/keycloak -- env | grep KC_HOSTNAME`

**`Realm 'kind' already exists. Import skipped`**

Expected on restarts after the first import. Use the re-import steps above if you changed `kind-realm.json`.

**`https://keycloak.kind.local` returns 404**

Check the HTTPRoute is attached and the gateway is programmed:

```bash
kubectl get httproute -n keycloak
kubectl get gateway native-gateway -n default
```
