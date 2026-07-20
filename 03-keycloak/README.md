# Keycloak — kind cluster deployment

Keycloak 26.x identity provider deployed via Helm on a local kind cluster.
Backed by PostgreSQL 17, TLS-terminated by nginx ingress, and pre-loaded with
the `kind` realm (groups + users) via a JSON import.

---

## Architecture

```
Browser ──► 127.0.0.1:443
                │
                ▼
      nginx Ingress (keycloak.kind.local)
      TLS: keycloak-local-tls secret
      (signed by shared pki/kind.localCA.crt)
                │
                ▼
      Deployment: keycloak          namespace: keycloak
      quay.io/keycloak/keycloak:26.3.3
                │
                ▼
      StatefulSet: keycloak-postgresql
      docker.io/library/postgres:17
      PVC: 4 Gi
```

---

## Folder structure

```
03-keycloak/
├── values.yaml              ← edit this to customise your install
├── kind-realm.json          ← realm definition (reference copy)
├── create-realm.sh          ← kcadm-based idempotent realm script
└── keycloak-chart/
    ├── Chart.yaml
    ├── values.yaml          ← all available defaults with comments
    ├── kind-realm.json      ← chart copy used by Helm .Files.Get
    └── templates/
        ├── namespace.yaml
        ├── secrets.yaml
        ├── postgres-services.yaml
        ├── postgres-statefulset.yaml
        ├── realm-configmap.yaml
        ├── keycloak-service.yaml
        ├── keycloak-deployment.yaml
        └── ingress.yaml
```

---

## Step 1 — Generate the Keycloak TLS certificate

Keycloak needs HTTPS for OIDC (Kubernetes 1.30+ rejects `http://` issuer URLs).
We sign a cert for `keycloak.kind.local` using the **shared local CA** created
during the Vault setup (`02-vault` Step 4a).  One CA covers both services so
the browser only needs to trust a single root.

> Run all commands from the **project root**
> (`vault-keycloak-k8s-platform/`).

### 1a — Create the server-cert config

```bash
cat > pki/keycloak.ini << 'EOF'
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[dn]
C  = US
O  = kind-vault
CN = keycloak.kind.local

[v3_req]
subjectAltName   = DNS:keycloak.kind.local
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF
```

### 1b — Generate the key and sign the CSR

```bash
# Server private key
openssl genrsa -out pki/keycloak.kind.local.key 4096 2>/dev/null

# CSR
openssl req -new \
  -key pki/keycloak.kind.local.key \
  -out pki/keycloak.kind.local.csr \
  -config pki/keycloak.ini

# Sign with the shared CA
openssl x509 -req \
  -in  pki/keycloak.kind.local.csr \
  -CA  pki/kind.localCA.crt \
  -CAkey pki/kind.localCA.key \
  -CAcreateserial \
  -out pki/keycloak.kind.local.crt \
  -days 3650 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:keycloak.kind.local\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth')

# Verify chain
openssl verify -CAfile pki/kind.localCA.crt pki/keycloak.kind.local.crt
```

### 1c — Create the Kubernetes TLS secret

The secret must exist **before** `helm install` — Helm only references the
name; it never creates the secret itself.

```bash
# Create the namespace first so the secret has somewhere to live
kubectl create namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

# Create the TLS secret
kubectl create secret tls keycloak-local-tls \
  --cert=pki/keycloak.kind.local.crt \
  --key=pki/keycloak.kind.local.key \
  -n keycloak

# Confirm
kubectl get secret keycloak-local-tls -n keycloak
```

> The CA (`pki/kind.localCA.crt`) is already trusted in macOS from the Vault
> setup, so `https://keycloak.kind.local` will be green in the browser with no
> extra steps.

---

## Step 2 — Add the local DNS entry

```bash
echo "127.0.0.1  keycloak.kind.local" | sudo tee -a /etc/hosts
```

---

## Step 3 — Install Keycloak via Helm

```bash
cd 03-keycloak

# Preview what will be deployed (dry-run)
helm template keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak

# Install
helm install keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak --create-namespace
```

Watch until all pods are Running:

```bash
kubectl get pods -n keycloak -w
```

Expected steady state (takes 2–5 min on first boot due to DB schema creation):

```
NAME                        READY   STATUS    RESTARTS
keycloak-xxxxx              1/1     Running   0
keycloak-postgresql-0       1/1     Running   0
```

