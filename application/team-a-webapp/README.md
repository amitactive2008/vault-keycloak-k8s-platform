# Team-A Webapp — 2-Tier Application with Vault Secret Injection

A demo 2-tier web application deployed in the `team-a` namespace. It demonstrates
two Vault features on Kubernetes:

| Feature | What it shows |
|---------|--------------|
| **Vault Agent sidecar injection** | Backend pod authenticates to Vault via its K8s service account token and receives DB credentials at `/vault/secrets/db.env` — no hardcoded secrets anywhere |
| **Kubernetes secrets engine** | Vault dynamically generates short-lived Kubernetes service account tokens on demand (`vault read kubernetes/creds/team-a-webapp-sa`) |

---

## Architecture

```
Browser
  │
  ▼
http://team-a-webapp.local          (/etc/hosts → 127.0.0.1)
  │
  ▼
nginx Ingress (ingress-nginx)
  │
  ├── /api/*  ──────────────────────► webapp-backend (Python, :5000)
  │                                        │
  │                                        │  reads /vault/secrets/db.env
  │                                        ▼
  │                                   vault-agent sidecar
  │                                        │  Kubernetes auth
  │                                        ▼
  │                                   Vault (secret/data/team-a/webapp/db)
  │                                        │
  │                                        ▼
  │                                   PostgreSQL (:5432)
  │
  └── /*  ──────────────────────────► webapp-frontend (nginx, :80)
```

### Components

| Resource | Kind | Namespace | Image |
|----------|------|-----------|-------|
| `webapp-frontend` | Deployment | `team-a` | `nginx:alpine` |
| `webapp-backend` | Deployment | `team-a` | `python:3.11-slim` |
| `postgres` | StatefulSet | `team-a` | `postgres:16-alpine` |
| `team-a-webapp` | Ingress | `team-a` | — |
| `webapp-backend` | ServiceAccount | `team-a` | — |

---

## File Structure

```
application/team-a-webapp/
├── vault-setup.sh        ← one-time Vault configuration script
├── vault-rbac.yaml       ← RBAC: grants vault SA permission to issue K8s tokens
├── serviceaccount.yaml   ← webapp-backend ServiceAccount (used by Vault Agent auth)
├── postgres.yaml         ← PostgreSQL StatefulSet + headless Service + init Secret
├── backend.yaml          ← Python API server + Vault Agent sidecar annotations
├── frontend.yaml         ← nginx SPA + /api/ reverse proxy
└── ingress.yaml          ← ingress-nginx on team-a-webapp.local
```

---

## Prerequisites

- Vault deployed and unsealed (`vault/`)
- Keycloak deployed with OIDC integration (`keycloak/vault-integration/setup.sh` run)
- `team-a` namespace exists (created by `keycloak/k8s-oidc/setup.sh`)
- `vault/cluster-keys.json` present (contains root token)

---

## Deployment

### Step 1 — Grant Vault SA the RBAC to issue Kubernetes tokens

```bash
kubectl apply -f application/team-a-webapp/vault-rbac.yaml
```

This creates a `ClusterRole` + `ClusterRoleBinding` so the `vault` service account
can call the Kubernetes `TokenRequest` API — required by the Kubernetes secrets engine.

### Step 2 — Configure Vault (run once)

```bash
cd application/team-a-webapp/
chmod +x vault-setup.sh
./vault-setup.sh
```

The script:
1. Writes DB credentials to `secret/data/team-a/webapp/db`
2. Creates Vault policy `team-a-webapp` (read-only on `secret/data/team-a/webapp/*`)
3. Enables and configures the **Kubernetes auth method** (pod SA token login)
4. Creates auth role `team-a-webapp` bound to the `webapp-backend` SA in `team-a`
5. Enables and configures the **Kubernetes secrets engine** (in-cluster)
6. Creates secrets engine role `team-a-webapp-sa` to generate SA tokens dynamically

### Step 3 — Deploy the application

```bash
kubectl apply -f application/team-a-webapp/serviceaccount.yaml
kubectl apply -f application/team-a-webapp/postgres.yaml
kubectl apply -f application/team-a-webapp/backend.yaml
kubectl apply -f application/team-a-webapp/frontend.yaml
kubectl apply -f application/team-a-webapp/ingress.yaml
```

### Step 4 — Add local DNS entry (one-time)

