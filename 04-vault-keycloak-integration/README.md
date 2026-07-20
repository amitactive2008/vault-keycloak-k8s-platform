# Vault ↔ Keycloak OIDC Integration

Connects HashiCorp Vault's authentication layer to Keycloak so users log in
to the Vault UI and CLI using their Keycloak credentials.  Group membership in
Keycloak automatically determines what secrets each user can access in Vault.

---

## How it works

```
User opens https://vault.kind.local/ui
         │
         │  1. Selects "OIDC" auth method, clicks Sign In
         ▼
Vault redirects browser to Keycloak:
  https://keycloak.kind.local/realms/kind/protocol/openid-connect/auth
  ?client_id=vault&redirect_uri=.../oidc/callback&response_type=code
         │
         │  2. User enters Keycloak credentials (e.g. team-a-user-1 / password)
         ▼
Keycloak issues Authorization Code → browser redirected back to Vault callback
         │
         │  3. Vault exchanges code for tokens (server-to-server, internal)
         │     Vault → https://keycloak.kind.local/realms/kind/...
         │     (CoreDNS resolves keycloak.kind.local inside the cluster)
         ▼
Vault receives JWT containing:
  { "sub": "uuid", "preferred_username": "team-a-user-1",
    "groups": ["/team-a"], "aud": "vault" }
         │
         │  4. Vault looks up group alias "/team-a"
         │     → maps to external identity group "team-a"
         │     → team-a-policy attached
         ▼
User is logged in with team-a-policy
  → can read/write secret/data/team-a/*
  → cannot access secret/data/team-b/* or secret/data/devops/*
```

---

## Access matrix

| Keycloak group | Keycloak JWT claim | Vault group alias | Vault policy | Allowed paths |
|----------------|--------------------|-------------------|--------------|---------------|
| `/devops` | `"groups":["/devops"]` | `/devops` | `devops-policy` | `*` (all paths) |
| `/team-a` | `"groups":["/team-a"]` | `/team-a` | `team-a-policy` | `secret/data/team-a/*` |
| `/team-b` | `"groups":["/team-b"]` | `/team-b` | `team-b-policy` | `secret/data/team-b/*` |

---

## Folder structure

```
04-vault-keycloak-integration/
├── setup.sh           ← end-to-end integration script (run this)
└── policies/
    ├── devops.hcl     ← full admin: path "*" { capabilities = [..., "sudo"] }
    ├── team-a.hcl     ← scoped to secret/data/team-a/*
    └── team-b.hcl     ← scoped to secret/data/team-b/*
```

---

## Prerequisites

Before running `setup.sh`, confirm the following are complete:

| Step | What to check |
|------|---------------|
| `02-vault` | Vault is deployed, initialised, and **unsealed** |
| `02-vault/cluster-keys.json` | Root token file exists locally (not committed) |
| `03-keycloak` | Keycloak is deployed and healthy |
| `03-keycloak` → `kind` realm | Groups `devops`, `team-a`, `team-b` exist |
| `pki/kind.localCA.crt` | Shared CA cert exists at the project root (created in `02-vault` Step 4a) |

> `setup.sh` uses the CA cert at `pki/kind.localCA.crt` to embed the CA PEM
> into the Vault OIDC config so Vault can verify Keycloak's TLS certificate.
> If this file is missing, Step 5 fails silently and OIDC login shows
> `Authentication failed: Invalid role`.

```bash
# Quick pre-flight checks
kubectl get pods -n vault        # all 3 vault-* pods Running, vault-0 active
kubectl get pods -n keycloak     # keycloak-* Running
kubectl exec -n vault vault-0 -- vault status | grep Sealed   # Sealed: false
```

---

## Run the integration

```bash
cd 04-vault-keycloak-integration
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — re-running it skips resources that already exist.

### What each step does

| Step | Action |
|------|--------|
| **0** | Validates `kubectl` and `python3` are available; confirms cluster is reachable |
| **1** | Patches CoreDNS to resolve `keycloak.kind.local` → nginx ClusterIP inside the cluster so Vault pods can reach Keycloak over HTTPS |
| **2** | Creates a **confidential** OIDC client `vault` in the Keycloak `kind` realm with a groups-claim mapper (`full.path=true` → `/devops`, `/team-a`, `/team-b`); syncs redirect URIs |
| **3** | Enables the **KV v2** secret engine at `secret/` |
| **4** | Uploads the three HCL policy files (`devops-policy`, `team-a-policy`, `team-b-policy`) to Vault |
| **5** | Enables the **OIDC auth method** and writes its config (discovery URL → Keycloak, CA cert, client ID/secret, default role) |
| **6** | Creates the OIDC role `default` — specifies which JWT claims to read (`sub`, `groups`), allowed redirect URIs, and token TTLs |
| **7** | Creates **external identity groups** (`devops`, `team-a`, `team-b`) and **group aliases** that link each JWT group name to a Vault group so policy assignment is automatic |
| **8** | Seeds sample secrets so you can immediately verify access |

---

## Why CoreDNS needs patching (Step 1)

Vault pods live inside Kubernetes and cannot read the host's `/etc/hosts`.
When Vault's OIDC auth method fetches the discovery document or exchanges
tokens, the request originates from inside the cluster. CoreDNS must resolve
`keycloak.kind.local` to the nginx ingress ClusterIP (the only endpoint that
handles TLS on port 443), not directly to the Keycloak pod (which only speaks
HTTP).

```
vault-0 pod
  → nslookup keycloak.kind.local
  → CoreDNS: 10.96.x.x (nginx ingress ClusterIP)
  → nginx: TLS termination → keycloak service:80
  → Keycloak pod
