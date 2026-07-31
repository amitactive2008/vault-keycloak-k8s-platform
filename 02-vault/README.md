# Vault HA Setup

Vault is deployed in HA mode (3-replica Raft cluster) inside the `vault` namespace.
Traffic is routed via the shared Envoy Gateway from `01-cloud-provider-kind-setup-with-gw-api`.
TLS is terminated at the gateway using the wildcard `*.kind.local` certificate — Vault itself
listens on plain HTTP internally (`global.tlsDisable: true`).

## Architecture

```
https://vault.kind.local
        │
        ▼
Envoy Gateway (native-gateway, default ns)
  HTTPS:443 → wildcard *.kind.local TLS termination
        │  HTTPRoute: vault (vault ns)
        ▼
vault-active service :8200  (always the Raft leader)
        │
        ├── vault-0  (active)
        ├── vault-1  (standby)
        └── vault-2  (standby)
```

## Files

| File | Purpose |
|------|---------|
| `vault.yaml` | Helm values — HA Raft, 3 replicas, injector, ingress disabled |
| `vault-httproute.yaml` | HTTPRoute for `vault.kind.local` + HTTP→HTTPS redirect |
| `cluster-keys.json` | Unseal keys and root token — **never commit, keep safe** |
| `cluster-keys.json.example` | Safe reference showing the expected JSON shape |

## Prerequisites

- Kind cluster running (`01-cloud-provider-kind-setup-with-gw-api` completed)
- Envoy Gateway installed with `native-gateway` programmed
- Wildcard cert `*.kind.local` loaded as `wildcard-kind-local-tls` in `default` namespace

## Step 1 — Add DNS entry

```bash
echo "127.0.0.1 vault.kind.local" | sudo tee -a /etc/hosts
```

## Step 2 — Install Vault

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

helm upgrade --install vault hashicorp/vault \
  --values vault.yaml \
  --namespace vault --create-namespace
```

Watch pods start (they will be `0/1` until unsealed):

```bash
kubectl get pods -n vault -w
```

The liveness probe deliberately accepts Vault's sealed and uninitialized
states. Those states make the pod NotReady, but must not restart the Vault
process while an operator is applying unseal keys. It also tolerates one minute
of transient probe failures so CPU pressure from local builds does not restart
and reseal every HA member.

## Step 3 — Apply the HTTPRoute

```bash
kubectl apply -f vault-httproute.yaml
```

Verify the route is accepted:

```bash
kubectl get httproute -n vault
# NAME                  HOSTNAMES
# vault                 ["vault.kind.local"]
# vault-http-redirect   ["vault.kind.local"]
```

## Step 4 — Initialize Vault

Run **once** on a fresh cluster. Outputs 5 unseal keys (threshold: 3) and a root token.

```bash
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 \
  -key-threshold=3 \
  -format=json > cluster-keys.json
