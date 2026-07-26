# 09 — Sample React + Node.js Application

A full-stack **User Management** web application demonstrating a complete DevSecOps pipeline on the kind cluster.

| Layer | Technology |
|---|---|
| Frontend | React 19, React Router v7, Axios, Nginx |
| Backend | Node.js 22, Express, Sequelize ORM, mysql2 |
| Database | MySQL 8.0 |
| Auth | JWT (jsonwebtoken) + bcryptjs |
| Secrets | HashiCorp Vault (Vault Agent sidecar injection) |
| CI/CD | Jenkins (role-strategy folder access) + SonarQube |
| Container | Docker multi-stage builds via BuildKit |

---

## Architecture

```
Browser
    │  HTTPS  (cert-manager wildcard cert)
    ▼
Envoy Gateway → sample-react-app.kind.local
    │
    ▼
[client pod] Nginx :80  (namespace: team-a)
    │  Serves React SPA static files
    │  Proxies /api/* → api-service:5000
    ▼
[api pod] Node.js Express :5000  (namespace: team-a)
    │  Vault Agent sidecar reads:
    │    secret/data/team-a/sample-react-app/api
    │    → DB_HOST, DB_PORT, DB_USER, DB_PASSWORD, DB_NAME, JWT_SECRET
    ▼
MySQL :3306  (namespace: team-a, StatefulSet)
```

### How Nginx proxies the API

`client/default.conf` is baked into the client Docker image:

```nginx
location /api/ {
  proxy_pass http://api-service:5000;   # K8s ClusterIP service (same namespace)
}
location / {
  try_files $uri /index.html;           # React Router SPA fallback
}
```

The React frontend calls `/api/auth/login`, `/api/users`, etc. — Nginx forwards them to the `api-service` ClusterIP within the `team-a` namespace. No CORS issues, no URL configuration needed in the React build.

---

## API endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/auth/register` | No | Register new user |
| `POST` | `/api/auth/login` | No | Login, returns JWT |
| `GET` | `/api/users` | JWT | List all users |
| `POST` | `/api/users` | JWT | Create user |
| `PUT` | `/api/users/:id` | JWT + admin | Update user |
| `DELETE` | `/api/users/:id` | JWT + admin | Delete user |
| `GET` | `/health` | No | DB connectivity check |
| `GET` | `/live` | No | Liveness check |

---

## Vault secret paths

Secrets are stored in Vault KV v2 under the team-a namespace path.  
The API pod uses **Vault Agent injection** to source these at startup.

| Path | Contents | Consumer |
|---|---|---|
| `secret/data/team-a/sample-react-app/api` | `DB_HOST`, `DB_PORT`, `DB_USER`, `DB_PASSWORD`, `DB_NAME`, `JWT_SECRET` | API pod (via Vault Agent → `/vault/secrets/api.env`) |
| `secret/data/team-a/sample-react-app/client` | `REACT_APP_API_URL`, `REACT_APP_ENV` | Reference only (client uses K8s service DNS at runtime) |

---

## Jenkins folder structure

```
team-a/
└── sample-react-app/
    ├── api/
    │   ├── ci    ← API CI pipeline (9 stages)
    │   └── cd    ← API CD pipeline (deploys to team-a namespace)
    └── client/
        ├── ci    ← Client CI pipeline (10 stages, includes unit tests)
        └── cd    ← Client CD pipeline
```

Access is controlled by the **Role Strategy Plugin**:
- `devops` group → global admin (can see and run all folders)
- `team-a` group → `team-a.*` item role (can see and run only team-a folder)

---

## CI Pipeline stages

### API CI (`api/Jenkinsfile`)

| Stage | Tool | Action |
|---|---|---|
| 1 Checkout | Git | Pull source (SCM) |
| 2 Install & Lint | Node.js 22 | `npm ci` + `node --check` syntax validation |
| 3 Gitleaks | gitleaks | Secret/credential leak scan |
| 4 OWASP SCA | dependency-check | npm package vulnerability scan |
| 5 SonarQube SAST | sonar-scanner | Static analysis → project `sample-react-app-api` |
| 6 Quality Gate | SonarQube | Fail/warn on quality threshold |
| 7 Docker Build | BuildKit | Build + push `amitactive2008/sample-react-app-api:<BUILD_NUMBER>` |
| 8 Trivy | trivy | Image CVE scan |
| 9 Trigger CD | Jenkins | Fire `team-a/sample-react-app/api/cd` |