Verify the ingress is reachable:

```bash
curl -sk https://keycloak.kind.local/realms/kind/.well-known/openid-configuration \
  --cacert pki/kind.localCA.crt | python3 -m json.tool | grep issuer
```

Expected: `"issuer": "https://keycloak.kind.local/realms/kind"`

---

## Step 4 — Users and groups

### How they are created (default: Helm import)

With `realm.importEnabled: true` (default in `values.yaml`), Helm mounts
`keycloak-chart/kind-realm.json` as a ConfigMap. Keycloak reads every `*.json`
file in `/opt/keycloak/data/import/` at startup and imports the realm,
groups, users, and role assignments automatically — **no extra steps needed**.

| Resource | Created by |
|----------|-----------|
| Realm `kind` | Helm import |
| Groups: `devops`, `team-a`, `team-b` | Helm import |
| Users: `devops-user-{1,2}`, `team-a-user-{1,2}`, `team-b-user-{1,2}` | Helm import |
| User → group membership | Helm import |
| `devops` → `realm-admin` client role | Helm import |

All demo users share the password `password`.

### Access matrix

| Group | Keycloak role | Typical use |
|-------|---------------|-------------|
| `devops` | `realm-admin` (realm-management) | Full realm administration |
| `team-a` | — | Scoped to `team-a` resources |
| `team-b` | — | Scoped to `team-b` resources |

### When to use `create-realm.sh`

`create-realm.sh` uses the Keycloak Admin CLI (`kcadm.sh`) via `kubectl exec`
to create or update realm resources **without redeploying Keycloak**.

Use it when:
- `realm.importEnabled: false` — you skipped the JSON import
- You want to add new users or groups to a running Keycloak
- The realm import failed and you need to recreate resources manually
- You want to reset deleted users/groups

```bash
cd 03-keycloak
chmod +x create-realm.sh
./create-realm.sh
```

The script is **idempotent** — it checks before creating every resource and
skips anything that already exists.

### Customising the realm

To change the imported realm (add users, tweak settings):

1. Edit `03-keycloak/keycloak-chart/kind-realm.json`
2. Also update `03-keycloak/kind-realm.json` (the reference copy)
3. Run `helm upgrade` (see below) — Keycloak re-imports on the next pod restart

---

## Step 5 — Verify in the Admin Console

Open `https://keycloak.kind.local/admin` in your browser.

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `Admin@Keycloak2024!` |
| Realm (dropdown) | switch from `master` → `kind` |

Check **Users**, **Groups**, and **Clients** to confirm the import succeeded.

---

## Authentication flow

```
User / Application
      │
      │  1. Redirect to Keycloak authorization endpoint
      │     https://keycloak.kind.local/realms/kind/protocol/openid-connect/auth
      │     ?client_id=<client>&redirect_uri=<callback>&response_type=code
      ▼
Keycloak login page  (kind realm)
      │
      │  2. User enters credentials  (e.g. team-a-user-1 / password)
      │     Keycloak validates against PostgreSQL
      ▼
      │  3. Keycloak issues Authorization Code → redirect to callback URI
      ▼
Application / kubectl / Vault
      │
      │  4. Exchange code for tokens (POST to token endpoint)
      │     https://keycloak.kind.local/realms/kind/protocol/openid-connect/token
      ▼
      │  5. Receive:
      │     - id_token     — who the user is (sub, preferred_username, groups)
      │     - access_token — presented to APIs
      │     - refresh_token — get new tokens without re-login
      ▼
      │  6. Consuming service validates token:
      │     - Kubernetes API server  → --oidc-issuer-url  (k8s-oidc/setup.sh)
      │     - Vault                  → auth/oidc/config   (vault-integration/setup.sh)
      ▼
RBAC / Policy evaluated  →  allow or deny
```

Key JWT claims used in this platform:

| Claim | Example value | Used by |
|-------|---------------|---------|
| `iss` | `https://keycloak.kind.local/realms/kind` | Token validation |
| `sub` | `1cf96fe0-bd7e-4896-a19e-22adbb54bd0c` | User identity |
| `preferred_username` | `team-a-user-1` | Kubernetes username |
| `groups` | `["team-a"]` | Kubernetes RBAC + Vault policy |
| `aud` | `kubernetes` or `vault` | Audience check per client |

---

## Upgrade

