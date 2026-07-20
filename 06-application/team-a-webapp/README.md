# Team-A Webapp — 2-Tier Application with Vault Secret Injection

A demo 2-tier web application deployed in the `team-a` namespace that showcases
two HashiCorp Vault features on Kubernetes:

| Feature | What it demonstrates |
|---------|---------------------|
| **Vault Agent sidecar injection** | Backend pod authenticates to Vault via its Kubernetes ServiceAccount token and receives DB credentials at `/vault/secrets/db.env` — no hardcoded secrets anywhere |
| **Kubernetes secrets engine** | Vault dynamically generates short-lived Kubernetes ServiceAccount tokens on demand (`vault read kubernetes/creds/team-a-webapp-sa`) |

---

## Install sequence

Follow these steps in order. Each item links to the relevant file or section.

- [ ] **1.** Configure Vault — run [`vault-setup.sh`](vault-setup.sh) → see [Step 1 — Configure Vault](#step-1--configure-vault)
- [ ] **2.** Edit overrides if needed — [`values.yaml`](values.yaml)
- [ ] **3.** Deploy the app — `helm install` → see [Step 2 — Install via Helm](#step-2--install-via-helm)
- [ ] **4.** Add DNS entry — `echo "127.0.0.1 team-a-webapp.local" | sudo tee -a /etc/hosts`
- [ ] **5.** Verify pods are Running — `kubectl get pods -n team-a`
- [ ] **6.** Open the app — [http://team-a-webapp.local](http://team-a-webapp.local) → see [Step 3 — Open the app](#step-3--open-the-app)

---

## Architecture

```
Browser
  │
  ▼
http://team-a-webapp.local   (/etc/hosts → 127.0.0.1)
  │
  ▼
nginx Ingress
  │
  ├── /api/*  ─────────────────► webapp-backend (Python :5000)
  │                                    │
  │                             reads /vault/secrets/db.env
  │                                    │
  │                             vault-agent sidecar
  │                                    │  Kubernetes auth
  │                                    ▼
  │                             Vault (secret/data/team-a/webapp/db)
  │
  └── /      ─────────────────► webapp-frontend (nginx :80)
                                  - static HTML + JS
                                  - calls /api/* buttons
                                        │
                                        ▼
                                 PostgreSQL :5432
                                 (team-a namespace)
```

### Components

| Component | Image | Purpose |
|-----------|-------|---------|
| `webapp-backend` | `python:3.11-slim` | Python HTTP API — reads DB creds from Vault, exposes `/api/health`, `/api/db-creds`, `/api/db-status` |
| `webapp-frontend` | `nginx:alpine` | Serves `index.html` — UI with buttons to call the backend API |
| `postgres` | `postgres:16-alpine` | PostgreSQL — receives app traffic from backend |
| Vault Agent sidecar | (injected by Vault injector) | Authenticates to Vault using the `webapp-backend` SA token, renders `db.env` into the backend pod |

---

## Folder structure

```
06-application/team-a-webapp/
├── values.yaml              ← edit this to customise your install
├── vault-setup.sh           ← run first: configures Vault (credentials, policy, auth)
└── webapp-chart/
    ├── Chart.yaml
    ├── values.yaml          ← all chart defaults with comments
    └── templates/
        ├── _helpers.tpl
        ├── serviceaccount.yaml       ← webapp-backend SA (used by Vault Agent)
        ├── vault-rbac.yaml           ← ClusterRole for Vault K8s secrets engine
        ├── postgres-secret.yaml      ← PostgreSQL bootstrap secret
        ├── postgres.yaml             ← StatefulSet + Service
        ├── backend-configmap.yaml    ← server.py script
        ├── frontend-configmap.yaml   ← nginx.conf + index.html
        ├── backend-deployment.yaml   ← Deployment + Service (with Vault annotations)
        ├── frontend-deployment.yaml  ← Deployment + Service
        └── ingress.yaml              ← routes /api/* → backend, / → frontend
```

---

## Prerequisites

| Requirement | What to check |
|-------------|---------------|
| Kind cluster running | `kubectl get nodes` |
| Vault deployed and unsealed (`02-vault`) | `kubectl get pods -n vault` |
| Vault OIDC integration done (`04-vault-keycloak-integration`) | `vault read auth/oidc/config` |
| Vault injector running | `kubectl get pods -n vault -l component=webhook` |
| `team-a` namespace exists | `kubectl get ns team-a` (created by `05-k8s-oidc-with-keycloak/setup.sh`) |
| `02-vault/cluster-keys.json` | Root token file exists locally |

---

## Step 1 — Configure Vault

Run `vault-setup.sh` **once** to configure Vault before deploying the app.

```bash
cd 06-application/team-a-webapp
chmod +x vault-setup.sh
./vault-setup.sh
```

### What vault-setup.sh does

| Step | Action |
|------|--------|
| **1** | Writes DB credentials to `secret/data/team-a/webapp/db` (accessible by all team-a users via `team-a-policy`) |
| **2** | Creates a Vault policy `team-a-webapp` scoped to `secret/data/team-a/webapp/*` (read-only) |
| **3** | Enables the Kubernetes auth method at `auth/kubernetes/` |
| **4** | Configures Kubernetes auth to trust the cluster's CA (`kubernetes.default.svc.cluster.local:443`) |
| **5** | Creates Kubernetes auth role `team-a-webapp` — binds the `webapp-backend` ServiceAccount in namespace `team-a` to `team-a-webapp` policy |
| **6** | Enables the Kubernetes secrets engine at `kubernetes/` |
| **7** | Configures the Kubernetes secrets engine for in-cluster use |
| **8** | Creates a Kubernetes secrets engine role `team-a-webapp-sa` for generating dynamic ServiceAccount tokens |

---

## Step 2 — Install via Helm

```bash
cd 06-application/team-a-webapp

# Preview what will be deployed
helm template team-a-webapp ./webapp-chart \
  -f ./values.yaml \
  --namespace team-a

# Install
helm install team-a-webapp ./webapp-chart \
  -f ./values.yaml \
  --namespace team-a --create-namespace
```

Add the local DNS entry (one-time):

```bash
echo "127.0.0.1 team-a-webapp.local" | sudo tee -a /etc/hosts
```

Watch pods start:

```bash
kubectl get pods -n team-a -w
```

Expected steady state (takes ~30 s):

```
NAME                              READY   STATUS
postgres-0                        1/1     Running
webapp-backend-xxx                2/2     Running   ← 2/2 = app + Vault Agent sidecar
webapp-frontend-xxx               1/1     Running
```

---

## Step 3 — Open the app

Navigate to **http://team-a-webapp.local** in your browser.

The UI has three buttons:

| Button | API endpoint | What it shows |
|--------|-------------|---------------|
| **Backend Health** | `GET /api/health` | Pod hostname and status `ok` |
| **Vault-Injected Creds** | `GET /api/db-creds` | DB credentials from `/vault/secrets/db.env` (password redacted) |
| **DB Connectivity** | `GET /api/db-status` | TCP connectivity check to `postgres.team-a.svc.cluster.local:5432` |

---

## Vault secret injection flow

```
pod starts
  │
  ▼
Vault Agent init container
  → authenticates: POST auth/kubernetes/login
    { "role": "team-a-webapp", "jwt": <webapp-backend SA token> }
  → Vault validates SA token against kube-apiserver
  → issues a Vault token with team-a-webapp policy
  │
  ▼
Vault Agent renders template:
  secret/data/team-a/webapp/db → /vault/secrets/db.env
  export DB_HOST=postgres.team-a.svc.cluster.local
  export DB_PORT=5432
  export DB_USER=webapp_user
  export DB_PASSWORD=S3cur3P@ssw0rd
  export DB_NAME=webapp_db
  │
  ▼
Main container (backend) starts
  → server.py reads /vault/secrets/db.env on every request
  │
  ▼
Vault Agent sidecar keeps running
  → renews Vault token before expiry
  → on secret rotation: re-renders db.env → sends SIGHUP to PID 1
  → server.py SIGHUP handler logs the refresh
  → next request picks up the new credentials (hot-reload, no pod restart)
```

---

## Upgrade

```bash
# After editing values.yaml
helm upgrade team-a-webapp ./webapp-chart \
  -f ./values.yaml \
  --namespace team-a
```

---

## Uninstall

```bash
helm uninstall team-a-webapp --namespace team-a
```

This removes all chart-managed resources. The Vault configuration (policy,
auth role, secrets) created by `vault-setup.sh` is **not** deleted — run the
following if you want a full cleanup:

```bash
export VAULT_ADDR=https://vault.kind.local
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('../../02-vault/cluster-keys.json'))['root_token'])")

vault kv delete secret/team-a/webapp/db
vault policy delete team-a-webapp
vault delete auth/kubernetes/role/team-a-webapp
vault delete kubernetes/roles/team-a-webapp-sa
```

---

## Useful commands

```bash
# Check Vault Agent sidecar injected the secret
kubectl exec -n team-a \
  $(kubectl get pod -n team-a -l app=webapp-backend -o jsonpath='{.items[0].metadata.name}') \
  -c backend -- cat /vault/secrets/db.env

# Check Vault Agent logs
kubectl logs -n team-a \
  $(kubectl get pod -n team-a -l app=webapp-backend -o jsonpath='{.items[0].metadata.name}') \
  -c vault-agent

# Read the DB credentials from Vault directly (as team-a user)
vault kv get secret/team-a/webapp/db

# Generate a dynamic K8s ServiceAccount token (Vault K8s secrets engine)
vault read kubernetes/creds/team-a-webapp-sa

# Helm release status
helm status team-a-webapp -n team-a
```
