# 07 — Monitoring Stack

Installs **Prometheus + Alertmanager + Grafana + Blackbox Exporter** on the kind cluster with:

- HTTPS access on `*.kind.local` (via cert-manager wildcard cert + Envoy Gateway)
- Grafana authenticated through **Keycloak** (`kind` realm)
- **Three Grafana organizations** with namespace-scoped access:

| Grafana Org | Keycloak group | Access |
|---|---|---|
| `admin` | `devops` | Full admin — all cluster dashboards |
| `team-a` | `team-a` | Admin — team-a namespace dashboards only |
| `team-b` | `team-b` | Admin — team-b namespace dashboards only |

---

## Architecture

```
Browser / curl
    │  HTTPS *.kind.local  (cert-manager wildcard cert)
    ▼
Envoy Gateway (native-gateway)
    │
    ├── prometheus.kind.local      ──► kube-prom-kube-prometheus-prometheus:9090
    ├── grafana.kind.local         ──► kube-prom-grafana:80
    ├── alertmanager.kind.local    ──► kube-prom-kube-prometheus-alertmanager:9093
    └── blackbox-exporter.kind.local ► blackbox-prometheus-blackbox-exporter:9115

Grafana
    │  OAuth2 OIDC (token exchange via CoreDNS → Envoy GW → Keycloak)
    ▼
Keycloak  (kind realm, grafana OIDC client)
    │
    ├── devops  group  →  Admin in admin + team-a + team-b orgs
    ├── team-a  group  →  Admin in team-a org only
    └── team-b  group  →  Admin in team-b org only

Prometheus (kube-prom-kube-prometheus-prometheus)
    │  scrapes
    ├── Node Exporter        (kube-prom-prometheus-node-exporter)
    ├── kube-state-metrics   (kube-prom-kube-state-metrics)
    ├── Kubernetes API / etcd / controller-manager / scheduler
    ├── All ServiceMonitors / PodMonitors (across all namespaces)
    └── Blackbox Exporter    (blackbox-prometheus-blackbox-exporter)
            │  probes (HTTP 2xx)
            ├── https://vault.kind.local/v1/sys/health
            ├── https://keycloak.kind.local/realms/kind/.well-known/...
            ├── https://team-a-webapp.kind.local/api/health
            ├── https://grafana.kind.local/api/health
            ├── https://prometheus.kind.local/-/healthy
            └── https://alertmanager.kind.local/-/healthy
```

---

## Components

| Component | Chart | App version | Release name | Namespace |
|---|---|---|---|---|
| kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` | `87.19.0` | `kube-prom` | `monitoring` |
| Prometheus | (included) | v2.x | — | `monitoring` |
| Alertmanager | (included) | v0.x | — | `monitoring` |
| Grafana | (included) | 13.1.1 | — | `monitoring` |
| Node Exporter | (included) | — | — | `monitoring` |
| kube-state-metrics | (included) | — | — | `monitoring` |
| Prometheus Blackbox Exporter | `prometheus-community/prometheus-blackbox-exporter` | `11.15.1` | `blackbox` | `monitoring` |

### Kubernetes resources created

| Kind | Name | Purpose |
|---|---|---|
| `StatefulSet` | `prometheus-kube-prom-kube-prometheus-prometheus` | Prometheus server, 30d retention, 10Gi PVC |
| `StatefulSet` | `alertmanager-kube-prom-kube-prometheus-alertmanager` | Alertmanager, 1Gi PVC |
| `Deployment` | `kube-prom-grafana` | Grafana server, 2Gi PVC |
| `DaemonSet` | `kube-prom-prometheus-node-exporter` | Host-level CPU/memory/disk metrics |
| `Deployment` | `kube-prom-kube-state-metrics` | Kubernetes object state metrics |
| `Deployment` | `blackbox-prometheus-blackbox-exporter` | HTTP/TCP/ICMP endpoint prober |
| `Deployment` | `kube-prom-kube-prometheus-operator` | Prometheus Operator (manages CRDs) |
| `HTTPRoute` | `prometheus/grafana/alertmanager/blackbox-exporter` | External HTTPS access |
| `HTTPRoute` | `*-http-redirect` | HTTP→HTTPS 301 redirects |

---

## Installation

### Step 1 — Add DNS entries

```bash
sudo tee -a /etc/hosts << 'EOF'
127.0.0.1 prometheus.kind.local
127.0.0.1 grafana.kind.local
127.0.0.1 alertmanager.kind.local
127.0.0.1 blackbox-exporter.kind.local
EOF
```

### Step 2 — Install kube-prometheus-stack

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --create-namespace \
  --values values.yaml \
  --version 87.19.0

# Wait for all components
kubectl rollout status deployment/kube-prom-grafana -n monitoring --timeout=300s
kubectl wait pod -n monitoring -l app.kubernetes.io/name=prometheus \
  --for=condition=Ready --timeout=300s
```

