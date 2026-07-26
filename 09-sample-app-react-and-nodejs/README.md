# 09 — Sample React + Node.js Application

A full-stack **User Management** web application demonstrating a complete DevSecOps pipeline on the kind cluster.

| Layer | Technology |
|---|---|
| Frontend | React 19, React Router v7, Axios, Nginx (multi-stage Docker) |
| Backend | Node.js 22, Express 4, Sequelize ORM + mysql2 |
| Database | MySQL 8.0 (StatefulSet, 2Gi PVC) |
| Auth | JWT (`jsonwebtoken`) + password hashing (`bcryptjs`) |
| Secrets | HashiCorp Vault — Vault Agent sidecar injection |
| CI/CD | Jenkins (role-strategy folder RBAC) + SonarQube |
| Container | Docker Buildx multi-platform builds via in-cluster BuildKit |

---

## Architecture

```
Browser
    │  HTTPS  (cert-manager wildcard *.kind.local cert)
    ▼
Envoy Gateway  →  sample-react-app.kind.local
    │
    ▼
[client pod]  Nginx :80  (namespace: team-a)
    │  Static:  serves /usr/share/nginx/html (React build)
    │  Proxy:   /api/* → http://api-service:5000
    ▼
[api pod]  Node.js Express :5000  (namespace: team-a)
    │  vault-agent sidecar reads:
    │    secret/data/team-a/sample-react-app/api
    │    renders → /vault/secrets/api.env
    │    api container sources this file at startup
    ▼
MySQL :3306  (StatefulSet: sample-react-app-mysql, namespace: team-a)
```

### Nginx API proxy

`client/default.conf` is baked into the Docker image at build time:

```nginx
location /api/ {
  proxy_pass http://api-service:5000;   # Kubernetes ClusterIP (same namespace)
}
location / {
  try_files $uri /index.html;           # React Router SPA fallback
}
```

The React frontend calls `/api/auth/login`, `/api/users`, etc. with relative paths. Nginx transparently forwards them to the `api-service` ClusterIP inside `team-a`. No CORS configuration, no build-time API URL injection needed.

---

## Directory structure

```
09-sample-app-react-and-nodejs/
├── api/                         ← Node.js Express backend
│   ├── Jenkinsfile              ← CI pipeline (9 stages)
│   ├── Jenkinsfile-cd           ← CD pipeline (deploy to team-a)
│   ├── Dockerfile               ← node:22-alpine single-stage
│   ├── server.js / app.js       ← Entry point + Express setup
│   ├── controllers/             ← authController, userController
│   ├── routes/                  ← /api/auth, /api/users
│   ├── middleware/              ← JWT verifyToken, isAdmin, role()
│   ├── models/                  ← Sequelize model + mysql2 pool
│   ├── migrations/              ← DB schema (initial + add phone)
│   └── seeders/                 ← Admin user seed
├── client/                      ← React frontend
│   ├── Jenkinsfile              ← CI pipeline (10 stages)
│   ├── Jenkinsfile-cd           ← CD pipeline (deploy to team-a)
│   ├── Dockerfile               ← Multi-stage: node:18-alpine → nginx:alpine
│   ├── default.conf             ← Nginx config (API proxy + SPA fallback)
│   └── src/                     ← React app (Login, Register, Dashboard)
├── kubernetes/                  ← All K8s manifests
│   ├── rbac.yaml                ← ServiceAccount: sample-react-app-backend
│   ├── httproute.yaml           ← HTTPRoute: sample-react-app.kind.local
│   ├── mysql/
│   │   ├── statefulset.yaml     ← MySQL 8.0 StatefulSet + 2Gi PVC
│   │   └── service.yaml         ← Headless + ClusterIP 'mysql'
│   ├── api/
│   │   ├── deployment.yaml      ← Node.js + Vault Agent sidecar annotations
│   │   └── service.yaml         ← ClusterIP 'api-service' :5000
│   └── client/
│       ├── deployment.yaml      ← Nginx + React build
│       └── service.yaml         ← ClusterIP 'sample-react-app-client' :80
└── vault-setup.sh               ← One-time Vault + K8s bootstrap script
```

---

## API endpoints

