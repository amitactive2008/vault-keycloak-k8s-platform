# HashiCorp Vault on Kubernetes (kind cluster)

Deploy a production-style Vault HA cluster with Raft storage behind an nginx
ingress on a local [kind](https://kind.sigs.k8s.io/) cluster.

---

## Prerequisites

| Tool | Version used | Install |
|------|-------------|---------|
| Podman | any recent | `brew install podman` (( I am using 5.5.0)) |
| kind | ≥ 0.24 | `brew install kind` ( I am using 0.32)| 
| kubectl | ≥ 1.29 | `brew install kubectl` ( I am using 1.36) |
| Helm | ≥ 4.x | `brew install helm` ( I am using 4.2)|
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

export kubeconfig and verify nodes are ready:

```bash
kind export kubeconfig --name=vault
kubectl get nodes
```

Expected output — 1 control-plane + 3 workers, all `Ready`.

---

## Step 2 — Install ingress-nginx

The ingress-nginx controller is packaged as a Helm chart inside this folder.
User-facing configuration lives in `values.yaml`; all available knobs are
documented in `ingress-nginx/values.yaml`.

### 2a — (Optional) Preview the rendered manifests

```bash
helm template ingress-nginx ./ingress-nginx \
  -f ./values.yaml \
  --namespace ingress-nginx
```

### 2b — Install

```bash
helm install ingress-nginx ./ingress-nginx \
  -f ./values.yaml \
  --namespace ingress-nginx --create-namespace
```

Wait for the controller pod to become ready:

```bash
kubectl rollout status deployment ingress-nginx-controller \
  -n ingress-nginx --timeout=120s
```

### 2c — Verify

```bash
# Controller pod is Running on the control-plane node
kubectl get pods -n ingress-nginx -o wide

kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=120s

# LoadBalancer service (EXTERNAL-IP = localhost in kind)
kubectl get svc ingress-nginx-controller -n ingress-nginx

# IngressClass is registered
kubectl get ingressclass nginx
```

### 2d — Upgrade (after editing values.yaml)

```bash
helm upgrade ingress-nginx ./ingress-nginx \
  -f ./values.yaml \
  --namespace ingress-nginx
```

### 2e — Uninstall

```bash
helm uninstall ingress-nginx --namespace ingress-nginx
```


### Common values to override in `values.yaml`

| Key | Default | When to change |
|-----|---------|----------------|
| `controller.replicaCount` | `1` | Scale up for HA |
| `controller.nodeSelector.kubernetes.io/hostname` | `vault-control-plane` | Different cluster name |
| `controller.service.type` | `LoadBalancer` | Use `NodePort` on bare-metal |
| `controller.resources.requests.cpu` | `500m` | Tune for your node capacity |
| `controller.resources.requests.memory` | `250Mi` | Tune for your node capacity |
| `controller.config.workerProcesses` | `"1"` | Increase for production |
| `admissionWebhooks.enabled` | `true` | Set `false` to skip webhook Jobs |