### Step 3 — Install Blackbox Exporter

```bash
helm install blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring \
  --values blackbox-values.yaml \
  --version 11.15.1
```

### Step 4 — Apply HTTPRoutes

```bash
kubectl apply -f httproutes.yaml
```

### Step 5 — Run the setup script (Keycloak + Grafana orgs + dashboards)

```bash
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — safe to re-run. It:
1. Updates CoreDNS to resolve ALL `*.kind.local` → Envoy Gateway ClusterIP
2. Creates the `grafana` Keycloak OIDC client with a flat-name groups mapper
3. Renames Grafana org 1 to `admin`; creates `team-a` and `team-b` orgs
4. Creates a Prometheus datasource in each org
5. Imports a namespace-scoped dashboard into `team-a` and `team-b` orgs

---

## Access

| Service | URL | Credentials |
|---|---|---|
| Grafana | https://grafana.kind.local | Local: `admin` / `Admin@Grafana2024!` or SSO via Keycloak |
| Prometheus | https://prometheus.kind.local | No auth (internal only) |
| Alertmanager | https://alertmanager.kind.local | No auth (internal only) |
| Blackbox Exporter | https://blackbox-exporter.kind.local | No auth |

### Grafana SSO login

1. Open `https://grafana.kind.local`
2. Click **Sign in with Keycloak**
3. Log in with a Keycloak user (password: `password`):

| User | Group | Grafana orgs accessible |
|---|---|---|
| `devops-user-1` | `devops` | admin, team-a, team-b |
| `team-a-user-1` | `team-a` | team-a |
| `team-b-user-1` | `team-b` | team-b |

Switch organizations from the user menu → **Switch Organization**.

### Grafana dashboards

**admin org** (devops only): Pre-built cluster-wide dashboards imported automatically by the Grafana sidecar:
- Kubernetes / Compute Resources / Cluster
- Kubernetes / Compute Resources / Namespace (all)
- Node Exporter / Nodes
- Alertmanager / Overview
- Prometheus / Overview
- …and many more (all dashboards bundled with kube-prometheus-stack)

**team-a org** (team-a + devops): `Team A — Namespace Overview`
- Running pods, total pods, restarts
- CPU usage by pod (time-series)
- Memory usage by pod (time-series)
- Pod status table

**team-b org** (team-b + devops): `Team B — Namespace Overview` (same as team-a, scoped to `team-b` namespace)

---

## Verify

```bash
# All monitoring pods running
kubectl get pods -n monitoring

# HTTPRoutes accepted
kubectl get httproute -n monitoring

# Prometheus targets (should include blackbox-http-platform)
curl -s https://prometheus.kind.local/api/v1/targets | python3 -m json.tool | grep '"job"' | sort -u

# Grafana health
curl -s https://grafana.kind.local/api/health

# Alertmanager health
curl -s https://alertmanager.kind.local/-/healthy

# Blackbox probe result for Vault
curl -s "https://blackbox-exporter.kind.local/probe?target=https://vault.kind.local/v1/sys/health&module=http_2xx_insecure" \
  | grep probe_success
# probe_success 1

# Check Grafana orgs
curl -s -u admin:Admin@Grafana2024! https://grafana.kind.local/api/orgs
```

---

## Upgrading the stack

### Upgrade procedure

The kube-prometheus-stack includes CRDs. The CRD upgrade must happen **before** the Helm chart upgrade.

**Always read the migration notes** for the target version:
```
https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#upgrading-chart
```

#### Step-by-step upgrade

```bash
# 1. Update Helm repos
helm repo update

# 2. Check the latest available versions
helm search repo prometheus-community/kube-prometheus-stack --versions | head -5
helm search repo prometheus-community/prometheus-blackbox-exporter --versions | head -5

# 3. Review breaking changes between current and target version
#    https://github.com/prometheus-community/helm-charts/blob/main/charts/kube-prometheus-stack/CHANGELOG.md

# 4. Upgrade CRDs FIRST (required for major chart upgrades)
#    Replace X.Y.Z with the target chart version
CHART_VERSION=87.19.0   # change to new version
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/prometheus-community/helm-charts/kube-prometheus-stack-${CHART_VERSION}/charts/kube-prometheus-stack/charts/crds/crds/crd-alertmanagerconfigs.yaml \
  --force-conflicts
# Repeat for all CRD files in that release, or use the chart's CRD script:
# https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack#uninstalling-the-chart

# 5. Upgrade the Helm release (preserves PVCs and custom values)
helm upgrade kube-prom prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values values.yaml \
  --version <NEW_VERSION> \
  --reuse-values \
  --atomic \
  --timeout 10m

# 6. Upgrade blackbox exporter
helm upgrade blackbox prometheus-community/prometheus-blackbox-exporter \
  --namespace monitoring \
  --values blackbox-values.yaml \
  --version <NEW_BLACKBOX_VERSION> \
  --reuse-values

# 7. Verify all pods are healthy
kubectl rollout status deployment/kube-prom-grafana -n monitoring
kubectl get pods -n monitoring
```