### Update the chart values or Keycloak version

Edit `values.yaml` then run:

```bash
cd 03-keycloak
helm upgrade keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak
```

### Update the Keycloak image version

In `values.yaml`:
```yaml
keycloak:
  image:
    tag: "26.x.x"   # new version
```

Then run `helm upgrade` as above.

> **Note:** Keycloak uses `strategy: Recreate` — the old pod terminates before
> the new one starts. Expect ~30 s of downtime during upgrades.

---

## Uninstall

```bash
# Remove the Helm release (deletes all chart-managed resources)
helm uninstall keycloak --namespace keycloak

# Delete the namespace (removes PVCs, secrets, everything)
kubectl delete namespace keycloak
```

> Deleting the namespace also removes the `keycloak-local-tls` TLS secret.
> Re-run Step 1c before the next install.

---

## Useful commands

```bash
# Pod status
kubectl get pods -n keycloak -o wide

# Keycloak logs (realm import visible here on first boot)
kubectl logs -n keycloak -l app=keycloak -f

# PostgreSQL logs
kubectl logs -n keycloak keycloak-postgresql-0

# Helm release status
helm status keycloak -n keycloak

# Helm release history
helm history keycloak -n keycloak

# Describe the ingress
kubectl describe ingress keycloak -n keycloak

# Test OIDC discovery endpoint
curl -sk https://keycloak.kind.local/realms/kind/.well-known/openid-configuration \
  --cacert ../pki/kind.localCA.crt | python3 -m json.tool

# Check the TLS secret exists
kubectl get secret keycloak-local-tls -n keycloak
```


---

## Architecture

```
                              ┌─────────────────────────────┐
Browser ──► 127.0.0.1:80      │  kind node (control-plane)  │
            (308 → :443)      │   nginx Ingress Controller   │
Browser ──► 127.0.0.1:443     │   TLS terminated             │
                              └──────────────┬──────────────┘
                                             │ keycloak.local
                         ┌───────────────────▼─────────────┐
                         │  Namespace: keycloak             │
                         │                                  │
                         │  Keycloak 26.3.3 (Deployment)    │
                         │  quay.io/keycloak/keycloak       │
                         │         │                        │
                         │  PostgreSQL 17 (StatefulSet)     │
                         │  docker.io/library/postgres      │
                         └──────────────────────────────────┘
```

| Component   | Image                              | Version |
|-------------|------------------------------------|---------|
| Keycloak    | `quay.io/keycloak/keycloak`        | 26.3.3  |
| PostgreSQL  | `docker.io/library/postgres`       | 17      |

---

## Prerequisites

| Tool      | Minimum version | Install |
|-----------|----------------|---------|
| `kind`    | v0.20+         | `brew install kind` |
| `kubectl` | v1.28+         | `brew install kubectl` |

> The kind cluster must be running with ports 80/443 mapped to the host (see `../deploy/kind.yaml`).
> Nginx Ingress Controller must be installed in the cluster (see `../deploy/deploy-ingress-nginx.yaml`).

---

## File Structure

```
keycloak/
├── README.md                 ← this file
├── install.sh                ← one-shot Keycloak install script
├── namespace.yaml            ← Namespace: keycloak
├── postgres.yaml             ← PostgreSQL 17 StatefulSet + Service + Secret
├── keycloak.yaml             ← Keycloak 26 Deployment + Service + Secret (performance-tuned)
├── ingress.yaml              ← nginx Ingress: keycloak.local — HTTP:80 → HTTPS:443 redirect
├── kind-realm.json           ← Realm definition imported on first boot
├── helm-values.yaml          ← Reference Bitnami chart values (kept for reference, not used)
├── vault-integration/        ← Vault ↔ Keycloak OIDC wiring
│   ├── setup.sh              ← end-to-end setup script (run after Keycloak is installed)
│   └── policies/
│       ├── devops.hcl        ← full Vault admin policy
│       ├── team-a.hcl        ← scoped to secret/data/team-a/*
│       └── team-b.hcl        ← scoped to secret/data/team-b/*
└── k8s-oidc/                 ← kubectl SSO via Keycloak (kube-apiserver OIDC)
    ├── README.md             ← kubectl SSO setup guide
    ├── setup.sh              ← end-to-end kubectl OIDC setup script
    ├── keycloak-local-ca.crt ← self-signed CA cert (generated; covers keycloak.local + vault-webui.local)
    ├── kubeconfig-oidc.yaml  ← kubectl contexts for devops/team-a/team-b (generated)
    └── rbac/
        ├── devops-cluster-admin.yaml
        ├── team-a.yaml
        └── team-b.yaml
```