| Method | Path | Auth | Description |
|---|---|---|---|
| `POST` | `/api/auth/register` | None | Create account |
| `POST` | `/api/auth/login` | None | Returns signed JWT (1h) |
| `GET` | `/api/users` | JWT | List all users |
| `POST` | `/api/users` | JWT | Create user |
| `PUT` | `/api/users/:id` | JWT + `admin` role | Update user |
| `DELETE` | `/api/users/:id` | JWT + `admin` role | Delete user |
| `GET` | `/health` | None | Checks MySQL connection via Sequelize |
| `GET` | `/live` | None | Always `ALIVE` — Kubernetes liveness |

---

## Vault secrets

Stored in Vault KV v2. The API pod uses **Vault Agent sidecar injection** to receive these at runtime — no secrets baked into the Docker image.

| Vault path | Contents | Used by |
|---|---|---|
| `secret/data/team-a/sample-react-app/api` | `DB_HOST=mysql`, `DB_PORT=3306`, `DB_USER`, `DB_PASSWORD`, `DB_NAME=sample_app_db`, `JWT_SECRET` | API container (`/vault/secrets/api.env`) |
| `secret/data/team-a/sample-react-app/client` | `REACT_APP_API_URL`, `REACT_APP_ENV` | Reference only — client uses K8s service DNS at runtime |

### How Vault Agent injection works

```
API pod starts
    │
    ├── Init container: vault-agent-init
    │     Authenticates to Vault using K8s ServiceAccount token
    │     Reads secret/data/team-a/sample-react-app/api
    │     Renders /vault/secrets/api.env:
    │       export DB_HOST="mysql"
    │       export DB_PORT="3306"
    │       export DB_USER="appuser"
    │       export DB_PASSWORD="..."
    │       export DB_NAME="sample_app_db"
    │       export JWT_SECRET="..."
    │       export NODE_ENV="production"
    │
    └── Main container: api
          source /vault/secrets/api.env    ← env vars loaded
          node scripts/migrate.js           ← run DB migrations + seed
          node server.js                    ← start Express server
```

Vault resources (created by `vault-setup.sh`):
- **Policy** `team-a-sample-react-app` — read access to `secret/data/team-a/sample-react-app/*`
- **K8s auth role** `team-a-sample-react-app` — bound to ServiceAccount `sample-react-app-backend` in `team-a` namespace
- **K8s Secret** `sample-react-app-mysql` — MySQL init credentials (not Vault; used by StatefulSet bootstrap only)

---

## Jenkins folder structure

```
team-a/
└── sample-react-app/           ← Folder: "Sample React App"
    ├── api/                    ← Folder: "API (Node.js)"
    │   ├── ci                  ← Pipeline: API CI (9 stages)
    │   └── cd                  ← Pipeline: API CD (deploys to team-a)
    └── client/                 ← Folder: "Client (React)"
        ├── ci                  ← Pipeline: Client CI (10 stages)
        └── cd                  ← Pipeline: Client CD (deploys to team-a)
```

Access control (Role Strategy Plugin):
| Keycloak group | Jenkins access |
|---|---|
| `devops` | Global admin — can view and trigger all jobs |
| `team-a` | `team-a.*` item role — can view and trigger only team-a jobs |

---

## CI Pipeline stages

### API CI — `api/Jenkinsfile`

| Stage | Tool | What it does |
|---|---|---|
| 1 Checkout | Git | `checkout scm` — pulls from configured SCM |
| 2 Install & Lint | nodejs container | `npm ci` + `node --check` syntax on all `.js` files |
| 3 Gitleaks | gitleaks container | Scans source for leaked secrets/credentials |
| 4 OWASP SCA | dependency-check | CVE scan on `npm` packages → `reports/` |
| 5 SonarQube SAST | sonar container | Static analysis → project `sample-react-app-api` |
| 6 Quality Gate | SonarQube | Blocks (warn in demo) if threshold not met |
| 7 Docker Build & Push | docker-cli + BuildKit | `docker buildx build --platform linux/amd64,linux/arm64` → DockerHub |
| 8 Trivy Scan | trivy container | Image CVE scan → `trivy-api-report.json` |
| 9 Trigger CD | Jenkins | Fires `team-a/sample-react-app/api/cd` with `IMAGE_TAG=<BUILD_NUMBER>` |

### Client CI — `client/Jenkinsfile`

