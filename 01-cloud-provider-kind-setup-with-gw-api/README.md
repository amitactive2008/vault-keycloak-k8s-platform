# Cloud-Provider-Kind + Gateway API Setup

Platform: macOS + Podman + Kind + Envoy Gateway

## Architecture

```
curl https://sample.kind.local
        │
        ▼
kindccm Envoy container  (0.0.0.0:80->80, 0.0.0.0:443->443)
        │  LoadBalancer external IP assigned by cloud-provider-kind
        ▼
Envoy Gateway pods  (namespace: envoy-gateway-system)
        │  GatewayClass: envoy-gateway
        │  Gateway listeners: HTTP:80 (redirect) + HTTPS:443 (TLS terminate)
        │  Wildcard TLS cert: *.kind.local (issued + auto-renewed by cert-manager)
        │  HTTPRoute rules
        ▼
Backend services (Vault, Keycloak, etc.)
```

## Key Design Decisions

- **No `extraPortMappings` in kind.yaml**: cloud-provider-kind creates a dedicated Envoy container per LoadBalancer service and binds it directly to the host port (e.g. `0.0.0.0:80->80`, `0.0.0.0:443->443`). If `extraPortMappings` claim those ports on a Kind node, cloud-provider-kind fails to bind its Envoy container to the same port.
- **`--gateway-channel standard`**: cloud-provider-kind installs Gateway API CRDs automatically. Do not apply `standard-install.yaml` separately — it installs a `safe-upgrades` ValidatingAdmissionPolicy that blocks cloud-provider-kind from managing CRDs.
- **Envoy Gateway (`--skip-crds`)**: Provides a production-grade Gateway API controller with in-cluster Envoy proxy pods and a proper LoadBalancer service. Installed with `--skip-crds` since CRDs are already provided by cloud-provider-kind.
- **cert-manager for TLS**: Replaces manual `openssl` cert generation. cert-manager bootstraps a local CA (ECDSA P-256, 5-year) and issues + auto-renews a wildcard `*.kind.local` TLS certificate (1-year, renews 30 days before expiry). The `wildcard-kind-local-tls` Secret in the `default` namespace is created and maintained entirely by cert-manager.

---

## Step 1: Configure Podman for Rootful Mode

Kind requires root permissions inside Podman to manage internal container networking and allow cloud-provider-kind to route traffic natively.

1. Open Podman Desktop.
2. Go to Settings > Resources.
3. Ensure your Podman machine is running in rootful mode. If it is marked as rootless, recreate it via the UI or run:

```bash
podman machine stop
podman machine set --rootful=true
podman machine start
```

## Step 2: Install cloud-provider-kind on your Mac

The cloud-provider-kind utility must run as a binary directly on your macOS host, not inside a container.

```bash
brew install cloud-provider-kind
```

Verify:

```bash
cloud-provider-kind version
```

## Step 3: Create the Kind Cluster

The `kind.yaml` defines a 1 control-plane + 3 worker cluster with **no** `extraPortMappings`. Port binding is handled entirely by cloud-provider-kind's Envoy containers.

```bash
kind create cluster --config kind.yaml
kind export kubeconfig --name vault
```

Verify all nodes are Ready:

```bash
kubectl get nodes
```

## Step 4: Start cloud-provider-kind

Run this in a **dedicated terminal window** and keep it running for the lifetime of the cluster. It installs Gateway API CRDs, registers the `cloud-provider-kind` GatewayClass, and manages LoadBalancer IP and port assignment.

```bash
sudo cloud-provider-kind --gateway-channel standard --enable-lb-port-mapping
```

Verify the GatewayClass is registered:

```bash
kubectl get gatewayclass
# NAME                  CONTROLLER                            ACCEPTED
# cloud-provider-kind   kind.sigs.k8s.io/gateway-controller   True
```

## Step 5: Install Envoy Gateway

Envoy Gateway provides the `envoy-gateway` GatewayClass controller. Use `--skip-crds` because Gateway API CRDs were already installed by cloud-provider-kind in Step 4.

```bash
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.4.0 \
  -n envoy-gateway-system \
  --create-namespace \
  --skip-crds
```

Wait for the controller to be ready:

```bash
kubectl rollout status deployment/envoy-gateway -n envoy-gateway-system
```

## Step 6: Install cert-manager

cert-manager automates TLS certificate issuance and renewal. It bootstraps a local CA and issues the wildcard `*.kind.local` certificate — no `openssl` commands or manual secret creation needed.

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Wait for all cert-manager components to be Ready:

```bash
kubectl rollout status deployment/cert-manager -n cert-manager
kubectl rollout status deployment/cert-manager-cainjector -n cert-manager
kubectl rollout status deployment/cert-manager-webhook -n cert-manager
```

## Step 7: Issue the Wildcard TLS Certificate via cert-manager

Apply `cert-manager.yaml`, which creates:
- `selfsigned-issuer` — bootstraps the root CA
- `kind-local-ca` — root CA certificate (ECDSA P-256, 5-year, stored as `kind-local-ca-secret` in `cert-manager` namespace)
- `kind-local-ca-issuer` — CA-backed ClusterIssuer for signing `*.kind.local` certs
- `wildcard-kind-local-tls` — wildcard certificate (ECDSA P-256, 1-year, auto-renewed 30 days before expiry, stored as `wildcard-kind-local-tls` Secret in `default` namespace)

```bash
kubectl apply -f cert-manager.yaml
```

Wait for both certificates to become Ready:

```bash
kubectl wait --for=condition=Ready certificate/kind-local-ca \
  -n cert-manager --timeout=60s

kubectl wait --for=condition=Ready certificate/wildcard-kind-local-tls \
  -n default --timeout=60s
```