---

## Quick Start


```bash
cd 03-keycloak/
chmod +x install.sh
./install.sh
```

The script will:
1. Create the `keycloak` namespace
2. Create the realm ConfigMap from `kind-realm.json`
3. Deploy PostgreSQL 17 and wait for it to be ready
4. Deploy Keycloak 26 (imports the `kind` realm on first boot)
5. Apply the nginx Ingress

Total time: **~3–5 minutes** (image pull on first run may take longer).

### 3. Add the hosts entry

```bash
sudo sh -c 'echo "127.0.0.1  keycloak.kind.local" >> /etc/hosts'
```

### 4. Access the Admin Console

| Field    | Value |
|----------|-------|
| URL      | https://keycloak.kind.local/admin |
| Username | `admin` |
| Password | `Admin@Keycloak2024!` |

---

## Realm: `kind`

The `kind` realm is automatically imported from `kind-realm.json` on first Keycloak startup.

### Groups

| Group    | Admin Access                                      |
|----------|---------------------------------------------------|
| `devops` | Full realm-admin (via `realm-management` client role) |
| `team-a` | Regular users                                     |
| `team-b` | Regular users                                     |

> `devops` members can manage the `kind` realm via **http://keycloak.local/admin/kind/console**.

### Users

All users have the password `password`.

| Username       | Group    |
|----------------|----------|
| `devops-user-1` | devops  |
| `devops-user-2` | devops  |
| `team-a-user-1` | team-a  |
| `team-a-user-2` | team-a  |
| `team-b-user-1` | team-b  |
| `team-b-user-2` | team-b  |

### Realm OIDC endpoints

HTTP (used internally by Vault pods via CoreDNS — bypasses the ingress redirect):
```
Discovery:   http://keycloak.local/realms/kind/.well-known/openid-configuration
Token:       http://keycloak.local/realms/kind/protocol/openid-connect/token
Userinfo:    http://keycloak.local/realms/kind/protocol/openid-connect/userinfo
JWKS:        http://keycloak.local/realms/kind/protocol/openid-connect/certs
```

HTTPS (used by kube-apiserver OIDC + browser login via kubelogin):
```
Discovery:   https://keycloak.local/realms/kind/.well-known/openid-configuration
Token:       https://keycloak.local/realms/kind/protocol/openid-connect/token
Userinfo:    https://keycloak.local/realms/kind/protocol/openid-connect/userinfo
JWKS:        https://keycloak.local/realms/kind/protocol/openid-connect/certs
```