| Stage | Tool | What it does |
|---|---|---|
| 1 Checkout | Git | `checkout scm` |
| 2 Install & Lint | nodejs | `npm ci` + syntax check |
| 3 Gitleaks | gitleaks | Secret scan |
| 4 Unit Tests | nodejs | `npm test -- --coverage --watchAll=false --ci` |
| 5 OWASP SCA | dependency-check | npm CVE scan |
| 6 SonarQube SAST | sonar | Static analysis → project `sample-react-app-client` |
| 7 Quality Gate | SonarQube | Quality threshold check |
| 8 Docker Build & Push | docker-cli + BuildKit | Multi-stage build (node→nginx) → DockerHub |
| 9 Trivy Scan | trivy | Image scan |
| 10 Trigger CD | Jenkins | Fires `team-a/sample-react-app/client/cd` |

### Docker image build — multi-platform (IMPORTANT)

Both pipelines build for **`linux/amd64,linux/arm64`** using Docker Buildx with the in-cluster BuildKit daemon:

```bash
# Create Buildx builder pointing to Jenkins' buildkitd (non-TLS)
docker buildx create \
  --name kind-buildkitd \
  --driver remote \
  tcp://buildkitd.jenkins.svc.cluster.local:1234 \
  --use --bootstrap

# Build and push multi-platform image in one step
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --push \
  -t amitactive2008/sample-react-app-api:<BUILD_NUMBER> \
  -t amitactive2008/sample-react-app-api:latest \
  .
```

> **Why multi-platform?** The kind cluster runs on Apple Silicon (arm64). Building for only `linux/amd64` causes `ImagePullBackOff` with `no match for platform in manifest: not found`. Always build for both platforms.

DockerHub images:
- `amitactive2008/sample-react-app-api` — Node.js Express API
- `amitactive2008/sample-react-app-client` — Nginx + React SPA

---

## CD Pipeline

### API CD — `api/Jenkinsfile-cd`

Runs inside the jenkins ServiceAccount pod (which has cluster RBAC):

1. **Checkout** — pull K8s manifests from SCM
2. **Vault Verification** — confirm `secret/data/team-a/sample-react-app/api` exists
3. **Apply Manifests** — `kubectl apply -f kubernetes/` in `team-a` (idempotent)
4. **Update Image** — `kubectl set image deployment/sample-react-app-api api=...<IMAGE_TAG>`
5. **Rollout Wait** — `kubectl rollout status --timeout=5m`
6. **Smoke Test** — `wget http://localhost:5000/live` and `/health` inside the API pod

### Client CD — `client/Jenkinsfile-cd`

1. **Checkout**
2. **Apply** — `kubectl apply -f kubernetes/client/`
3. **Update Image** — `kubectl set image deployment/sample-react-app-client client=...<IMAGE_TAG>`
4. **Rollout Wait**
5. **Smoke Test** — verify Nginx serves `index.html`

---

## Setup

### Prerequisites

- Steps 01–08 complete (cluster, cert-manager, Vault, Keycloak, Jenkins, SonarQube, Monitoring)
- Vault initialized and **unsealed** (`02-vault/cluster-keys.json` present)
- `08-jenkins/` setup complete (Jenkins running, buildkitd deployed)

### Step 1 — Run vault-setup.sh (one-time)

```bash
cd 09-sample-app-react-and-nodejs
chmod +x vault-setup.sh
./vault-setup.sh
```

This idempotent script does:
- Writes secrets to `secret/data/team-a/sample-react-app/{api,client}`
- Creates Vault policy `team-a-sample-react-app`
- Enables and configures Kubernetes auth method
- Creates K8s auth role bound to `sample-react-app-backend` SA / `team-a` namespace
- Creates K8s Secret `sample-react-app-mysql` in `team-a` (MySQL StatefulSet bootstrap)
- Applies `kubernetes/rbac.yaml` (ServiceAccount)
- Updates CoreDNS with `sample-react-app.kind.local → Envoy Gateway`

### Step 2 — DNS entry

```bash
sudo sh -c 'echo "127.0.0.1 sample-react-app.kind.local" >> /etc/hosts'
```

### Step 3 — Add Jenkins jobs (JCasC)

The `08-jenkins/jenkins-values.yaml` already contains the job definitions. Apply via Helm upgrade:

```bash
helm upgrade jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 08-jenkins/jenkins-values.yaml \
  --version 5.9.40

# Restart Jenkins to reload JCasC
kubectl delete pod jenkins-0 -n jenkins
kubectl wait pod -n jenkins -l app.kubernetes.io/component=jenkins-controller \
  --for=condition=Ready --timeout=600s
```

Verify jobs exist on disk:

