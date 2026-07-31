# Team-A Webapp — 2-Tier Application with Vault Secret Injection

A demo 2-tier web application deployed in the `team-a` namespace that showcases
two HashiCorp Vault features on Kubernetes:

| Feature | What it demonstrates |
|---------|---------------------|
| **Vault Agent sidecar injection** | Backend pod authenticates to Vault via its Kubernetes ServiceAccount token and receives DB credentials at `/vault/secrets/db.env` — no hardcoded secrets anywhere |
| **Kubernetes secrets engine** | Vault dynamically generates short-lived Kubernetes ServiceAccount tokens on demand (`vault read kubernetes/creds/team-a-webapp-sa`) |

---

## Architecture

```
https://team-a-webapp.kind.local  (/etc/hosts → 127.0.0.1)
  │
  ▼
Envoy Gateway (native-gateway, default ns)
  HTTPS:443 → wildcard *.kind.local TLS termination
  │
  ├── /api/*  ──────────────────► webapp-backend (Python :5000)
  │                                    │
  │                             reads /vault/secrets/db.env
  │                                    │
  │                             vault-agent sidecar
  │                                    │  Kubernetes auth (SA token)
  │                                    ▼
  │                             Vault (secret/data/team-a/webapp/db)
  │
  └── /       ──────────────────► webapp-frontend (nginx :80)
                                    static HTML + JS, calls /api/*
                                          │
                                          ▼
                                    postgres (StatefulSet :5432)
```

---

## Install sequence

### Prerequisites

- `02-vault` — Vault deployed, initialised, unsealed
- `04-vault-keycloak-integration` — KV v2 enabled at `secret/`, team-a-policy applied
- `01-cloud-provider-kind-setup-with-gw-api` — Envoy Gateway running with HTTPS on port 443

### Step 1 — Configure Vault

Run `vault-setup.sh` once. It is idempotent.

```bash
cd 07-application/team-a-webapp
chmod +x vault-setup.sh
./vault-setup.sh
```

What it does:

| Step | Action |
|------|--------|
| 1 | Writes DB credentials to `secret/data/team-a/webapp/db` |
| 2 | Creates `team-a-webapp` Vault policy (read `secret/data/team-a/webapp/*`) |
| 3–5 | Enables Kubernetes auth method and binds `webapp-backend` SA to the policy |
| 6–8 | Enables Kubernetes secrets engine for dynamic SA token generation |

### Step 2 — Add DNS entry

```bash
echo "127.0.0.1 team-a-webapp.kind.local" | sudo tee -a /etc/hosts
```

### Step 3 — Install via Helm

```bash
helm upgrade --install team-a-webapp ./webapp-chart \
  -f ./values.yaml \
  --namespace team-a --create-namespace
```

Watch pods start:

```bash
kubectl get pods -n team-a -w
# webapp-backend-xxx    2/2 Running   ← main + vault-agent sidecar
# webapp-frontend-xxx   1/1 Running
# postgres-0            1/1 Running
```

### Step 4 — Verify

```bash
# Frontend page (HTTPS — CA is trusted in macOS System Keychain after Step 1 setup)
curl -s https://team-a-webapp.kind.local/ | grep title

# Backend health
curl -s https://team-a-webapp.kind.local/api/health

# Vault-injected DB credentials (password is redacted)
curl -s https://team-a-webapp.kind.local/api/db-creds

# DB connectivity (via Vault-injected credentials)
curl -s https://team-a-webapp.kind.local/api/db-status

# HTTP → HTTPS redirect
curl -sv http://team-a-webapp.kind.local/ 2>&1 | grep -E "HTTP|Location"
```

Open in browser: **https://team-a-webapp.kind.local**

---

## Vault integration details

### Secret injection flow

```
webapp-backend pod starts
  └── vault-agent sidecar (injected by Vault mutating webhook)
        │
        │ 1. Reads projected SA token from /var/run/secrets/…
        │ 2. POST auth/kubernetes/login { role=team-a-webapp, jwt=<token> }
        ▼
      Vault validates SA token against kube-apiserver
        │ 3. Returns short-lived Vault token
        ▼
      vault-agent fetches secret/data/team-a/webapp/db
        │ 4. Renders template → /vault/secrets/db.env
        │    export DB_HOST=postgres.team-a.svc.cluster.local
        │    export DB_PORT=5432
        │    export DB_USER=webapp_user
        │    export DB_PASSWORD=<secret>
        │    export DB_NAME=webapp_db
        │ 5. Sends SIGHUP to PID 1 on renewal (hot-reload)
        ▼
      backend reads /vault/secrets/db.env on startup
```

### Vault paths used

| Path | Purpose |
|------|---------|
| `auth/kubernetes/role/team-a-webapp` | Binds `webapp-backend` SA to `team-a-webapp` policy |
| `secret/data/team-a/webapp/db` | DB credentials read by Vault Agent |
| `kubernetes/roles/team-a-webapp-sa` | Dynamic SA token generation role |

---

## Upgrade

```bash
helm upgrade team-a-webapp ./webapp-chart \
  -f ./values.yaml --namespace team-a
```

## Uninstall

```bash
helm uninstall team-a-webapp --namespace team-a
```

Do not delete the `team-a` namespace when module 09 or another Team A workload
is installed there. To remove the namespace only after confirming it is empty:

```bash
kubectl get all,secret,configmap,pvc,httproute -n team-a
kubectl delete namespace team-a
```

Namespace deletion is destructive and also removes retained PVCs, Secrets,
RBAC, and every other Team A workload in that namespace.

---

## Useful commands

```bash
# Pod status
kubectl get pods -n team-a -o wide

# Backend logs (Python server)
kubectl logs -n team-a -l app=webapp-backend -c backend

# Vault Agent sidecar logs
kubectl logs -n team-a -l app=webapp-backend -c vault-agent

# PostgreSQL logs
kubectl logs -n team-a postgres-0

# Check which variables were injected without printing their secret values
kubectl exec -n team-a deploy/webapp-backend -c backend \
  -- sh -c "sed 's/=.*$/=<redacted>/' /vault/secrets/db.env"

# HTTPRoutes
kubectl get httproute -n team-a

# Helm history
helm history team-a-webapp -n team-a

# Generate a dynamic SA token via Kubernetes secrets engine
export VAULT_ADDR=https://vault.kind.local
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('../../02-vault/cluster-keys.json'))['root_token'])")
vault read kubernetes/creds/team-a-webapp-sa
```

---

## Troubleshooting

**`webapp-backend` stuck at `1/2` (vault-agent not ready)**

Vault Agent can't authenticate. Check:
```bash
kubectl logs -n team-a -l app=webapp-backend -c vault-agent | tail -20
```
Most likely causes: `vault-setup.sh` not run, or Vault is sealed.

**`vault_injected: false` from `/api/db-creds`**

Secret file `/vault/secrets/db.env` not yet written. Check vault-agent logs above.

**`https://team-a-webapp.kind.local` returns 404**

HTTPRoute not attached. Check:
```bash
kubectl get httproute -n team-a
kubectl get gateway native-gateway -n default
```

**DB connectivity check fails**

PostgreSQL pod may still be initialising. Check: `kubectl logs -n team-a postgres-0`
