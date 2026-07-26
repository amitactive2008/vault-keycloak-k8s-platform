# Vault ↔ Keycloak OIDC Integration

Connects HashiCorp Vault's authentication layer to Keycloak so users log in
to the Vault UI and CLI using their Keycloak credentials. Group membership in
Keycloak automatically determines which secrets each user can access in Vault.

---

## How it works

```
User opens https://vault.kind.local/ui
         │
         │  1. Selects "OIDC" auth method, role "default", clicks Sign In
         ▼
Vault redirects browser to Keycloak:
  https://keycloak.kind.local/realms/kind/protocol/openid-connect/auth
  ?client_id=vault&redirect_uri=.../oidc/callback&response_type=code
         │
         │  2. User enters Keycloak credentials (e.g. team-a-user-1 / password)
         ▼
Keycloak issues Authorization Code → browser redirected back to Vault callback
         │
         │  3. Vault exchanges code for tokens (server-to-server, in-cluster)
         │     vault-0 → https://keycloak.kind.local/realms/kind/...
         │     (CoreDNS resolves keycloak.kind.local → Envoy Gateway ClusterIP)
         ▼
Vault receives JWT:
  { "sub": "uuid", "preferred_username": "team-a-user-1",
    "groups": ["/team-a"], "aud": "vault" }
         │
         │  4. Vault looks up group alias "/team-a"
         │     → maps to external identity group "team-a"
         │     → team-a-policy attached
         ▼
User logged in with team-a-policy
  → can read/write secret/data/team-a/*
  → cannot access secret/data/team-b/* or secret/data/devops/*
```

---

## Access matrix

| Keycloak group | JWT claim | Vault group | Vault policy | Allowed paths |
|----------------|-----------|-------------|--------------|---------------|
| `/devops` | `"groups":["/devops"]` | `devops` | `devops-policy` | `*` (all paths) |
| `/team-a` | `"groups":["/team-a"]` | `team-a` | `team-a-policy` | `secret/data/team-a/*` |
| `/team-b` | `"groups":["/team-b"]` | `team-b` | `team-b-policy` | `secret/data/team-b/*` |

---

## Folder structure

```
04-vault-keycloak-integration/
├── setup.sh           ← end-to-end integration script (idempotent)
└── policies/
    ├── devops.hcl     ← full admin: path "*" { capabilities = [..., "sudo"] }
    ├── team-a.hcl     ← scoped to secret/data/team-a/*
    └── team-b.hcl     ← scoped to secret/data/team-b/*
```

---

## Prerequisites

| Step | What to check |
|------|---------------|
| `01-cloud-provider-kind-setup-with-gw-api` | Envoy Gateway running, `native-gateway` programmed |
| `02-vault` | Vault deployed, initialised, **unsealed** (all 3 pods) |
| `03-keycloak` | Keycloak running, `kind` realm with groups imported |

```bash
# Quick pre-flight
kubectl get pods -n vault    # vault-0/1/2: 1/1 Running
kubectl get pods -n keycloak # keycloak-*: 1/1 Running
kubectl exec -n vault vault-0 -- vault status | grep Sealed  # Sealed: false
```

---

## Run the integration

```bash
cd 04-vault-keycloak-integration
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — re-running skips resources that already exist.

### What each step does

| Step | Action |
|------|--------|
| **0** | Validates `kubectl` + `python3`, confirms cluster is reachable |
| **1** | Patches CoreDNS: `keycloak.kind.local` → Envoy Gateway ClusterIP so Vault pods reach Keycloak over HTTPS in-cluster |
| **2** | Creates confidential OIDC client `vault` in Keycloak `kind` realm with groups-claim mapper (`full.path=true` → `/devops`, `/team-a`, `/team-b`) |
| **3** | Enables KV v2 engine at `secret/` |
| **4** | Uploads `devops-policy`, `team-a-policy`, `team-b-policy` to Vault |
| **5** | Enables OIDC auth method; writes discovery URL (`https://keycloak.kind.local/realms/kind`), CA cert, client ID/secret |
| **6** | Creates OIDC role `default` — reads `sub` + `groups` claims, sets redirect URIs and TTLs |
| **7** | Creates external identity groups (`devops`, `team-a`, `team-b`) and group aliases linking JWT group names to Vault groups |
| **8** | Seeds sample secrets for immediate access testing |