### Client CI (`client/Jenkinsfile`)

| Stage | Tool | Action |
|---|---|---|
| 1 Checkout | Git | Pull source |
| 2 Install & Lint | Node.js | `npm ci` + syntax check |
| 3 Gitleaks | gitleaks | Secret scan |
| 4 Unit Tests | Jest | `npm test -- --coverage` |
| 5 OWASP SCA | dependency-check | npm vulnerability scan |
| 6 SonarQube SAST | sonar-scanner | Static analysis → project `sample-react-app-client` |
| 7 Quality Gate | SonarQube | Quality threshold check |
| 8 Docker Build | BuildKit | Multi-stage build + push `amitactive2008/sample-react-app-client:<BUILD_NUMBER>` |
| 9 Trivy | trivy | Image CVE scan |
| 10 Trigger CD | Jenkins | Fire `team-a/sample-react-app/client/cd` |

### Docker image build (BuildKit)

Both pipelines use Docker Buildx with the in-cluster **BuildKit daemon** (non-TLS):
```sh
docker buildx create \
  --name kind-buildkitd \
  --driver remote \
  tcp://buildkitd.jenkins.svc.cluster.local:1234 \
  --use --bootstrap

docker buildx build --platform linux/amd64 --push \
  -t amitactive2008/sample-react-app-api:<BUILD_NUMBER> \
  -t amitactive2008/sample-react-app-api:latest \
  .
```

DockerHub credentials are read from the `dockerhub` Jenkins credential (username/password).

---

## CD Pipeline

### API CD (`api/Jenkinsfile-cd`)

1. Checkout manifests
2. Verify Vault secret exists (`secret/data/team-a/sample-react-app/api`)
3. `kubectl apply -f kubernetes/` (idempotent — creates MySQL, API, Client, HTTPRoute)
4. `kubectl set image deployment/sample-react-app-api api=amitactive2008/sample-react-app-api:<IMAGE_TAG>`
5. `kubectl rollout status` (waits up to 5 minutes)
6. Smoke test: `wget -qO- http://localhost:5000/live` inside the API pod

### Client CD (`client/Jenkinsfile-cd`)

1. Checkout manifests
2. `kubectl apply -f kubernetes/client/`
3. `kubectl set image deployment/sample-react-app-client client=amitactive2008/sample-react-app-client:<IMAGE_TAG>`
4. `kubectl rollout status`
5. Smoke test: verify Nginx serves `index.html`

---

## Setup

### Prerequisites

- Steps 01–07 complete (cluster, Vault, Keycloak, Jenkins, SonarQube)
- Vault initialized and unsealed (`02-vault/cluster-keys.json` present)

### Step 1 — Vault + CoreDNS + Kubernetes setup

```bash
cd 09-sample-app-react-and-nodejs
chmod +x vault-setup.sh
./vault-setup.sh
```

This script:
- Writes secrets to `secret/data/team-a/sample-react-app/{api,client}`
- Creates Vault policy `team-a-sample-react-app`
- Creates Kubernetes auth role bound to `sample-react-app-backend` ServiceAccount
- Creates K8s Secret `sample-react-app-mysql` (MySQL init credentials)
- Applies `kubernetes/rbac.yaml` (ServiceAccount)
- Adds `sample-react-app.kind.local` to CoreDNS

### Step 2 — DNS entry

```bash
# Add to /etc/hosts
sudo sh -c 'echo "127.0.0.1 sample-react-app.kind.local" >> /etc/hosts'
```

### Step 3 — Jenkins: reload JCasC

After updating `08-jenkins/jenkins-values.yaml`, reload Jenkins to pick up new jobs:

```bash
helm upgrade jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 08-jenkins/jenkins-values.yaml \
  --version 5.9.40

kubectl delete pod jenkins-0 -n jenkins  # force restart to re-apply JCasC
```