```

> **Keep `cluster-keys.json` safe.** The repository `.gitignore` already
> excludes this file. Never commit, paste, or share its contents.
> Anyone with the unseal keys and root token has full access to Vault.

## Step 5 — Unseal all pods

Each pod must be unsealed independently. Apply 3 of the 5 keys to each pod.

```bash
K0=$(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
K1=$(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
K2=$(jq -r '.unseal_keys_b64[2]' cluster-keys.json)

for pod in vault-0 vault-1 vault-2; do
  echo "=== Unsealing $pod ==="
  kubectl exec -n vault "$pod" -- vault operator unseal "$K0"
  kubectl exec -n vault "$pod" -- vault operator unseal "$K1"
  kubectl exec -n vault "$pod" -- vault operator unseal "$K2"
done
```

Verify all pods are unsealed and the cluster formed:

```bash
for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ==="
  kubectl exec -n vault $pod -- vault status | grep -E "Sealed|HA Mode|Active Node"
done
# vault-0: Sealed false, HA Mode active
# vault-1: Sealed false, HA Mode standby
# vault-2: Sealed false, HA Mode standby
```

## Step 6 — Verify access

```bash
# Health check via HTTPS (CA is trusted in macOS System Keychain after Step 1 setup)
curl https://vault.kind.local/v1/sys/health

# HTTP -> HTTPS redirect
curl -v http://vault.kind.local/ 2>&1 | grep -E "HTTP|Location"
# < HTTP/1.1 301 Moved Permanently
```

Open the UI in your browser: **https://vault.kind.local/ui/**

Login with the root token:

```bash
jq -r '.root_token' cluster-keys.json
```

## Step 7 — Optional: CLI access

```bash
export VAULT_ADDR=https://vault.kind.local
export VAULT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
vault status
```

Or port-forward if you prefer direct access:

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# Open: http://localhost:8200/ui/
```

---

## Unseal after cluster restart

Vault pods start **sealed** after every restart. Unseal them again with:

```bash
K0=$(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
K1=$(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
K2=$(jq -r '.unseal_keys_b64[2]' cluster-keys.json)

for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault "$pod" -- vault operator unseal "$K0"
  kubectl exec -n vault "$pod" -- vault operator unseal "$K1"
  kubectl exec -n vault "$pod" -- vault operator unseal "$K2"
done
```

---

## Upgrading Vault

### 1. Check latest chart and app versions

```bash
helm repo update
helm show chart hashicorp/vault | grep -E "^version|appVersion"
```

Update image tags in `vault.yaml`:

```yaml
server:
  image:
    tag: "<new-vault-version>"

injector:
  image:
    tag: "<new-vault-k8s-version>"
  agentImage:
    tag: "<new-vault-version>"
```

### 2. Run helm upgrade

```bash
helm upgrade vault hashicorp/vault \
  --namespace vault \
  --values vault.yaml \
  --force-conflicts
```

> `--force-conflicts` is required because the Vault injector manages the `caBundle` field
> in the `MutatingWebhookConfiguration` outside of Helm.

### 3. Unseal pods as they roll

The StatefulSet rolls `vault-2` → `vault-1` → `vault-0`. Each restarted pod starts sealed
and the rollout pauses until it becomes Ready. Unseal each pod to unblock the next.

```bash
for i in 2 1 0; do
  echo "--- Waiting for vault-$i to restart ---"
  until kubectl exec -n vault "vault-$i" -- vault status 2>/dev/null | grep -q "Sealed.*true"; do
    sleep 3
  done
  kubectl exec -n vault "vault-$i" -- vault operator unseal \
    "$(jq -r '.unseal_keys_b64[0]' cluster-keys.json)"
  kubectl exec -n vault "vault-$i" -- vault operator unseal \
    "$(jq -r '.unseal_keys_b64[1]' cluster-keys.json)"
  kubectl exec -n vault "vault-$i" -- vault operator unseal \
    "$(jq -r '.unseal_keys_b64[2]' cluster-keys.json)"
  echo "vault-$i unsealed"
done
```

---

## Useful commands

```bash
# Cluster health
kubectl get pods -n vault

# Vault status on each pod
for pod in vault-0 vault-1 vault-2; do
  echo "=== $pod ===" && kubectl exec -n vault $pod -- vault status
done

# Helm release history
helm history vault -n vault

# Rollback
helm rollback vault -n vault

# Vault logs
kubectl logs -n vault vault-0 --tail=50

# HTTPRoutes
kubectl get httproute -n vault
```

---

## Troubleshooting

**Pods remain `0/1 Running` after install**

Expected — pods are sealed until you run `vault operator init` and `vault operator unseal`.
Check pod logs: `kubectl logs -n vault vault-0`

If sealed pods show `CrashLoopBackOff`, verify that the installed liveness path
contains `sealedcode=204&uninitcode=204`, then reconcile the Helm release. A
liveness probe that uses the default sealed response code kills the process
before it can reliably be unsealed.

**`https://vault.kind.local` returns 404 or connection refused**

Check the HTTPRoute is accepted and the gateway is programmed:

```bash
kubectl get httproute -n vault
kubectl get gateway native-gateway -n default
```

**Vault re-seals after `kind` cluster restart**

Vault pods always start sealed. Re-run the unseal loop in Step 5 / "Unseal after cluster restart".

**`cluster-keys.json` lost**

There is no recovery path — the encrypted data in the PVCs cannot be decrypted without the
unseal keys. Treat the keys file the same as a private key.