```bash
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  find /var/jenkins_home/jobs/team-a/jobs/sample-react-app -name config.xml \
  | sed 's|/var/jenkins_home/jobs/||;s|/config.xml||' | sort
```

Expected output:
```
team-a/jobs/sample-react-app
team-a/jobs/sample-react-app/jobs/api
team-a/jobs/sample-react-app/jobs/api/jobs/cd
team-a/jobs/sample-react-app/jobs/api/jobs/ci
team-a/jobs/sample-react-app/jobs/client
team-a/jobs/sample-react-app/jobs/client/jobs/cd
team-a/jobs/sample-react-app/jobs/client/jobs/ci
```

### Step 4 — Build Docker images via Jenkins infrastructure

Since the CI pipeline requires the source code in a Git repository accessible from the cluster, images can be built manually using the same Jenkins buildkitd infrastructure:

```bash
# Read DockerHub credentials from Jenkins K8s Secret
DOCKER_USER=$(kubectl get secret jenkins-credentials -n jenkins \
  -o jsonpath='{.data.DOCKERHUB_USERNAME}' | base64 -d)
DOCKER_PASS=$(kubectl get secret jenkins-credentials -n jenkins \
  -o jsonpath='{.data.DOCKERHUB_PASSWORD}' | base64 -d)

# Create temp secret for the build job
kubectl create secret generic dockerhub-build-creds \
  --namespace jenkins \
  --from-literal=username="$DOCKER_USER" \
  --from-literal=password="$DOCKER_PASS"

# Run the build job (clones source + builds via buildkitd + pushes to DockerHub)
# See: kubernetes/build-job.yaml or use the inline Job below
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: build-sample-react-app
  namespace: jenkins
spec:
  backoffLimit: 2
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: builder
          image: docker:27-cli
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -e
              mkdir -p /root/.docker
              echo "{\"auths\":{\"https://index.docker.io/v1/\":{\"username\":\"$DOCKER_USER\",\"password\":\"$DOCKER_PASS\"}}}" > /root/.docker/config.json
              apk add --no-cache git
              git clone --depth=1 --branch dev \
                https://github.com/amitactive2008/DevSecOps-Mega-Project.git /src
              docker buildx create --name kb --driver remote \
                tcp://buildkitd.jenkins.svc.cluster.local:1234 --use --bootstrap
              docker buildx build --platform linux/amd64,linux/arm64 --push \
                -t amitactive2008/sample-react-app-api:latest \
                -t amitactive2008/sample-react-app-api:jenkins-build-1 /src/api
              docker buildx build --platform linux/amd64,linux/arm64 --push \
                -t amitactive2008/sample-react-app-client:latest \
                -t amitactive2008/sample-react-app-client:jenkins-build-1 /src/client
          env:
            - name: DOCKER_USER
              valueFrom:
                secretKeyRef: {name: dockerhub-build-creds, key: username}
            - name: DOCKER_PASS
              valueFrom:
                secretKeyRef: {name: dockerhub-build-creds, key: password}
          resources:
            limits: {cpu: "2", memory: "1Gi"}
EOF

# Stream build logs
kubectl logs -n jenkins -l job-name=build-sample-react-app -f

# Cleanup after successful build
kubectl delete job build-sample-react-app -n jenkins
kubectl delete secret dockerhub-build-creds -n jenkins
```

### Step 5 — Deploy (CD pipeline)

Apply all Kubernetes manifests (what the Jenkins CD pipeline does):

```bash
APP_DIR="09-sample-app-react-and-nodejs"

kubectl apply -f ${APP_DIR}/kubernetes/rbac.yaml        -n team-a
kubectl apply -f ${APP_DIR}/kubernetes/mysql/            -n team-a
kubectl apply -f ${APP_DIR}/kubernetes/api/              -n team-a
kubectl apply -f ${APP_DIR}/kubernetes/client/           -n team-a
kubectl apply -f ${APP_DIR}/kubernetes/httproute.yaml    -n team-a

# Set image tag (use jenkins-build-1 or your own build number)
kubectl set image deployment/sample-react-app-api \
  api=amitactive2008/sample-react-app-api:jenkins-build-1 -n team-a
kubectl set image deployment/sample-react-app-client \
  client=amitactive2008/sample-react-app-client:jenkins-build-1 -n team-a

# Wait for MySQL (slow on first run — PVC provisioning)
kubectl rollout status statefulset/sample-react-app-mysql -n team-a --timeout=3m

# Wait for deployments
kubectl rollout status deployment/sample-react-app-client -n team-a --timeout=2m
kubectl rollout status deployment/sample-react-app-api    -n team-a --timeout=5m
```