---

## Why CoreDNS needs patching (Step 1)

Vault pods live inside Kubernetes and cannot read the host `/etc/hosts`. When Vault's OIDC
auth method fetches the discovery document or exchanges tokens, the call originates from
inside the cluster. CoreDNS must resolve `keycloak.kind.local` to the Envoy Gateway's
ClusterIP — the endpoint that terminates TLS (`*.kind.local` wildcard cert) and proxies
to the Keycloak pod.

```
vault-0 pod
  → HTTPS keycloak.kind.local:443
  → CoreDNS: 10.96.x.x (Envoy Gateway ClusterIP)
  → Envoy Gateway: TLS termination → keycloak service:80
  → Keycloak pod
```

---

## Seeded sample secrets

| Path | Contents |
|------|----------|
| `secret/team-a/config` | `app=team-a-service env=kind owner=team-a` |
| `secret/team-a/db` | `host=db.team-a port=5432 password=changeme` |
| `secret/team-b/config` | `app=team-b-service env=kind owner=team-b` |
| `secret/team-b/db` | `host=db.team-b port=5432 password=changeme` |
| `secret/devops/cluster` | `name=kind-vault region=local nodes=4` |

---

## Login and test

### Browser (Vault UI)

1. Open `https://vault.kind.local/ui`
2. Select method: **OIDC**
3. Enter role: **default**
4. Click **Sign In** → browser redirects to Keycloak
5. Log in with e.g. `team-a-user-1` / `password`
6. Redirected back to Vault, logged in with `team-a-policy`

### Vault CLI

```bash
export VAULT_ADDR=https://vault.kind.local

# Extract the CA cert from cert-manager (once per session)
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/kind-local-ca.crt
export VAULT_CACERT=/tmp/kind-local-ca.crt

# Login (opens browser for Keycloak SSO)
vault login -method=oidc role=default

# Read a secret you have access to
vault kv get secret/team-a/config

# Try another team's secret (denied)
vault kv get secret/team-b/config
# Error: permission denied
```

---

## Verify the configuration

```bash
export VAULT_ADDR=https://vault.kind.local
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/kind-local-ca.crt
export VAULT_CACERT=/tmp/kind-local-ca.crt
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('../02-vault/cluster-keys.json'))['root_token'])")

vault auth list | grep oidc                  # oidc/ enabled
vault read auth/oidc/config                  # discovery URL + CA
vault read auth/oidc/role/default            # groups_claim, redirect URIs
vault list identity/group/name               # devops, team-a, team-b
vault policy list                            # devops-policy, team-a-policy, team-b-policy
vault kv list secret/                        # devops/, team-a/, team-b/

# Confirm CoreDNS resolves keycloak from inside the cluster
kubectl exec -n vault vault-0 -- nslookup keycloak.kind.local
```

---

## Re-running after a cluster restart

Vault pods start **sealed** after every cluster restart. Unseal them first
(see `02-vault/README.md`), then re-run the script to re-apply any in-memory
config that was lost:

```bash
cd 04-vault-keycloak-integration && ./setup.sh
```

The script is idempotent — it skips what already exists in Raft storage and
only re-creates the CoreDNS patch and OIDC config if missing.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `error checking oidc discovery URL` | CoreDNS not yet propagated / Envoy GW IP changed | Re-run `./setup.sh` (Step 1 re-patches automatically) |
| `Authentication failed: Invalid role` in Vault UI | OIDC config missing or CA cert wrong | `vault read auth/oidc/config` — if empty, re-run script |
| User logs in but gets `permission denied` | Group alias not created or JWT `groups` claim missing | `vault list identity/group/name`; verify Keycloak `vault` client has groups mapper |
| `connection refused` on token exchange | Envoy Gateway ClusterIP changed | Re-run `./setup.sh` to update CoreDNS |
