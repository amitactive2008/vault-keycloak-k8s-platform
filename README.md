# Vault + Keycloak on Kubernetes (kind)

> **DEMO / STUDY USE ONLY**
> This repository is designed for **local learning on a kind cluster** (localhost only).
> It contains intentionally simple, hardcoded credentials to make setup frictionless.
> **Do not use any credential, configuration, or pattern from this repo in a production environment.**
> See the [Security Notice](#security-notice) section below.

A complete local platform running on a [kind](https://kind.sigs.k8s.io/) cluster:

| Component | Stack |
|-----------|-------|
| **Cluster** | kind — 1 control-plane + 3 workers, K8s v1.35 |
| **Ingress / TLS** | Envoy Gateway v1.4.0 + cloud-provider-kind — wildcard `*.kind.local` HTTPS |
| **Certificate management** | cert-manager — automated CA bootstrap + wildcard cert issuance and renewal |
| **Secrets management** | HashiCorp Vault 2.x — HA/Raft, 3 replicas |
| **Identity / SSO** | Keycloak 26.3.3 — PostgreSQL backend |
| **Vault OIDC auth** | Vault OIDC → Keycloak `kind` realm |
| **kubectl SSO** | kube-apiserver OIDC → Keycloak; per-team RBAC |
| **Sample app** | 2-tier webapp with Vault Agent secret injection |

---

## Architecture

```
/etc/hosts
127.0.0.1  vault.kind.local
127.0.0.1  keycloak.kind.local
127.0.0.1  team-a-webapp.kind.local
      │
      ▼
kindccm Envoy container  (0.0.0.0:80, 0.0.0.0:443)
  managed by cloud-provider-kind
      │
      ▼
Envoy Gateway (native-gateway)
  HTTPS:443 — wildcard *.kind.local TLS termination
  HTTP:80   — 301 redirect to HTTPS
      │
      ├──── vault.kind.local ──────────────► NS: vault
      │                                       Vault ×3 (HA/Raft)
      │
      ├──── keycloak.kind.local ──────────► NS: keycloak
      │                                       Keycloak 26 + PostgreSQL
      │
      └──── team-a-webapp.kind.local ─────► NS: team-a
                                             webapp-frontend (nginx)
                                             webapp-backend (Python)
                                             PostgreSQL
                                             vault-agent sidecar ──► Vault
                                                                     (K8s auth)
```

```
kube-apiserver ──── OIDC ────► Keycloak
                               (HTTPS, in-cluster via CoreDNS → Envoy GW)
```

### Hostnames

| Hostname | Service | Protocol |
|----------|---------|----------|
| `vault.kind.local` | Vault UI + API | HTTPS |
| `keycloak.kind.local` | Keycloak Admin + OIDC | HTTPS |
| `team-a-webapp.kind.local` | Sample 2-tier webapp | HTTPS |

---

## Prerequisites

| Tool | Min version | Install |
|------|-------------|---------|
| `kind` | v0.24+ | `brew install kind` |
| `kubectl` | v1.29+ | `brew install kubectl` |
| `helm` | v3+ | `brew install helm` |
| `podman` | any | `brew install podman` (rootful mode required) |
| `jq` | any | `brew install jq` |
| `cloud-provider-kind` | any | `brew install cloud-provider-kind` |
| `kubelogin` | any | `brew install int128/kubelogin/kubelogin` (Step 5 only) |

---

## Repository Structure

```
vault-keycloak-k8s-platform/
│
├── 01-cloud-provider-kind-setup-with-gw-api/   ← kind cluster + Envoy Gateway + wildcard TLS
│   ├── kind.yaml                                ← cluster definition (no extraPortMappings)
│   ├── gateway-infra.yaml                       ← GatewayClass, Gateway, HTTPRoutes
│   └── cert-manager.yaml                        ← ClusterIssuers + Certificates (CA + wildcard)
│
├── 02-vault/                                    ← Vault Helm install + init + unseal
│   ├── README.md
│   ├── vault.yaml                               ← Vault Helm values (HA/Raft, ingress disabled)
│   ├── vault-httproute.yaml                     ← HTTPRoute for vault.kind.local
│   └── cluster-keys.json                        ← DO NOT COMMIT — unseal keys + root token
│
├── 03-keycloak/                                 ← Keycloak Helm chart + realm import
│   ├── README.md
│   ├── values.yaml                              ← user-facing overrides (ingress disabled)
│   ├── keycloak-httproute.yaml                  ← HTTPRoute for keycloak.kind.local
│   ├── kind-realm.json                          ← realm definition (groups + users)
│   ├── create-realm.sh                          ← kcadm-based realm creation (idempotent)
│   └── keycloak-chart/                          ← local Helm chart
│
├── 04-vault-keycloak-integration/               ← Vault OIDC → Keycloak wiring
│   ├── README.md
│   ├── setup.sh                                 ← idempotent integration script
│   └── policies/
│       ├── devops.hcl
│       ├── team-a.hcl
│       └── team-b.hcl
│
├── 05-k8s-oidc-with-keycloak/                  ← kubectl SSO via Keycloak (optional)
│   ├── README.md
│   ├── setup.sh
│   ├── kubeconfig-oidc.yaml                     ← generated kubeconfig (by setup.sh)
│   └── rbac/
│       ├── devops-cluster-admin.yaml
│       ├── team-a.yaml
│       └── team-b.yaml
│
└── 06-application/
    └── team-a-webapp/                           ← 2-tier demo app with Vault Agent injection
        ├── README.md
        ├── values.yaml
        ├── vault-setup.sh                       ← configure Vault for the app (run once)
        └── webapp-chart/                        ← local Helm chart
```

---

## Setup Order

### Step 1 — Create the kind cluster + Envoy Gateway

```bash
cd 01-cloud-provider-kind-setup-with-gw-api

# Create cluster (no extraPortMappings — cloud-provider-kind owns port binding)
kind create cluster --config kind.yaml
kind export kubeconfig --name vault

# Start cloud-provider-kind in a DEDICATED terminal — keep it running
sudo cloud-provider-kind --gateway-channel standard --enable-lb-port-mapping

# Install Envoy Gateway (CRDs already provided by cloud-provider-kind)
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.4.0 \
  -n envoy-gateway-system --create-namespace --skip-crds

kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system
```

#### Install cert-manager + issue wildcard TLS certificate

cert-manager automates CA bootstrap and wildcard cert issuance/renewal — no `openssl` commands needed.

```bash
# Install cert-manager
helm repo add jetstack https://charts.jetstack.io && helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager

# Apply cert-manager resources: ClusterIssuers + CA Certificate + Wildcard Certificate
kubectl apply -f cert-manager.yaml

# Wait for certificates to be issued
kubectl wait --for=condition=Ready certificate/kind-local-ca -n cert-manager --timeout=60s
kubectl wait --for=condition=Ready certificate/wildcard-kind-local-tls -n default --timeout=60s

# Trust the CA on macOS (covers all *.kind.local services)
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/kind-local-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/kind-local-ca.crt
rm /tmp/kind-local-ca.crt
```

#### Deploy gateway + test app

```bash
kubectl apply -f gateway-infra.yaml
kubectl apply -f app-deployment.yaml

# Verify
kubectl get gateway native-gateway   # PROGRAMMED: True
curl https://sample.kind.local/
```

---

### Step 2 — Install Vault

```bash
cd 02-vault

# Add DNS entry
echo "127.0.0.1 vault.kind.local" | sudo tee -a /etc/hosts

helm repo add hashicorp https://helm.releases.hashicorp.com && helm repo update
helm install vault hashicorp/vault \
  --values vault.yaml \
  --namespace vault --create-namespace

# Apply HTTPRoute
kubectl apply -f vault-httproute.yaml

# Initialize and unseal (run once)
kubectl exec -n vault vault-0 -- vault operator init \
  -key-shares=5 -key-threshold=3 -format=json > cluster-keys.json
echo "cluster-keys.json" >> ../.gitignore

K0=$(jq -r '.unseal_keys_b64[0]' cluster-keys.json)
K1=$(jq -r '.unseal_keys_b64[1]' cluster-keys.json)
K2=$(jq -r '.unseal_keys_b64[2]' cluster-keys.json)
for pod in vault-0 vault-1 vault-2; do
  kubectl exec -n vault $pod -- vault operator unseal "$K0"
  kubectl exec -n vault $pod -- vault operator unseal "$K1"
  kubectl exec -n vault $pod -- vault operator unseal "$K2"
done

# Verify
curl https://vault.kind.local/v1/sys/health
```

---

### Step 3 — Install Keycloak

```bash
cd 03-keycloak

# Add DNS entry
echo "127.0.0.1 keycloak.kind.local" | sudo tee -a /etc/hosts

helm install keycloak ./keycloak-chart \
  -f ./values.yaml \
  --namespace keycloak --create-namespace

kubectl rollout status deployment/keycloak -n keycloak --timeout=360s

# Apply HTTPRoute
kubectl apply -f keycloak-httproute.yaml

# Verify OIDC discovery
curl -s https://keycloak.kind.local/realms/kind/.well-known/openid-configuration \
  | python3 -m json.tool | grep issuer
# "issuer": "https://keycloak.kind.local/realms/kind"
```

---

### Step 4 — Connect Vault ↔ Keycloak (OIDC)

```bash
cd 04-vault-keycloak-integration
chmod +x setup.sh && ./setup.sh
```

---

### Step 5 — kubectl SSO via Keycloak (optional)

Enables `kubectl` login with Keycloak credentials. Requires `kubelogin`.

```bash
cd 05-k8s-oidc-with-keycloak
chmod +x setup.sh && ./setup.sh

export KUBECONFIG=~/.kube/config:$(pwd)/kubeconfig-oidc.yaml
kubectl config use-context team-a
kubectl get pods -n team-a   # opens browser → Keycloak login
```

---

### Step 6 — Deploy the sample webapp (optional)

2-tier app in the `team-a` namespace with Vault Agent secret injection.

```bash
cd 06-application/team-a-webapp

echo "127.0.0.1 team-a-webapp.kind.local" | sudo tee -a /etc/hosts

chmod +x vault-setup.sh && ./vault-setup.sh

helm install team-a-webapp ./webapp-chart \
  -f ./values.yaml \
  --namespace team-a --create-namespace

# Open: https://team-a-webapp.kind.local
```

---

## Access URLs

| Service | URL | Credentials |
|---------|-----|-------------|
| Vault UI | https://vault.kind.local/ui | Root token from `02-vault/cluster-keys.json` |
| Vault OIDC login | https://vault.kind.local/ui → OIDC → role `default` | Keycloak users (password: `password`) |
| Keycloak Admin | https://keycloak.kind.local/admin | `admin` / `Admin@Keycloak2024!` |
| Team-A webapp | https://team-a-webapp.kind.local | — |

---

## Vault OIDC Access Matrix

| Keycloak group | Vault policy | Allowed paths |
|----------------|-------------|---------------|
| `devops` | `devops-policy` | `*` (full admin) |
| `team-a` | `team-a-policy` | `secret/data/team-a/*` only |
| `team-b` | `team-b-policy` | `secret/data/team-b/*` only |

---

## kubectl OIDC Access Matrix

| Keycloak group | Kubernetes RBAC | Scope |
|----------------|-----------------|-------|
| `devops` | `cluster-admin` | All namespaces |
| `team-a` | `admin` | `team-a` namespace only |
| `team-b` | `admin` | `team-b` namespace only |

---

## Teardown

```bash
kind delete cluster --name vault
# Ctrl+C in the terminal where cloud-provider-kind is running
```

---

## Security Notice

This project is a **local demo**. The following are intentional trade-offs for simplicity:

| Item | Value in this repo | Production alternative |
|------|-------------------|----------------------|
| Vault root token | `02-vault/cluster-keys.json` (gitignored) | Vault auto-unseal (AWS KMS, GCP KMS, etc.) |
| Keycloak admin password | `Admin@Keycloak2024!` | Random secret via secrets manager |
| Keycloak DB password | `Keycloak@2024!` | Vault database secrets engine |
| OIDC client secret | `Vault@Keycloak2024!` | Randomly generated, rotated |
| Demo user password | `password` | Enforced password policy |
| Webapp DB password | `S3cur3P@ssw0rd` | Vault database secrets engine |
| TLS | cert-manager + local self-signed CA (auto-renewed) | cert-manager + Let's Encrypt / ACME |
| Vault in-cluster TLS | Disabled (`tlsDisable: true`) | TLS everywhere, even in-cluster |
| CA private key | Stored in K8s secret `cert-manager/kind-local-ca-secret` | HSM / managed CA |

> Verify `02-vault/cluster-keys.json` is not tracked before pushing:
> ```bash
> git check-ignore -v 02-vault/cluster-keys.json
> ```