### Step 6 — Trigger Jenkins CI pipelines (for future builds)

Once source code is pushed to a Git repository, trigger from Jenkins UI:

1. Log in as `devops-user-1` (Keycloak) or local `admin`
2. Navigate to **team-a → Sample React App → api → ci** → **Build Now**
3. Navigate to **team-a → Sample React App → client → ci** → **Build Now**

Each CI pipeline automatically triggers the CD pipeline on success.

---

## Kubernetes resources

```
team-a namespace:
├── ServiceAccount    sample-react-app-backend    ← Vault Agent K8s auth identity
├── Secret            sample-react-app-mysql       ← MySQL bootstrap (root + app user creds)
├── StatefulSet       sample-react-app-mysql       ← MySQL 8.0, 1 replica, 2Gi PVC
├── Service           sample-react-app-mysql        ← headless (StatefulSet DNS)
├── Service           mysql                         ← ClusterIP :3306 (DB_HOST=mysql)
├── Deployment        sample-react-app-api          ← Node.js Express + vault-agent sidecar (2/2)
├── Service           api-service                   ← ClusterIP :5000 (Nginx proxy_pass target)
├── Deployment        sample-react-app-client       ← Nginx + React build (1/1)
├── Service           sample-react-app-client       ← ClusterIP :80 (HTTPRoute backend)
├── HTTPRoute         sample-react-app              ← HTTPS sample-react-app.kind.local → client:80
└── HTTPRoute         sample-react-app-http-redirect ← HTTP → 301 HTTPS
```

### Key service name decisions

| Service name | Why this exact name |
|---|---|
| `api-service` | Matches `proxy_pass http://api-service:5000;` hardcoded in `client/default.conf` — changing this would require rebuilding the client image |
| `mysql` | Matches `DB_HOST=mysql` stored in Vault secret — K8s cluster DNS resolves `mysql.team-a.svc.cluster.local` |

---

## Access

| URL | What | Default credentials |
|---|---|---|
| `https://sample-react-app.kind.local` | React SPA login page | `admin@example.com` / `admin123` |
| `https://sample-react-app.kind.local/api/health` | API → MySQL connectivity | `OK` when DB is ready |
| `https://sample-react-app.kind.local/api/live` | API liveness | `ALIVE` always |

---

## Verify

```bash
# Extract cert-manager CA for curl
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.crt

# Frontend HTTP 200
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/ \
  -o /dev/null -w "HTTP %{http_code}\n"

# API liveness
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/api/live

# API DB health
curl -sf --cacert /tmp/ca.crt https://sample-react-app.kind.local/api/health

# JWT login
curl -sf --cacert /tmp/ca.crt -X POST \
  https://sample-react-app.kind.local/api/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"admin@example.com","password":"admin123"}' \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('token:', d['token'][:40]+'...')"

# HTTP → HTTPS redirect (expect 301)
curl -sf --cacert /tmp/ca.crt http://sample-react-app.kind.local/ \
  -o /dev/null -w "HTTP %{http_code}\n"

# Vault secrets injected into API pod (redact sensitive values)
kubectl exec -n team-a deployment/sample-react-app-api -c api -- \
  cat /vault/secrets/api.env | grep -v 'PASSWORD\|SECRET'

rm /tmp/ca.crt
```

---

## Troubleshooting

### Common issues

