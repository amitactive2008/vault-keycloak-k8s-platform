# Vault + Keycloak on Kubernetes (kind)

> **⚠️ DEMO / STUDY USE ONLY**
> This repository is designed for **local learning on a kind cluster** (localhost only).
> It contains intentionally simple, hardcoded credentials to make setup frictionless.
> **Do not use any credential, configuration, or pattern from this repo in a production environment.**
> See the [Security Notice](#security-notice) section below for the full list.

A complete, production-style local platform running on a [kind](https://kind.sigs.k8s.io/) cluster:

| Component | Stack |
|-----------|-------|
| **Secrets management** | HashiCorp Vault 2.0.3 — HA/Raft, 3 replicas |
| **Identity / SSO** | Keycloak 26.3.3 — PostgreSQL backend |
| **Auth integration** | Vault OIDC auth → Keycloak `kind` realm |
| **kubectl SSO** | kube-apiserver OIDC → Keycloak; per-team RBAC |
| **Ingress** | nginx ingress-nginx v1.15.1 — ports 80 (HTTP) + 443 (HTTPS) |
| **Cluster** | kind v0.29 — 1 control-plane + 3 workers, K8s v1.35 |

---

## Architecture

```
                  /etc/hosts
  127.0.0.1  vault-webui.local
  127.0.0.1  keycloak.local
                     │
          ┌──────────▼──────────┐
          │  nginx Ingress      │  port 80 (HTTP) + 443 (HTTPS, TLS-terminated)
          └──────┬────────┬─────┘
                 │        │
    ┌────────────▼──┐  ┌──▼─────────────────┐
    │  NS: vault    │  │  NS: keycloak       │
    │               │  │                     │
    │  Vault ×3     │  │  Keycloak 26        │
    │  (HA/Raft)    │  │  PostgreSQL 17      │
    └───────────────┘  └─────────────────────┘
           │ Vault OIDC (HTTP / internal)         kubectl OIDC (HTTPS)
           └──────────────────────────────────►  Keycloak kind realm  ◄──────── kube-apiserver
```

---

## Prerequisites

| Tool      | Min version | Install |
|-----------|-------------|---------|
| `kind`    | v0.24+      | `brew install kind` |
| `kubectl` | v1.29+      | `brew install kubectl` |
| `helm`    | v4.x        | `brew install helm` |
| `podman`  | any recent  | `brew install podman` (kind uses Podman on macOS) |
| `jq`      | any         | `brew install jq` |

> Docker also works in place of Podman.

---

## Setup Order

Follow the sub-READMEs in this order:

```
1. vault/                        → cluster + nginx + Vault
2. keycloak/                     → Keycloak + kind realm + users/groups
3. keycloak/vault-integration/   → connect Vault OIDC to Keycloak
4. keycloak/k8s-oidc/            → kubectl SSO via Keycloak (optional)
5. application/team-a-webapp/    → Kubernetes secrets engine + 2-tier sample app
```

### 1. Create cluster, nginx, Vault

```bash
# See vault/README.md for full steps
kind create cluster --config vault/kind.yaml
kubectl apply -f vault/deploy-ingress-nginx.yaml
helm install vault hashicorp/vault --namespace vault --create-namespace --values vault/vault.yaml
# Initialize + unseal — see vault/README.md
```

### 2. Deploy Keycloak

```bash
cd keycloak/
chmod +x install.sh
./install.sh
# Add to /etc/hosts: 127.0.0.1  keycloak.local
```

### 3. Connect Vault ↔ Keycloak (OIDC)

```bash
cd keycloak/vault-integration/
chmod +x setup.sh
./setup.sh
```

### 4. kubectl SSO via Keycloak (optional)

Enables `kubectl` login with Keycloak credentials. See [keycloak/k8s-oidc/README.md](keycloak/k8s-oidc/README.md).

```bash
cd keycloak/k8s-oidc/
chmod +x setup.sh
./setup.sh
```

### 5. Kubernetes secrets engine + team-a 2-tier webapp

Enables the Vault Kubernetes secrets engine and deploys a sample frontend/backend/DB
application in the `team-a` namespace. DB credentials are stored in Vault and injected
into the backend pod at runtime by Vault Agent.

```bash
# Apply RBAC so Vault SA can generate K8s tokens
kubectl apply -f application/team-a-webapp/vault-rbac.yaml

# Configure Vault (run once)
cd application/team-a-webapp/
chmod +x vault-setup.sh
./vault-setup.sh

# Deploy the application
kubectl apply -f application/team-a-webapp/serviceaccount.yaml
kubectl apply -f application/team-a-webapp/postgres.yaml
kubectl apply -f application/team-a-webapp/backend-configmap.yaml
kubectl apply -f application/team-a-webapp/backend.yaml
kubectl apply -f application/team-a-webapp/frontend-configmap.yaml
kubectl apply -f application/team-a-webapp/frontend.yaml
kubectl apply -f application/team-a-webapp/ingress.yaml

# Add local DNS entry (one-time)
echo "127.0.0.1 team-a-webapp.local" | sudo tee -a /etc/hosts
```

Open http://team-a-webapp.local in your browser.



| Service | URL | Credentials |
|---------|-----|-------------|
| Vault UI | https://vault-webui.local (http → https) | root token from `vault/cluster-keys.json` |
| Vault OIDC login | https://vault-webui.local → OIDC → role `default` | Keycloak users (password: `password`) |
| Keycloak Admin | https://keycloak.local/admin (http → https) | `admin` / `Admin@Keycloak2024!` |
| Keycloak kind realm | https://keycloak.local/realms/kind (http → https) | — |

> HTTP (port 80) redirects to HTTPS (port 443) for both Vault and Keycloak via a 308 permanent redirect — browsers follow automatically. HTTPS uses a self-signed CA (`keycloak/k8s-oidc/keycloak-local-ca.crt`). Trust it once in your macOS keychain:
> ```bash
> sudo security add-trusted-cert -d -r trustRoot \
>   -k /Library/Keychains/System.keychain \
>   keycloak/k8s-oidc/keycloak-local-ca.crt
> ```

---

## Vault OIDC Access Matrix

Users log in to Vault via Keycloak. Group membership in the `kind` realm drives Vault policy:

| Keycloak Group | Vault Policy | Vault Access |
|----------------|-------------|--------------|
| `devops` | `devops-policy` | All paths `*` (full admin) |
| `team-a` | `team-a-policy` | `secret/data/team-a/*` only |
| `team-b` | `team-b-policy` | `secret/data/team-b/*` only |

---

## Repository Structure

```
vault-on-kubernetes/
├── vault/
│   ├── README.md                  ← Vault + nginx setup guide
│   ├── kind.yaml                  ← kind cluster (1 CP + 3 workers)
│   ├── vault.yaml                 ← Vault Helm values (HA/Raft, HTTPS ingress)
│   ├── deploy-ingress-nginx.yaml  ← nginx ingress-nginx v1.15.1
│   └── cluster-keys.json          ← ⚠️  DO NOT COMMIT — unseal keys + root token
│
├── keycloak/
│   ├── README.md                  ← Keycloak setup guide
│   ├── install.sh                 ← one-shot Keycloak install script
│   ├── namespace.yaml
│   ├── postgres.yaml              ← PostgreSQL 17 StatefulSet
│   ├── keycloak.yaml              ← Keycloak 26 Deployment (optimised)
│   ├── ingress.yaml               ← nginx Ingress → keycloak.local (HTTP + HTTPS)
│   ├── kind-realm.json            ← realm definition (groups + users)
│   ├── vault-integration/
│   │   ├── setup.sh               ← Vault ↔ Keycloak OIDC wiring script
│   │   └── policies/
│   │       ├── devops.hcl         ← full admin policy
│   │       ├── team-a.hcl         ← team-a scoped policy
│   │       └── team-b.hcl         ← team-b scoped policy
│   └── k8s-oidc/
│       ├── README.md              ← kubectl SSO setup guide
│       ├── setup.sh               ← end-to-end kubectl OIDC setup script
│       ├── keycloak-local-ca.crt  ← self-signed CA (generated; covers keycloak.local + vault-webui.local)
│       ├── kubeconfig-oidc.yaml   ← kubectl contexts (generated)
│       └── rbac/
│           ├── devops-cluster-admin.yaml
│           ├── team-a.yaml
│           └── team-b.yaml
│
└── application/                   ← example Vault-injected workloads
```

---

## Teardown

```bash
kind delete cluster --name vault
```

---

## Security Notice

This project is a **local demo on a kind cluster**. The following are intentional
trade-offs to keep setup simple. None of these are acceptable in production.

| Item | Value in this repo | Production alternative |
|------|-------------------|----------------------|
| Vault root token | Stored in `vault/cluster-keys.json` (gitignored) | Use Vault auto-unseal (AWS KMS, GCP CKMS, etc.) and rotate root token |
| Keycloak admin password | `Admin@Keycloak2024!` | Random secret, managed by a secrets manager |
| Keycloak DB password | `Keycloak@2024!` | Dynamic credentials via Vault database secrets engine |
| OIDC client secret | `Vault@Keycloak2024!` | Randomly generated, rotated regularly |
| Demo user password | `password` | Enforced via Keycloak password policy |
| Webapp DB password | `S3cur3P@ssw0rd` | Dynamic credentials via Vault database secrets engine |
| TLS | Self-signed CA for `keycloak.local` | Cert-manager + Let's Encrypt (or internal CA) |
| Vault TLS | Disabled (`tlsDisable: true`) | TLS everywhere, even in-cluster |
| `kubeconfig-oidc.yaml` | Gitignored (has local absolute paths) | Generated per-user by `setup.sh` |
| `keycloak-local-ca.crt` | Gitignored (generated file) | Generated per-user by `setup.sh` |

> `vault/cluster-keys.json` is covered by both `vault/.gitignore` and the
> root `.gitignore`. Verify it is not tracked before pushing:
> ```bash
> git check-ignore -v vault/cluster-keys.json
> ```