```

Without this patch the OIDC discovery URL returns an error and the Vault
OIDC config write fails.

---

## Vault policies

### `devops-policy` — full admin

```hcl
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
```

### `team-a-policy` — scoped to `secret/data/team-a/*`

```hcl
path "secret/data/team-a/*"     { capabilities = ["create","read","update","delete","list"] }
path "secret/metadata/team-a/*" { capabilities = ["read","list","delete"] }
path "secret/delete/team-a/*"   { capabilities = ["update"] }
path "secret/undelete/team-a/*" { capabilities = ["update"] }
path "secret/destroy/team-a/*"  { capabilities = ["update"] }
```

`team-b-policy` mirrors this for `secret/data/team-b/*`.

---

## Seeded sample secrets

After setup, these paths exist for testing:

| Path | Contents |
|------|----------|
| `secret/team-a/config` | `app=team-a-service env=kind owner=team-a` |
| `secret/team-a/db` | `host=db.team-a port=5432 password=changeme` |
| `secret/team-b/config` | `app=team-b-service env=kind owner=team-b` |
| `secret/team-b/db` | `host=db.team-b port=5432 password=changeme` |
| `secret/devops/cluster` | `name=kind-vault region=local nodes=4` |

---

## Login and test after setup

### Browser (Vault UI)

1. Open `https://vault.kind.local/ui`
2. Select method: **OIDC**
3. Enter role: **default**
4. Click **Sign In** — browser redirects to Keycloak login
5. Log in with e.g. `team-a-user-1` / `password`
6. Redirected back to Vault, logged in as team-a

### Vault CLI

```bash
export VAULT_ADDR=https://vault.kind.local

# Login (opens browser for Keycloak SSO)
vault login -method=oidc role=default

# Read a secret you have access to
vault kv get secret/team-a/config

# Try accessing another team's secret (should be denied)
vault kv get secret/team-b/config
# Error: 1 error occurred: * permission denied
```

### Verify group policy assignment

```bash
# After logging in, check your token's policies
vault token lookup | grep -E "policies|display_name"
```

---

## Verify the configuration

```bash
# Set VAULT_ADDR to the ingress URL (HTTPS from your laptop)
export VAULT_ADDR=https://vault.kind.local
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('../02-vault/cluster-keys.json'))['root_token'])")

# Check OIDC auth is enabled
vault auth list | grep oidc

# Check OIDC config (discovery URL, default role)
vault read auth/oidc/config

# Check OIDC role
vault read auth/oidc/role/default

# List identity groups
vault list identity/group/name

# List policies
vault policy list

# Check CoreDNS resolved keycloak.kind.local from vault-0
kubectl exec -n vault vault-0 -- nslookup keycloak.kind.local
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `error checking oidc discovery URL` during setup | CoreDNS hasn’t resolved yet, or TLS secret missing in `keycloak` ns | Re-run Step 1; run `kubectl get secret keycloak-local-tls -n keycloak` |
| `Authentication failed: Invalid role` in Vault UI | OIDC config not written (Step 5 failed silently) | Check `vault read auth/oidc/config` — if empty, re-run `./setup.sh`. Most common cause: `pki/kind.localCA.crt` missing |
| `No value found at auth/oidc/config` | Step 5 failed | Verify `pki/kind.localCA.crt` exists at the project root; then re-run `./setup.sh` |
| User logs in but gets `permission denied` | Group alias not created or JWT groups claim missing | Check `vault list identity/group/name`; verify Keycloak `vault` client has a groups mapper with `full.path=true` |
| CoreDNS smoke-test shows `UNRESOLVED` | nginx ingress IP changed (e.g. after cluster restart) | Re-run the script — Step 1 re-patches CoreDNS automatically |

---

## Re-running after a cluster restart

Vault pods restart **sealed** after every cluster restart. Unseal them first
(see `02-vault/README.md` Step 6), then re-run this script if the OIDC config
was lost:

```bash
cd 04-vault-keycloak-integration
./setup.sh
```

The script skips everything that still exists and only re-applies missing
pieces (typically just the OIDC config, since Vault storage is persistent via
Raft PVCs).