| Symptom | Root cause | Fix |
|---|---|---|
| API pods `0/1` (no vault-agent sidecar) | Vault Agent Injector TLS cert stale — webhook silently skipped (`failurePolicy: Ignore`) | `kubectl rollout restart deployment/vault-agent-injector -n vault`; then `kubectl delete pod -n team-a -l app=sample-react-app-api` |
| API pod `ImagePullBackOff: no match for platform in manifest` | Image built for wrong arch (e.g., amd64-only on ARM64 cluster) | Rebuild with `--platform linux/amd64,linux/arm64` |
| API pod `CrashLoopBackOff: can't open /vault/secrets/api.env` | Vault Agent not yet injected OR Vault auth role misconfigured | 1) Check vault-agent sidecar present (`kubectl get pod -o wide`); 2) Re-run `vault-setup.sh` |
| `/api/health` returns `503` | MySQL not ready or wrong credentials | Check `kubectl logs -n team-a statefulset/sample-react-app-mysql`; verify Vault secret `DB_HOST=mysql` |
| API pod stuck in `Init:0/2` | MySQL not ready yet (`wait-for-mysql` init container looping) | Wait — MySQL StatefulSet can take 60–90s on first PVC provisioning |
| Jenkins jobs not visible in UI | JCasC not reloaded after Helm upgrade | `kubectl delete pod jenkins-0 -n jenkins` to force JCasC re-apply |
| `team-a-user-1` sees team-b jobs | Role Strategy RBAC misconfigured | Verify `team-a.*` pattern in `08-jenkins/jenkins-values.yaml` roleBased items |
| Docker build fails: `buildkitd connection refused` | buildkitd pod not running in jenkins namespace | `kubectl get pods -n jenkins -l app=buildkitd` |

### Vault Agent Injector restart (most common fix)

The Vault Agent Injector webhook uses TLS for admission webhooks. After cluster restarts or long uptimes, the TLS handshake can fail silently (`failurePolicy: Ignore`), causing pods to be created **without** the vault-agent sidecar. Fix:

```bash
# 1. Restart the injector (regenerates TLS cert)
kubectl rollout restart deployment/vault-agent-injector -n vault
kubectl rollout status deployment/vault-agent-injector -n vault

# 2. Force new pods (so the refreshed webhook fires on admission)
kubectl delete pod -n team-a -l app=sample-react-app-api

# 3. Verify sidecar is injected (should show 2/2)
kubectl get pods -n team-a -l app=sample-react-app-api
```

### Diagnostic commands

```bash
# All team-a pods at a glance
kubectl get pods -n team-a

# API pod containers (should be: wait-for-mysql | api vault-agent)
kubectl get pod -n team-a -l app=sample-react-app-api \
  -o jsonpath='{.items[0].spec.initContainers[*].name} | {.items[0].spec.containers[*].name}'

# Vault Agent logs (token renewal, secret fetch)
kubectl logs -n team-a deployment/sample-react-app-api -c vault-agent --tail=40

# API container logs (Node.js startup, migration, errors)
kubectl logs -n team-a deployment/sample-react-app-api -c api --tail=40

# MySQL logs
kubectl logs -n team-a statefulset/sample-react-app-mysql --tail=20

# Injector webhook TLS status
kubectl logs -n vault deployment/vault-agent-injector --tail=20 | grep -E "error|Error|TLS"

# Vault secret verification
kubectl exec -n vault vault-0 -- \
  sh -c "VAULT_ADDR=http://vault-active.vault.svc.cluster.local:8200 \
    VAULT_TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token) \
    vault kv get secret/team-a/sample-react-app/api" 2>/dev/null

# Jenkins job structure on disk
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  find /var/jenkins_home/jobs/team-a/jobs/sample-react-app -name config.xml \
  | sed 's|/var/jenkins_home/jobs/||;s|/config.xml||' | sort
```

---

## Database migrations

Sequelize CLI migrations run automatically at API startup (via `scripts/migrate.js`):

```
20260115110337-initial-schema.js     ← creates users table
20260722093000-add-phone-to-users.js ← adds phone_number column
```

Default seeded user (`seeders/20260116061200-seed-admin-user.js`):
- Email: `admin@example.com`
- Password: `admin123` (bcrypt-hashed)
- Role: `admin`

To run migrations manually:
```bash
kubectl exec -n team-a deployment/sample-react-app-api -c api -- \
  sh -c "source /vault/secrets/api.env && npx sequelize-cli db:migrate"
```

---

## Current deployment state

| Resource | Status | Image |
|---|---|---|
| `sample-react-app-mysql` StatefulSet | Running (1/1) | `mysql:8.0` |
| `sample-react-app-api` Deployment | Running (2/2 with vault-agent) | `amitactive2008/sample-react-app-api:jenkins-build-1` |
| `sample-react-app-client` Deployment | Running (1/1) | `amitactive2008/sample-react-app-client:jenkins-build-1` |
| HTTPRoute `sample-react-app.kind.local` | Accepted | via Envoy Gateway |

Built with Jenkins buildkitd (multi-platform `linux/amd64,linux/arm64`):
- `amitactive2008/sample-react-app-api:jenkins-build-1`
- `amitactive2008/sample-react-app-client:jenkins-build-1`