#### Rollback

```bash
# If the upgrade fails, Helm --atomic rolls back automatically.
# For manual rollback:
helm rollback kube-prom -n monitoring
helm rollback blackbox -n monitoring
```

### Upgrading Grafana only

If only Grafana has breaking changes, you can pin the grafana subchart version:

```yaml
# Add to values.yaml under grafana:
grafana:
  image:
    tag: "13.1.1"   # pin to known-good version
```

### Upgrading Prometheus only

Prometheus is managed by the Prometheus Operator. The StatefulSet is reconciled from the `Prometheus` CRD. To change just the Prometheus version:

```yaml
# Add to values.yaml
prometheus:
  prometheusSpec:
    image:
      tag: v2.54.0   # pin to specific version
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Grafana shows "Sign in with Keycloak" button but login fails | OIDC client not created / wrong secret | Re-run `./setup.sh` step 2 |
| Grafana OIDC login succeeds but user has no org | Orgs not created yet | Re-run `./setup.sh` step 4 |
| Grafana user in wrong org after Keycloak group change | Org sync happens on login | Log out and back in; clear browser cookies |
| Blackbox targets showing `probe_success 0` | DNS not updated in CoreDNS | Re-run `./setup.sh` step 1 |
| Prometheus not scraping new namespaces | `serviceMonitorSelectorNilUsesHelmValues: true` | Already set to `false` in values.yaml |
| Pods stuck in Pending (PVC not bound) | No StorageClass / local-path not set | `kubectl get sc; kubectl get pvc -n monitoring` |
| HTTPRoute not accepting traffic | Service name mismatch | `kubectl get svc -n monitoring`; check release name is `kube-prom` |
| Alertmanager shows `unknown receiver` | Custom receiver config not applied | `helm upgrade kube-prom ... --values values.yaml` |
| `kube-state-metrics` CrashLoopBackOff | RBAC missing for new K8s version | `helm upgrade` to latest chart version |

### Useful commands

```bash
# Check all monitoring pods
kubectl get pods -n monitoring -o wide

# Watch Prometheus operator logs
kubectl logs -n monitoring -l app.kubernetes.io/name=prometheus-operator -f

# Check Prometheus config (shows all scrape targets + rule files)
kubectl exec -n monitoring statefulset/prometheus-kube-prom-kube-prometheus-prometheus -- \
  cat /etc/prometheus/config_out/prometheus.env.yaml | head -80

# Reload Prometheus config (without restart)
curl -X POST https://prometheus.kind.local/-/reload

# Grafana API — list all orgs
curl -s -u admin:Admin@Grafana2024! https://grafana.kind.local/api/orgs | python3 -m json.tool

# Grafana API — list users in org 2 (team-a)
curl -s -u admin:Admin@Grafana2024! https://grafana.kind.local/api/orgs/2/users | python3 -m json.tool

# Blackbox manual probe test
curl -s "https://blackbox-exporter.kind.local/probe?target=https://vault.kind.local/v1/sys/health&module=http_2xx_insecure"

# Port-forward Prometheus for direct PromQL
kubectl port-forward -n monitoring svc/kube-prom-kube-prometheus-prometheus 9090:9090 &
# then: http://localhost:9090
```

---

## Security notice (local demo)

| Item | Value here | Production alternative |
|---|---|---|
| Grafana admin password | `Admin@Grafana2024!` | Random secret via secrets manager |
| Grafana OIDC client secret | `Grafana@Keycloak2024!` | Randomly generated, stored in Vault |
| TLS skip verify (Grafana→Keycloak) | `tls_skip_verify_insecure: true` | Mount cert-manager CA cert as volume |
| Alertmanager receivers | null (no notifications) | PagerDuty / Slack / email |
| Prometheus storage | 10Gi local-path | Distributed storage (Thanos / Cortex) |
| Grafana persistence | 2Gi local-path | Managed PostgreSQL for HA Grafana |
| Namespace isolation | Dashboard-level filtering | Prometheus per-tenant proxy (cortex-tenant) |