Or trigger via Jenkins UI: **Manage Jenkins → Configuration as Code → Reload existing configuration**.

### Step 4 — Run CI pipelines

In Jenkins UI (as `devops-user-1` or local admin):

1. Go to **team-a → Sample React App → api → ci** → **Build Now**
2. Go to **team-a → Sample React App → client → ci** → **Build Now**

Each CI pipeline automatically triggers the corresponding CD pipeline when it completes.

### Step 5 — Direct deploy (skip CI)

To deploy without running CI first:

```bash
# Apply all Kubernetes manifests
kubectl apply -f kubernetes/rbac.yaml -n team-a
kubectl apply -f kubernetes/mysql/    -n team-a
kubectl apply -f kubernetes/api/      -n team-a
kubectl apply -f kubernetes/client/   -n team-a
kubectl apply -f kubernetes/httproute.yaml -n team-a

# Wait for MySQL to be ready (first run only — StatefulSet volume provisioning)
kubectl rollout status statefulset/sample-react-app-mysql -n team-a --timeout=3m

# Watch all pods come up
kubectl get pods -n team-a -w
```

---

## Kubernetes resources

```
team-a namespace:
├── ServiceAccount    sample-react-app-backend    (Vault Agent K8s auth)
├── Secret            sample-react-app-mysql       (MySQL bootstrap creds)
├── StatefulSet       sample-react-app-mysql       (MySQL 8.0, 2Gi PVC)
├── Service           sample-react-app-mysql       (headless)
├── Service           mysql                         (ClusterIP :3306)
├── Deployment        sample-react-app-api          (Node.js + Vault Agent sidecar)
├── Service           api-service                   (ClusterIP :5000)
├── Deployment        sample-react-app-client       (Nginx + React build)
├── Service           sample-react-app-client       (ClusterIP :80)
├── HTTPRoute         sample-react-app              (HTTPS → client)
└── HTTPRoute         sample-react-app-http-redirect (HTTP → 301 HTTPS)
```

---

## Access

| URL | Service | Notes |
|---|---|---|
| https://sample-react-app.kind.local | React frontend | Login: `admin@example.com` / `admin123` |
| https://sample-react-app.kind.local/api/health | API health | Checks DB connection |
| https://sample-react-app.kind.local/api/live | API liveness | Always 200 |

Default seeded user (from `api/seeders/`):
- Email: `admin@example.com`
- Password: `admin123`
- Role: `admin`

---

## Verify

```bash
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.crt

# Frontend loads
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/ | grep -c "DevOps Shack"

# API health (checks DB)
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/api/health

# API liveness
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/api/live

# Vault secrets injected into API pod
kubectl exec -n team-a deployment/sample-react-app-api -c api -- \
  cat /vault/secrets/api.env

rm /tmp/ca.crt
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| API pod stuck in Init | MySQL not ready yet | `kubectl logs -n team-a statefulset/sample-react-app-mysql` |
| API pod CrashLoop | Vault secret missing or auth role not configured | Run `vault-setup.sh`; check `kubectl logs -c vault-agent` |
| Vault Agent fails `permission denied` | Policy not applied | Re-run `vault-setup.sh` step 2 |
| `/api/health` returns 503 | DB connection failed | Check MySQL pod; verify DB_HOST=mysql in Vault secret |
| Jenkins CI fails at Docker stage | BuildKit unreachable | `kubectl get pods -n jenkins -l app=buildkitd` |
| Job `team-a/sample-react-app` not visible | JCasC not reloaded | Helm upgrade + restart Jenkins pod |
| `team-a-user-1` can't see the jobs | RBAC item role not applied | Verify `team-a.*` pattern in jenkins-values.yaml roleBased config |

```bash
# Check Vault Agent logs in API pod
kubectl logs -n team-a deployment/sample-react-app-api -c vault-agent --tail=30

# Check all pods in team-a
kubectl get pods -n team-a

# Describe API deployment
kubectl describe deployment sample-react-app-api -n team-a

# Check Jenkins jobs via API
curl -sf --globoff -u admin:Admin@Jenkins2024! \
  "https://jenkins.kind.local/job/team-a/job/sample-react-app/api/json" \
  | python3 -m json.tool
```
