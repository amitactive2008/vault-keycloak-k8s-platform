# Keycloak on Kind Cluster

Production-grade Keycloak 26.3.3 deployed on a local kind cluster using official images and plain Kubernetes manifests.

---

## Architecture

```
                         ┌─────────────────────────────┐
Browser ──► 127.0.0.1:80 │  kind node (control-plane)  │
                         │   nginx Ingress Controller   │
                         └──────────────┬──────────────┘
                                        │ keycloak.local
                         ┌──────────────▼──────────────┐
                         │  Namespace: keycloak         │
                         │                              │
                         │  Keycloak 26.3.3 (Deployment)│
                         │  quay.io/keycloak/keycloak   │
                         │         │                    │
                         │  PostgreSQL 17 (StatefulSet) │
                         │  docker.io/library/postgres  │
                         └─────────────────────────────┘
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
├── ingress.yaml              ← nginx Ingress (keycloak.local → port 80; TLS on 443)
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

### 1. Start the kind cluster (if not already running)

```bash
kind create cluster --config ../deploy/kind.yaml
kubectl apply -f ../deploy/deploy-ingress-nginx.yaml
```

### 2. Run the install script

```bash
cd keycloak/
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
sudo sh -c 'echo "127.0.0.1  keycloak.local" >> /etc/hosts'
```

### 4. Access the Admin Console

| Field    | Value |
|----------|-------|
| URL      | http://keycloak.local/admin |
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

HTTP (used by Vault internal OIDC):
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
# Browser (both work):
#   http://vault-webui.local  → OIDC → role: default
#   https://vault-webui.local → OIDC → role: default

# CLI:
vault login -method=oidc -address=http://vault-webui.local role=default
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
curl -s -X POST http://keycloak.local/realms/kind/protocol/openid-connect/token \
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
