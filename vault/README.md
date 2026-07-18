# HashiCorp Vault on Kubernetes (kind cluster)

Deploy a production-style Vault HA cluster with Raft storage behind an nginx
ingress on a local [kind](https://kind.sigs.k8s.io/) cluster.

---

## Prerequisites

| Tool | Version used | Install |
|------|-------------|---------|
| Podman | any recent | `brew install podman` (kind uses Podman on macOS) |
| kind | ≥ 0.24 | `brew install kind` |
| kubectl | ≥ 1.29 | `brew install kubectl` |
| Helm | ≥ 4.x | `brew install helm` |
| jq | any | `brew install jq` |

> Docker also works in place of Podman. kind will use whichever is available.

---

## Cluster layout

| Node | Role |
|------|------|
| `vault-control-plane` | Control-plane — hosts ingress-nginx (ports 80/443 mapped to host) |
| `vault-worker` | Worker |
| `vault-worker2` | Worker |
| `vault-worker3` | Worker |

```
kind.yaml       — kind cluster definition (1 control-plane + 3 workers, K8s v1.35)
vault.yaml      — Vault Helm values (HA/Raft, 3 replicas, ingress enabled)
deploy-ingress-nginx.yaml  — ingress-nginx v1.15.1 (kind-specific manifest)
cluster-keys.json          — generated after vault init (DO NOT COMMIT)
```

---

## Step 1 — Create the kind cluster

```bash
kind create cluster --config kind.yaml
```

Verify nodes are ready:

```bash
kubectl get nodes
```

Expected output — 1 control-plane + 3 workers, all `Ready`.

---

## Step 2 — Install ingress-nginx

> ⚠️ **ingress-nginx is retired (archived March 2026).** Version `v1.15.1` is the
> final release — no further security patches will be issued. For production
> workloads, migrate to [NGINX Gateway Fabric](https://github.com/nginx/nginx-gateway-fabric),
> [Traefik](https://traefik.io/), or the Kubernetes [Gateway API](https://gateway-api.sigs.k8s.io/).
> This local kind cluster uses it as a known-good, stable ingress for study/demo purposes.

```bash
kubectl apply -f deploy-ingress-nginx.yaml
```

Wait for the controller to be ready:

```bash
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s
```

> **Why a kind-specific manifest?** The controller must run on the control-plane
> node (the only node with `extraPortMappings` for ports 80/443) and needs
> `hostPort` bindings plus `--publish-status-address=localhost`.

---

## Step 3 — Install Vault

### Add the HashiCorp Helm repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### Create the namespace

```bash
kubectl create namespace vault
```

### Install

```bash
helm install vault hashicorp/vault \
  --namespace vault \
  --values vault.yaml
```

### Add a local DNS entry (one-time)

```bash
echo "127.0.0.1 vault-webui.local" | sudo tee -a /etc/hosts
```

---

## Step 4 — Create the HTTPS TLS secret

The Vault ingress references a TLS secret named `vault-webui-local-tls` in the
`vault` namespace. **Without it `https://vault-webui.local` will not work** —
ingress-nginx falls back to its default self-signed cert and browsers show an
untrusted-certificate error.

### Option A — Shared CA (recommended if `keycloak/k8s-oidc/setup.sh` has already been run)

The keycloak setup writes a CA key to `/private/tmp/keycloak-local-ca.key`.
Reusing the same CA means you only need to trust one root certificate in your
browser/OS (covers both `vault-webui.local` and `keycloak.local`).

```bash
# Generate server key + cert for vault-webui.local signed by the shared CA
openssl genrsa -out /tmp/vault-webui-local.key 4096 2>/dev/null

openssl req -new -key /tmp/vault-webui-local.key \
  -out /tmp/vault-webui-local.csr \
  -subj "/C=US/O=kind-vault/CN=vault-webui.local"

openssl x509 -req \
  -in /tmp/vault-webui-local.csr \
  -CA /private/tmp/keycloak-local-ca.crt \
  -CAkey /private/tmp/keycloak-local-ca.key \
  -CAcreateserial \
  -out /tmp/vault-webui-local.crt \
  -days 3650 -sha256 \
  -extfile <(printf "subjectAltName=DNS:vault-webui.local\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth")

kubectl create secret tls vault-webui-local-tls \
  --cert=/tmp/vault-webui-local.crt \
  --key=/tmp/vault-webui-local.key \
  -n vault
```

Trust the shared CA (one-time, covers both Vault and Keycloak):

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ../keycloak/k8s-oidc/keycloak-local-ca.crt
```

### Option B — Standalone self-signed cert (Keycloak not yet set up)

```bash
openssl req -x509 -newkey rsa:4096 -nodes \
  -keyout /tmp/vault-webui-local.key \
  -out /tmp/vault-webui-local.crt \
  -days 3650 -sha256 \
  -subj "/C=US/O=kind-vault/CN=vault-webui.local" \
  -addext "subjectAltName=DNS:vault-webui.local"

kubectl create secret tls vault-webui-local-tls \
  --cert=/tmp/vault-webui-local.crt \
  --key=/tmp/vault-webui-local.key \
  -n vault
```

Trust the standalone cert directly (macOS):

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  /tmp/vault-webui-local.crt
```

Verify the secret exists:

```bash
kubectl get secret vault-webui-local-tls -n vault
```

---

## Step 5 — Initialize Vault

Run this **once** on a fresh cluster. It outputs 5 unseal keys and a root token.

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > cluster-keys.json
```

> ⚠️ **Keep `cluster-keys.json` safe.** Add it to `.gitignore` immediately.
> Anyone with the unseal keys and root token has full access to Vault.

```bash
echo "cluster-keys.json" >> .gitignore
```

---

## Step 6 — Unseal all pods

Vault requires **3 of the 5 keys** to unseal. Each pod must be unsealed
independently after every restart.

```bash
# Unseal vault-0
kubectl exec -n vault vault-0 -- vault operator unseal $(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
kubectl exec -n vault vault-0 -- vault operator unseal $(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
kubectl exec -n vault vault-0 -- vault operator unseal $(jq -r '.unseal_keys_b64[2]' cluster-keys.json)

# Unseal vault-1
kubectl exec -n vault vault-1 -- vault operator unseal $(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
kubectl exec -n vault vault-1 -- vault operator unseal $(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
kubectl exec -n vault vault-1 -- vault operator unseal $(jq -r '.unseal_keys_b64[2]' cluster-keys.json)

# Unseal vault-2
kubectl exec -n vault vault-2 -- vault operator unseal $(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
kubectl exec -n vault vault-2 -- vault operator unseal $(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
kubectl exec -n vault vault-2 -- vault operator unseal $(jq -r '.unseal_keys_b64[2]' cluster-keys.json)
```

Verify all pods are unsealed:

```bash
for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ==="
  kubectl exec -n vault $pod -- vault status | grep -E "Sealed|HA Mode|Version"
done
```

Expected: `Sealed: false` on all three pods, one `active` and two `standby`.

---

## Step 7 — Access the UI

Vault is accessible over both HTTP and HTTPS:

| Protocol | URL |
|----------|-----|
| HTTP     | http://vault-webui.local/ui/ |
| HTTPS    | https://vault-webui.local/ui/ |

Login with the root token:

```bash
jq -r '.root_token' cluster-keys.json
```

HTTPS uses a self-signed certificate signed by `keycloak/k8s-oidc/keycloak-local-ca.crt`
(the same CA as Keycloak). Trust it once to avoid browser warnings:

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  ../keycloak/k8s-oidc/keycloak-local-ca.crt
```

> **Browser HSTS:** If the browser previously cached an HSTS policy for
> `vault-webui.local` and is forcing `https://`, that is now correct behaviour
> — the HTTPS endpoint is available. If you need to reset a stale cached policy
> from before HTTPS was set up:
> - **Chrome/Edge**: `chrome://net-internals/#hsts` → delete `vault-webui.local`
> - **Firefox**: History → “Forget About This Site” for `vault-webui.local`

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# Open: http://localhost:8200/ui/
```

---

## Keycloak OIDC Integration

After Vault is running, connect it to Keycloak for SSO login.
See [../keycloak/README.md](../keycloak/README.md) for the full Keycloak setup,
then run the integration script:

```bash
cd ../keycloak/vault-integration/
chmod +x setup.sh
./setup.sh
```

What the script configures:

| Item | Detail |
|------|--------|
| CoreDNS | Adds `keycloak.local` → Keycloak ClusterIP so Vault pods can reach Keycloak |
| Keycloak client | Confidential OIDC client `vault` in the `kind` realm |
| KV v2 engine | Mounts `secret/` |
| Vault OIDC auth | Discovery URL: `http://keycloak.local/realms/kind` (Vault uses HTTP internally via CoreDNS) |
| Policies | `devops-policy` (all paths), `team-a-policy`, `team-b-policy` |
| External groups | Maps Keycloak groups `/devops`, `/team-a`, `/team-b` to policies |

After setup, users can log in to Vault via OIDC:

```bash
# Browser (both work):
#   http://vault-webui.local  → OIDC → role: default
#   https://vault-webui.local → OIDC → role: default

# CLI:
vault login -method=oidc -address=http://vault-webui.local role=default
# or:
vault login -method=oidc -address=https://vault-webui.local role=default
```

---

## Upgrading Vault

### 1. Update image tags in `vault.yaml`

Check the latest chart version and its bundled app version:

```bash
helm repo update
helm show chart hashicorp/vault | grep -E "^version|appVersion"
```

Update the tags in `vault.yaml` to match:

```yaml
server:
  image:
    tag: "<new-vault-version>"   # e.g. 2.0.3

injector:
  image:
    tag: "<new-vault-k8s-version>"   # e.g. 1.7.5
  agentImage:
    tag: "<new-vault-version>"

csi:
  image:
    tag: "<new-csi-provider-version>"   # e.g. 1.7.3
  agent:
    image:
      tag: "<new-vault-version>"
```

Or get all defaults at once:

```bash
helm show values hashicorp/vault | grep -A2 -E "^  image:|^  agentImage:" | grep -E "repository|tag"
```

### 2. Run `helm upgrade`

```bash
helm upgrade vault hashicorp/vault \
  --namespace vault \
  --values vault.yaml \
  --force-conflicts
```

> `--force-conflicts` is required because the Vault injector controller manages
> the `caBundle` field in the `MutatingWebhookConfiguration` outside of Helm,
> causing a server-side apply conflict on every upgrade.

### 3. Unseal pods as they roll

The StatefulSet rolls pods **one at a time** from highest to lowest ordinal
(`vault-2` → `vault-1` → `vault-0`). Each restarted pod starts **sealed** and
the rollout pauses until it becomes `Ready`. You must unseal each pod to
unblock the next.

Watch and unseal in one shot:

```bash
for i in 2 1 0; do
  echo "--- Waiting for vault-$i to restart ---"
  # Wait until pod is running but sealed
  until kubectl exec -n vault vault-$i -- vault status 2>/dev/null | grep -q "Sealed.*true"; do
    sleep 3
  done
  kubectl exec -n vault vault-$i -- vault operator unseal $(jq -r '.unseal_keys_b64[0]' cluster-keys.json) > /dev/null
  kubectl exec -n vault vault-$i -- vault operator unseal $(jq -r '.unseal_keys_b64[1]' cluster-keys.json) > /dev/null
  kubectl exec -n vault vault-$i -- vault operator unseal $(jq -r '.unseal_keys_b64[2]' cluster-keys.json) > /dev/null
  echo "vault-$i unsealed ✓"
done
```

### 4. Verify the upgrade

```bash
kubectl get pods -n vault
for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $pod -- vault version
done
```

---

## Upgrade tips

| Tip | Why |
|-----|-----|
| Always run `helm repo update` before upgrading | Ensures you have the latest chart metadata and correct `appVersion` |
| Use `--force-conflicts` on every `helm upgrade` | The Vault injector manages `caBundle` outside Helm — conflict will happen without this flag |
| Keep a terminal open watching `kubectl get pods -n vault -w` | You can see exactly when each pod restarts and needs unsealing |
| Unseal pods in order: `vault-2` → `vault-1` → `vault-0` | StatefulSet rolls in reverse ordinal order; unsealing out of order will stall the rollout |
| Never lose `cluster-keys.json` | There is no recovery path without the unseal keys — the data is permanently inaccessible |
| Consider auto-unseal for production | Use AWS KMS / GCP KMS / Azure Key Vault to unseal automatically on restart — eliminates the manual unseal step entirely |
| Backup PVCs before major version upgrades | `kubectl get pvc -n vault` shows the data and audit volumes — snapshot them before upgrading across major Vault versions |

---

## Useful commands

```bash
# Check cluster health
kubectl get pods -n vault
kubectl get pods -n ingress-nginx

# Check vault status
kubectl exec -n vault vault-0 -- vault status

# View Helm release history
helm history vault -n vault

# Rollback to previous release
helm rollback vault -n vault

# View ingress controller logs
kubectl logs -n ingress-nginx deployment/ingress-nginx-controller --tail=50

# View vault logs
kubectl logs -n vault vault-0 --tail=50

# Login to vault CLI from outside the cluster
export VAULT_ADDR=http://vault-webui.local     # HTTP
# or:
export VAULT_ADDR=https://vault-webui.local    # HTTPS (trust CA first, see Step 6)
export VAULT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
vault status
```

---

## Teardown

```bash
kind delete cluster --name vault
```

This removes the entire cluster. PVC data is not persisted outside kind.