Verify the wildcard TLS secret exists (referenced by the Gateway):

```bash
kubectl get secret wildcard-kind-local-tls -n default
# NAME                      TYPE                DATA
# wildcard-kind-local-tls   kubernetes.io/tls   3
```

Verify certificate details:

```bash
kubectl get certificate -n cert-manager
kubectl get certificate -n default
```

### Trust the CA on your Mac (one-time)

Extract the CA cert from the cert-manager secret and trust it in the macOS System Keychain.
This makes `curl` and browsers trust all `*.kind.local` services without `--cacert` flags.

```bash
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/kind-local-ca.crt

sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/kind-local-ca.crt

rm /tmp/kind-local-ca.crt
```

## Step 8: Deploy the Gateway Infrastructure

Apply `gateway-infra.yaml` which creates:
- A `GatewayClass` backed by the Envoy Gateway controller
- A `Gateway` with two listeners: HTTP:80 (redirects to HTTPS) and HTTPS:443 (TLS termination with `*.kind.local` cert)
- An HTTP→HTTPS redirect `HTTPRoute` for all `*.kind.local` traffic
- An HTTPS `HTTPRoute` for the test app at `sample.kind.local`

```bash
kubectl apply -f gateway-infra.yaml
```

Verify both GatewayClasses are accepted and the Gateway is programmed:

```bash
kubectl get gatewayclass
# envoy-gateway   gateway.envoyproxy.io/gatewayclass-controller   True

kubectl get gateway native-gateway
# NAME             CLASS           ADDRESS       PROGRAMMED
# native-gateway   envoy-gateway   10.89.0.xx    True
```

Verify the Envoy container has both ports bound:

```bash
podman ps --format "table {{.Names}}\t{{.Ports}}" | grep kindccm
# kindccm-xxx   0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp, ...
```

> **Note:** If the Envoy container only shows port 80 after adding the HTTPS listener, the container needs to be recreated. Delete and re-apply the gateway:
> ```bash
> kubectl delete gateway native-gateway
> kubectl apply -f gateway-infra.yaml
> ```

## Step 9: Deploy a Test Application

```bash
kubectl apply -f app-deployment.yaml
```

## Step 10: Configure Local DNS

Add an entry to `/etc/hosts` for each `*.kind.local` hostname you want to use locally:

```bash
sudo tee -a /etc/hosts <<'EOF'
127.0.0.1 sample.kind.local
127.0.0.1 vault.kind.local
127.0.0.1 keycloak.kind.local
EOF
```

## Step 11: Verify End-to-End Traffic

```bash
# HTTPS — CA is trusted in macOS System Keychain (Step 7)
curl https://sample.kind.local/
# Server address: 10.244.x.x:80
# Server name: sample-web-xxxxxxxxx-xxxxx

# HTTP → HTTPS redirect
curl -v http://sample.kind.local/ 2>&1 | grep -E "HTTP|Location"
# < HTTP/1.1 301 Moved Permanently
# < location: https://sample.kind.local/
```

---

## Teardown

```bash
kind delete cluster --name vault
# Ctrl+C in the terminal where cloud-provider-kind is running
```

---

## Troubleshooting

**LoadBalancer stuck at `<pending>` / `SyncLoadBalancerFailed`**

cloud-provider-kind failed to bind the host port. Most common cause: a Kind node has `extraPortMappings` claiming the same port (80 or 443). Remove `extraPortMappings` from `kind.yaml` and recreate the cluster.

**Port 443 not appearing in `podman ps` after adding HTTPS listener**

Podman cannot add ports to a running container. Delete and re-apply the Gateway to force container recreation:

```bash
kubectl delete gateway native-gateway
kubectl apply -f gateway-infra.yaml
```

**GatewayClass `envoy-gateway` shows `Unknown`**

The Envoy Gateway controller is not running. Check:

```bash
kubectl get pods -n envoy-gateway-system
```

**`safe-upgrades` ValidatingAdmissionPolicy blocking CRD updates**

This policy is installed if you manually apply the Gateway API standard CRD bundle.
Do not apply external GW API CRD manifests — let cloud-provider-kind manage them via
`--gateway-channel standard`. If you accidentally applied such a manifest, remove the policy:

```bash
kubectl delete validatingadmissionpolicybinding safe-upgrades.gateway.networking.k8s.io --ignore-not-found
kubectl delete validatingadmissionpolicy safe-upgrades.gateway.networking.k8s.io --ignore-not-found
```

**TLS certificate not trusted by browser or curl**

Trust the local CA on your Mac. Extract from cert-manager and add to Keychain:

```bash
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/kind-local-ca.crt
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain /tmp/kind-local-ca.crt
rm /tmp/kind-local-ca.crt
```

**Certificate not Ready after applying cert-manager.yaml**

Check cert-manager events and certificate status:

```bash
kubectl describe certificate wildcard-kind-local-tls -n default
kubectl describe certificate kind-local-ca -n cert-manager
kubectl get certificaterequest -n default
kubectl get certificaterequest -n cert-manager
kubectl logs -n cert-manager -l app=cert-manager --tail=50
```

Common cause: cert-manager webhook not yet ready. Wait ~30s after `helm install` and retry:

```bash
kubectl rollout status deployment/cert-manager-webhook -n cert-manager
kubectl apply -f cert-manager.yaml
```

**Gateway programmed but `curl https://sample.kind.local/` returns connection refused**

Verify the Envoy container has port 443 bound:

```bash
podman ps --format "table {{.Names}}\t{{.Ports}}" | grep kindccm
```

If not, cycle the gateway (see port 443 note in Step 8).