> The TLS certificate for `https://keycloak.local` is signed by the self-signed CA at
> `k8s-oidc/keycloak-local-ca.crt`. Trust it once with `sudo security add-trusted-cert`
> (see [k8s-oidc/README.md](k8s-oidc/README.md#3-trust-the-self-signed-ca-certificate)).

---

## Performance Optimizations

`keycloak.yaml` has been tuned for responsive page loads on a local kind cluster:

| Setting | Value | Reason |
|---------|-------|--------|
| CPU request/limit | `1000m` / `2000m` | JVM JIT + G1GC need unthrottled CPU bursts |
| Memory request/limit | `1536Mi` / `3Gi` | JVM heap = 50–75 % of pod memory |
| `KC_CACHE` | `local` | Avoids distributed-cache overhead on a single replica |
| `KC_LOG_LEVEL` | `WARN` | Cuts logging I/O by ~80 % vs `INFO` |
| `KC_TRANSACTION_XA_ENABLED` | `false` | Faster DB writes for single-database setup |
| `KC_DB_POOL_MIN_SIZE` | `5` | Pre-warms DB connections; no cold-connect latency |
| JVM GC | `-XX:+UseG1GC -XX:MaxGCPauseMillis=200` | Low-latency GC for request-serving workloads |

---

## Vault Integration

The `vault-integration/` directory wires Keycloak as the OIDC provider for Vault.
Run **after** both Vault and Keycloak are deployed:

```bash
cd vault-integration/
chmod +x setup.sh
./setup.sh
```

What it sets up:

| Resource | Detail |
|----------|--------|
| CoreDNS patch | `keycloak.local` resolves inside the cluster (Vault pods reach Keycloak) |
| Keycloak client `vault` | Confidential OIDC client with groups claim mapper |
| KV v2 engine | Mounted at `secret/` in Vault |
| Vault OIDC auth | Discovery URL: `http://keycloak.local/realms/kind` |
| Vault policies | `devops-policy` (all paths), `team-a-policy`, `team-b-policy` |
| External group aliases | `/devops` → `devops-policy`, `/team-a` → `team-a-policy`, `/team-b` → `team-b-policy` |

Group-to-Vault access after setup:

| Keycloak Group | Vault Access |
|----------------|--------------|
| `devops` | All paths `*` (full admin) |
| `team-a` | `secret/data/team-a/*` only |
| `team-b` | `secret/data/team-b/*` only |

Vault login:
```bash
# Browser (http redirects automatically to https via 308):
#   https://vault-webui.local → OIDC → role: default

# CLI:
vault login -method=oidc -address=https://vault-webui.local role=default
```

---

## kubectl SSO

The `k8s-oidc/` directory wires the **kube-apiserver** to Keycloak so that
`kubectl` users authenticate with their Keycloak credentials instead of
client certificates. Run **after** the Vault integration is set up:

```bash
cd k8s-oidc/
chmod +x setup.sh
./setup.sh
```

See [k8s-oidc/README.md](k8s-oidc/README.md) for the full guide including
kubelogin setup and per-team access examples.

---

## Re-importing the Realm

If you update `kind-realm.json` and want to re-import:

```bash
# 1. Update the ConfigMap
kubectl create configmap keycloak-realm-import \
  --from-file=kind-realm.json=kind-realm.json \
  --namespace keycloak --dry-run=client -o yaml | kubectl apply -f -

# 2. Delete the realm via kcadm (Keycloak skips import if realm exists)
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "Admin@Keycloak2024!"

kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh delete realms/kind

# 3. Restart Keycloak to trigger re-import
kubectl rollout restart deployment/keycloak -n keycloak
kubectl rollout status deployment/keycloak -n keycloak --timeout=300s
```

---

## Useful Commands

```bash
# Check pod status
kubectl get pods -n keycloak

# Stream Keycloak logs (realm import visible here)
kubectl logs -n keycloak -l app=keycloak -f

# Stream PostgreSQL logs
kubectl logs -n keycloak -l app=keycloak-postgresql -f

# Check ingress
kubectl get ingress -n keycloak

# Open kcadm shell session
kubectl exec -it -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080 --realm master \
  --user admin --password "Admin@Keycloak2024!"

# List all groups in kind realm
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get groups -r kind

# List all users in kind realm
kubectl exec -n keycloak deployment/keycloak -- \
  /opt/keycloak/bin/kcadm.sh get users -r kind

# Get an access token for a user (useful for API testing)
curl -s -X POST https://keycloak.local/realms/kind/protocol/openid-connect/token \
  --cacert keycloak/k8s-oidc/keycloak-local-ca.crt \
  -d "client_id=admin-cli&grant_type=password&username=devops-user-1&password=password" \
  | python3 -m json.tool
```

---

## Uninstall

```bash
# Remove everything (namespace, PVCs, secrets, pods)
kubectl delete ns keycloak
```

---

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERR_NAME_NOT_RESOLVED` in browser | `/etc/hosts` entry missing | `sudo sh -c 'echo "127.0.0.1  keycloak.local" >> /etc/hosts'` |
| `keycloak` pod stuck in `Init:0/1` | PostgreSQL not ready | `kubectl logs -n keycloak keycloak-postgresql-0` |
| `Realm 'kind' already exists. Import skipped` | Expected on restarts after first import | Re-import steps above if you changed `kind-realm.json` |
| Keycloak pod `CrashLoopBackOff` | DB connection refused | Check postgres pod is Running; check secret values match |
| `403 Forbidden` on admin console | Wrong realm URL | Use `/admin/kind/console` for realm-admin users, `/admin` for super-admin |
| Slow Keycloak pages on first request | JVM cold start / CPU throttle | Resources are tuned; wait ~30 s for JIT warm-up on first load |
| Vault OIDC login fails with `connection refused` | `keycloak.local` not in CoreDNS | Re-run `vault-integration/setup.sh` (Step 1 patches CoreDNS) |
