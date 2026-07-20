# Kubernetes SSO via Keycloak OIDC

Configures the Kubernetes API server to authenticate users via Keycloak so
`kubectl` logins use Keycloak credentials instead of long-lived kubeconfig
certificates. Group membership in Keycloak drives Kubernetes RBAC automatically.

---

## How it works

```
kubectl get pods  (team-a context)
      │
      │  1. kubectl calls oidc-login (kubelogin plugin)
      │     kubelogin checks ~/.kube/cache/oidc-login/ for a valid token
      │     cache miss → open browser
      ▼
  Browser → https://keycloak.kind.local/realms/kind/protocol/openid-connect/auth
              ?client_id=kubernetes&response_type=code&...
      │
      │  2. User enters credentials (e.g. team-a-user-1 / password)
      │     Keycloak issues Authorization Code
      ▼
  kubelogin exchanges code for tokens (localhost:8000 callback)
  Receives JWT:
    { "iss":    "https://keycloak.kind.local/realms/kind",
      "aud":    "kubernetes",
      "sub":    "uuid",
      "preferred_username": "team-a-user-1",
      "groups": ["team-a"] }          ← flat name, no slash
      │
      │  3. kubectl sends Bearer token to kube-apiserver
      ▼
  kube-apiserver validates JWT:
    --oidc-issuer-url=https://keycloak.kind.local/realms/kind
    --oidc-client-id=kubernetes
    --oidc-username-claim=preferred_username  → User: team-a-user-1
    --oidc-groups-claim=groups                → Groups: [team-a]
    --oidc-ca-file=/etc/kubernetes/pki/kind.localCA.crt
      │
      │  4. RBAC evaluated
      │     group "team-a" → RoleBinding keycloak-team-a-admin → Role admin
      │     namespace scope: team-a only
      ▼
  Request allowed or denied
```

**Key design points:**

- The kube-apiserver is **inside** the kind cluster. `keycloak.kind.local` is
  resolved via the control-plane `/etc/hosts` → nginx ClusterIP (HTTPS).
- `setup.sh` uses the **shared local CA** from `pki/kind.localCA.crt` (project
  root) — the same CA that signs `vault.kind.local`. Only one root cert needs
  to be trusted.
- The `groups` JWT claim uses **flat names** (`team-a`, not `/team-a`) because
  `full.path=false` is set on the Keycloak groups mapper. This matches RBAC
  group subject names directly.
- Vault OIDC is **not affected** — Vault uses CoreDNS → Keycloak ClusterIP
  over HTTP port 80, which coexists independently.

---

## Access matrix

| Keycloak group | Kubernetes RBAC | Allowed |
|----------------|-----------------|---------|
| `devops` | `cluster-admin` (ClusterRoleBinding) | All namespaces, all resources |
| `team-a` | `admin` (RoleBinding, namespace: team-a) | `team-a` namespace only |
| `team-b` | `admin` (RoleBinding, namespace: team-b) | `team-b` namespace only |

### Test users (password: `password`)

| Username | Keycloak group | Expected kubectl access |
|----------|---------------|------------------------|
| `devops-user-1` | `devops` | `kubectl get nodes`, all namespaces |
| `devops-user-2` | `devops` | `kubectl get nodes`, all namespaces |
| `team-a-user-1` | `team-a` | `kubectl get pods -n team-a` only |
| `team-a-user-2` | `team-a` | `kubectl get pods -n team-a` only |
| `team-b-user-1` | `team-b` | `kubectl get pods -n team-b` only |
| `team-b-user-2` | `team-b` | `kubectl get pods -n team-b` only |

---

## Folder structure

```
05-k8s-oidc-with-keycloak/
├── setup.sh                       ← end-to-end setup script (run this)
├── keycloak-local-ca.crt          ← CA cert copy written by setup.sh (for kubelogin)
├── keycloak-local-ca.crt.example  ← example placeholder
├── kubeconfig-oidc.yaml           ← generated kubeconfig written by setup.sh
├── kubeconfig-oidc.yaml.example   ← example placeholder
└── rbac/
    ├── devops-cluster-admin.yaml  ← ClusterRoleBinding: devops → cluster-admin
    ├── team-a.yaml                ← Namespace team-a + RoleBinding + ns-viewer ClusterRole
    └── team-b.yaml                ← Namespace team-b + RoleBinding + ns-viewer ClusterRole
```

