
## Step 3 — Install Vault

### Add the HashiCorp Helm repo

```bash
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
```

### Install

```bash
helm install vault hashicorp/vault \
  --values vault.yaml \
  --namespace vault --create-namespace
```

### Add a local DNS entry (one-time)

```bash
echo "127.0.0.1 vault.kind.local" | sudo tee -a /etc/hosts
```

---

## Step 4 — Create the shared local CA and Vault TLS secret

All PKI files live in a `pki/` folder at the project root so every setup
script can reference them from a single place. Run **all commands in this step
from the project root** (the folder that contains `02-vault/`, `keycloak/`, etc.).

> `pki/kind.localCA.key` is sensitive — never commit it.  
> Add `pki/*.key` and `pki/*.csr` to `.gitignore`.

```bash
echo 'pki/*.key\npki/*.csr\npki/*.srl' >> .gitignore
mkdir -p pki
```

### 4a — Create the CA config file and generate the shared CA

```bash
# Create the CA config file
cat > pki/ca.ini << 'EOF'
[req]
distinguished_name = dn
x509_extensions    = v3_ca
prompt             = no

[dn]
C  = US
O  = kind-vault
CN = kind-vault-local-ca

[v3_ca]
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints       = critical, CA:true
keyUsage               = critical, digitalSignature, cRLSign, keyCertSign
EOF

# CA private key
openssl genrsa -out pki/kind.localCA.key 4096 2>/dev/null

# Self-signed CA certificate (10-year validity)
openssl req -x509 -new -nodes \
  -key pki/kind.localCA.key \
  -days 3650 \
  -out pki/kind.localCA.crt \
  -config pki/ca.ini
```

Trust the CA once in macOS (covers **all** certs signed by it — Vault and Keycloak):

```bash
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain \
  pki/kind.localCA.crt
```

### 4b — Create the Vault server cert config, sign the CSR

```bash
# Create the server-cert config (SAN required by modern browsers)
cat > pki/vault.ini << 'EOF'
[req]
distinguished_name = dn
req_extensions     = v3_req
prompt             = no

[dn]
C  = US
O  = kind-vault
CN = vault.kind.local

[v3_req]
subjectAltName   = DNS:vault.kind.local
keyUsage         = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
EOF

# Generate server key and CSR
openssl genrsa -out pki/vault-webui.kind.local.key 4096 2>/dev/null
openssl req -new \
  -key pki/vault-webui.kind.local.key \
  -out pki/vault-webui.kind.local.csr \
  -config pki/vault.ini

# Sign the CSR with the shared CA
openssl x509 -req \
  -in pki/vault-webui.kind.local.csr \
  -CA pki/kind.localCA.crt \
  -CAkey pki/kind.localCA.key \
  -CAcreateserial \
  -out pki/vault-webui.kind.local.crt \
  -days 3650 -sha256 \
  -extfile <(printf 'subjectAltName=DNS:vault.kind.local\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth')

# Verify the cert chains back to our CA
openssl verify -CAfile pki/kind.localCA.crt pki/vault-webui.kind.local.crt
```

### 4c — Create the Kubernetes TLS secret

```bash
kubectl create secret tls vault-webui-local-tls \
  --cert=pki/vault-webui.kind.local.crt \
  --key=pki/vault-webui.kind.local.key \
  -n vault

# Confirm
kubectl get secret vault-webui-local-tls -n vault
```

> **Keycloak:** When you run `keycloak/k8s-oidc/setup.sh` later it will look
> for the shared CA at `pki/kind.localCA.{crt,key}` (project root) and use it
> to sign `keycloak.local` — no extra trust step needed.

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
| HTTP     | http://vault.kind.local/ui/ |
| HTTPS    | https://vault.kind.local/ui/ |

Login with the root token:

```bash
jq -r '.root_token' cluster-keys.json
```
## Step 8 — Optional. If you want to Access the UI by forwading port

```bash
kubectl port-forward -n vault svc/vault 8200:8200
# Open: http://localhost:8200/ui/
```


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
export VAULT_ADDR=http://vault.kind.local      # HTTP
# or:
export VAULT_ADDR=https://vault.kind.local     # HTTPS (CA trusted in Step 4a)
export VAULT_TOKEN=$(jq -r '.root_token' cluster-keys.json)
vault status
```