```bash
echo "127.0.0.1 team-a-webapp.local" | sudo tee -a /etc/hosts
```

> **macOS `.local` DNS note:** macOS routes `.local` domains through mDNS by
> default, which causes `curl` and browsers to time out. Use the IP directly
> or `curl --resolve team-a-webapp.local:80:127.0.0.1 http://team-a-webapp.local`
> if you see hangs.

---

## Verify

### Check all pods are Running / Ready

```bash
kubectl get po,svc,ingress -n team-a
```

Expected:

```
NAME                                   READY   STATUS    RESTARTS
pod/postgres-0                         1/1     Running   0
pod/webapp-backend-<hash>              2/2     Running   0   ← 2/2 = app + vault-agent sidecar
pod/webapp-frontend-<hash>             1/1     Running   0

NAME                      TYPE        CLUSTER-IP      PORTS
service/postgres          ClusterIP   None            5432/TCP
service/webapp-backend    ClusterIP   <ip>            5000/TCP
service/webapp-frontend   ClusterIP   <ip>            80/TCP

NAME                              CLASS   HOSTS                 ADDRESS
ingress/team-a-webapp             nginx   team-a-webapp.local   localhost
```

> `webapp-backend` shows **2/2** because the Vault Agent sidecar container
> is injected alongside the main app container.

### Confirm Vault Agent injected the secret

```bash
kubectl exec -n team-a deploy/webapp-backend -c backend -- cat /vault/secrets/db.env
```

Expected output:

```
export DB_HOST=postgres.team-a.svc.cluster.local
export DB_PORT=5432
export DB_USER=webapp_user
export DB_PASSWORD=S3cur3P@ssw0rd
export DB_NAME=webapp_db
```

### Test the API endpoints

```bash
# Backend health
curl --resolve team-a-webapp.local:80:127.0.0.1 http://team-a-webapp.local/api/health

# Vault-injected DB credentials (password masked)
curl --resolve team-a-webapp.local:80:127.0.0.1 http://team-a-webapp.local/api/db-creds

# TCP connectivity to PostgreSQL
curl --resolve team-a-webapp.local:80:127.0.0.1 http://team-a-webapp.local/api/db-status
```

### Open in browser

```
http://team-a-webapp.local
```

Use the three buttons to verify backend health, Vault injection, and DB connectivity.

---

## Vault Secret Access (team-a users)

DB credentials are stored at a path that all `team-a` group members can read
**and modify** through the existing `team-a-policy`:

```bash
# Log in to Vault as a team-a user (OIDC)
vault login -method=oidc -path=oidc role=default

# Read the DB secret
vault kv get secret/team-a/webapp/db

# Update the DB password
vault kv patch secret/team-a/webapp/db password="NewP@ssw0rd"
```

After updating a secret, the Vault Agent sidecar automatically re-renders
`/vault/secrets/db.env` in the backend pod within the next lease cycle (~1 min).

---

## Kubernetes Secrets Engine (dynamic SA tokens)

The Kubernetes secrets engine is configured with a role that can generate
short-lived tokens for the `webapp-backend` service account:

```bash
# Authenticate to Vault (as devops or team-a user)
vault login -method=oidc -path=oidc role=default

# Request a dynamic Kubernetes service account token
vault read kubernetes/creds/team-a-webapp-sa \
  kubernetes_namespace=team-a

# Sample output:
# Key                          Value
# ---                          -----
# service_account_name         webapp-backend
# service_account_namespace    team-a
# service_account_token        eyJhbGci...   ← short-lived K8s token (TTL: 1h)
```

This token can be used as a `Bearer` token against the Kubernetes API — it
expires automatically and is never stored long-term.

---

## Cleanup

```bash
kubectl delete -f application/team-a-webapp/ingress.yaml
kubectl delete -f application/team-a-webapp/frontend.yaml
kubectl delete -f application/team-a-webapp/backend.yaml
kubectl delete -f application/team-a-webapp/postgres.yaml
kubectl delete -f application/team-a-webapp/serviceaccount.yaml
kubectl delete -f application/team-a-webapp/vault-rbac.yaml

# Remove the Vault configuration (requires root token)
vault login -method=token   # root token
vault kv delete secret/team-a/webapp/db
vault auth disable kubernetes
vault secrets disable kubernetes
vault policy delete team-a-webapp
```