---

## Prerequisites

| Requirement | What to check |
|-------------|---------------|
| Kind cluster running | `kubectl get nodes` |
| Keycloak running (`03-keycloak`) | `kubectl get pods -n keycloak` — must be Running |
| `kind` realm with users and groups | Helm import or `03-keycloak/create-realm.sh` |
| `pki/kind.localCA.crt` + `pki/kind.localCA.key` | Created in `02-vault` Step 4a |
| `pki/keycloak.kind.local.crt` + `pki/keycloak.kind.local.key` | Signed in `03-keycloak` TLS step |
| `kubelogin` plugin | `brew install int128/kubelogin/kubelogin` |

```bash
# Quick pre-flight checks (from project root)
kubectl get pods -n keycloak               # keycloak-* Running
ls pki/kind.localCA.crt                    # CA cert exists
ls pki/keycloak.kind.local.crt             # Keycloak TLS cert exists
kubectl oidc-login --version               # kubelogin installed
```

---

## Run setup.sh

```bash
cd 05-k8s-oidc-with-keycloak
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — every resource is checked before creation.
Safe to re-run after a cluster restart or configuration change.

### What each step does

| Step | Action |
|------|--------|
| **0** | Validates `kubectl`, `podman`, `python3`; confirms cluster is reachable |
| **1** | Uses `pki/keycloak.kind.local.{crt,key}` (or generates if missing); creates/updates `keycloak-local-tls` TLS secret in the `keycloak` namespace; patches the Keycloak nginx ingress to enable TLS; copies the CA cert to the control-plane PKI dir (`/etc/kubernetes/pki/kind.localCA.crt`) and saves a copy as `keycloak-local-ca.crt` in this folder |
| **2** | Adds `keycloak.kind.local → nginx ClusterIP` to the control-plane `/etc/hosts` so kube-apiserver can reach Keycloak; verifies that the OIDC discovery issuer matches `https://keycloak.kind.local/realms/kind` |
| **3** | Creates the `kubernetes` **public** OIDC client in the Keycloak `kind` realm (idempotent); adds two protocol mappers: **groups** (`full.path=false` → flat names e.g. `team-a`) and **audience** (`aud=kubernetes`, required by kube-apiserver 1.30+) |
| **4** | Reads the kube-apiserver static pod manifest from the control-plane container, appends the five OIDC flags, writes it back. kubelet detects the file change and restarts the API server automatically |
| **5** | Waits up to 120 s for the API server to come back healthy |
| **6** | Applies three RBAC manifests: `devops-cluster-admin.yaml`, `team-a.yaml`, `team-b.yaml` |
| **7** | Prints a verification summary: OIDC flags on kube-apiserver, namespace and RoleBinding status |

### kube-apiserver flags written by Step 4

```
--oidc-issuer-url=https://keycloak.kind.local/realms/kind
--oidc-client-id=kubernetes
--oidc-username-claim=preferred_username
--oidc-groups-claim=groups
--oidc-ca-file=/etc/kubernetes/pki/kind.localCA.crt
```

---

## User setup (after running setup.sh)

### 1. Add keycloak.kind.local to /etc/hosts

```bash
echo "127.0.0.1  keycloak.kind.local" | sudo tee -a /etc/hosts
```

> **macOS `.local` DNS issue:** macOS routes `.local` through mDNS before
> checking `/etc/hosts`, which can cause timeouts. Flush the DNS cache if needed:
> ```bash
> sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
> ```
> The generated `kubeconfig-oidc.yaml` already sets `GODEBUG=netdns=go` to force
> Go's resolver to read `/etc/hosts` directly — this covers kubectl/kubelogin.

### 2. Trust the CA certificate (one-time, may already be done)

The shared CA is at `pki/kind.localCA.crt` (project root). If you trusted it
during `02-vault` setup it is already in your system keychain.

```bash
# From project root — macOS system keychain (trusted by browser + CLI tools)
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  pki/kind.localCA.crt
```

Restart your browser after adding. Both `https://keycloak.kind.local` and
`https://vault.kind.local` will show a valid padlock.

### 3. Set up the OIDC kubeconfig

```bash
# From project root
export KUBECONFIG=~/.kube/config:$(pwd)/05-k8s-oidc-with-keycloak/kubeconfig-oidc.yaml

# Confirm the three contexts are visible
kubectl config get-contexts
```

Add the `export KUBECONFIG=...` line to `~/.zshrc` or `~/.bashrc` to make it
permanent.

### 4. Run kubectl — browser login opens automatically on first use

```bash
# team-a
kubectl config use-context team-a
kubectl get pods -n team-a          # ✓ allowed  (opens browser first time)
kubectl get pods -n team-b          # ✗ Forbidden
kubectl get nodes                   # ✗ Forbidden

# team-b
kubectl config use-context team-b
kubectl get pods -n team-b          # ✓ allowed
kubectl get pods -n team-a          # ✗ Forbidden

# devops (cluster-admin)
kubectl config use-context devops
kubectl get nodes                   # ✓ all nodes
kubectl get pods -A                 # ✓ all namespaces
kubectl create namespace foo        # ✓ full admin
```

### 5. Switch users — clear the token cache first

All three kubeconfig users share the same cache key (same issuer + client ID).
Without clearing the cache, the old user's token is reused and kubectl returns
`Forbidden`.

```bash
rm -rf ~/.kube/cache/oidc-login/
kubectl get pods -n team-a          # triggers fresh browser login
```

---

## Verify the setup

```bash
# OIDC flags present on kube-apiserver
podman exec vault-control-plane \
  grep oidc /etc/kubernetes/manifests/kube-apiserver.yaml

# keycloak.kind.local resolves from control-plane
podman exec vault-control-plane getent hosts keycloak.kind.local

# 'kubernetes' client exists in kind realm
kubectl exec -n keycloak \
  $(kubectl get pod -n keycloak -l app=keycloak \
    -o jsonpath='{.items[0].metadata.name}') -- \
  /opt/keycloak/bin/kcadm.sh get clients -r kind --fields clientId \
  | grep kubernetes

# RBAC resources in place
kubectl get clusterrolebinding keycloak-devops-cluster-admin
kubectl get rolebinding -n team-a keycloak-team-a-admin
kubectl get rolebinding -n team-b keycloak-team-b-admin

# Namespaces created
kubectl get ns team-a team-b
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `Unauthorized` / `You must be logged in` | Token `aud` or `iss` mismatch | Re-run `./setup.sh`; verify the audience mapper exists in Keycloak |
| Browser cert warning on `https://keycloak.kind.local` | CA not trusted | Run `security add-trusted-cert` in step 2; restart browser |
| `no such host: keycloak.kind.local` | macOS mDNS intercepting `.local` | Flush DNS cache. The kubeconfig sets `GODEBUG=netdns=go` for kubectl/kubelogin |
| `pods is forbidden ... namespace "team-b"` | Correct behaviour | team-a users intentionally have no access to team-b |
| `OIDC discovery issuer mismatch` in Step 2 | Keycloak ingress not using HTTPS | Confirm: `kubectl get secret keycloak-local-tls -n keycloak` |
| API server not restarting after Step 4 | kubelet needs time to detect the manifest change | Wait 60–120 s; check: `podman exec vault-control-plane crictl ps \| grep apiserver` |
| `kubelogin: command not found` | Plugin not installed | `brew install int128/kubelogin/kubelogin` |
| `Forbidden` after switching context | Stale cached token | `rm -rf ~/.kube/cache/oidc-login/` then re-run kubectl |

---

## Re-running after a cluster restart

The kube-apiserver manifest persists inside the kind container across restarts —
OIDC flags survive. However, the control-plane `/etc/hosts` entry added in
Step 2 **is lost** on every container restart.

Re-run the script to restore it (all other steps are skipped as idempotent):

```bash
cd 05-k8s-oidc-with-keycloak
./setup.sh
# Steps 1, 3, 4, 6 are skipped; Step 2 re-adds keycloak.kind.local to /etc/hosts
```
