# 10 — Sample React App (team-b)

Deploys the **same User Management application** as `09-sample-app-react-and-nodejs` but into the **`team-b` namespace** with team-b-specific Docker image tags, Vault secrets, and a separate hostname.

---

## How team-b differs from team-a

| Aspect | team-a (`09-`) | team-b (`10-`) |
|---|---|---|
| Namespace | `team-a` | `team-b` |
| Vault secrets | `secret/data/team-a/sample-react-app/*` | `secret/data/team-b/sample-react-app/*` |
| Docker image tag | `jenkins-build-1`, `latest` | `team-b-1`, `team-b-latest` |
| External URL | `https://sample-react-app.kind.local` | `https://sample-react-app-team-b.kind.local` |
| Jenkins folder | `team-a/sample-react-app/` | `team-b/sample-react-app/` |
| Source code | `09-sample-app-react-and-nodejs/` (local repo) | `amitactive2008/DevSecOps-Mega-Project` (GitHub) |
| MySQL credentials | Separate K8s Secret in `team-a` | Separate K8s Secret in `team-b` |

Everything else is identical: same Express API, same React SPA, same Nginx proxy, same Vault Agent injection pattern.

---

## Architecture

```
Browser
    │  HTTPS  *.kind.local  (cert-manager wildcard)
    ▼
Envoy Gateway  →  sample-react-app-team-b.kind.local
    │
    ▼
[client pod]  Nginx :80  (namespace: team-b)
    │  Proxy /api/* → http://api-service:5000
    ▼
[api pod]  Node.js Express :5000  (namespace: team-b)
    │  Vault Agent sidecar:
    │    reads  secret/data/team-b/sample-react-app/api
    │    writes /vault/secrets/api.env  (DB_HOST, DB_PASSWORD, JWT_SECRET …)
    ▼
MySQL :3306  (StatefulSet: sample-react-app-mysql, namespace: team-b)

Source code (CI checkout):
    github.com/amitactive2008/DevSecOps-Mega-Project  (branch: dev)
    api/   ← Node.js Express
    client/ ← React 19 + Nginx

Docker images (team-b tagged):
    amitactive2008/sample-react-app-api:team-b-<BUILD>
    amitactive2008/sample-react-app-api:team-b-latest
    amitactive2008/sample-react-app-client:team-b-<BUILD>
    amitactive2008/sample-react-app-client:team-b-latest
```

---

## Source code

Checked out from **public GitHub repo** during CI:
```
https://github.com/amitactive2008/DevSecOps-Mega-Project.git  (branch: dev)
```

Structure in that repo:
```
api/        ← Node.js Express backend (identical to 09-sample-app-react-and-nodejs/api/)
client/     ← React frontend + Nginx config (identical to 09-.../client/)
jenkins/    ← Jenkins pipeline utilities
kubernetes/ ← Original K8s manifests (not used here — we use 10-sample-react-app-team-b/kubernetes/)
```

---

## Docker image tags

Each CI build pushes **two tags** per component, both with the `team-b-` prefix:

| Image | Tag (build-specific) | Tag (latest) |
|---|---|---|
| `amitactive2008/sample-react-app-api` | `team-b-<BUILD_NUMBER>` | `team-b-latest` |
| `amitactive2008/sample-react-app-client` | `team-b-<BUILD_NUMBER>` | `team-b-latest` |

Shared DockerHub repo with team-a — differentiated by tag prefix (`team-b-` vs no prefix for team-a).

---

## Vault secrets

| Path | Contents | Used by |
|---|---|---|
| `secret/data/team-b/sample-react-app/api` | `DB_HOST=mysql`, `DB_PORT=3306`, `DB_USER`, `DB_PASSWORD`, `DB_NAME=sample_app_db`, `JWT_SECRET` | API pod (`/vault/secrets/api.env`) |
| `secret/data/team-b/sample-react-app/client` | `REACT_APP_API_URL`, `REACT_APP_ENV` | Reference only |

Vault resources:
- **Policy**: `team-b-sample-react-app` — read `secret/data/team-b/sample-react-app/*`
- **K8s auth role**: `team-b-sample-react-app` → SA `sample-react-app-backend` / `team-b` namespace

---

## Jenkins folder structure

```
team-b/
└── sample-react-app/                ← "Sample React App"
    ├── api/                         ← "API (Node.js)"
    │   ├── ci                       ← API CI (9 stages)
    │   └── cd                       ← API CD (team-b namespace)
    └── client/                      ← "Client (React)"
        ├── ci                       ← Client CI (10 stages)
        └── cd                       ← Client CD (team-b namespace)
```

Access control:
- `devops` group → global admin (all folders)
- `team-b` group → `team-b.*` item role only

---

## CI Pipeline stages

### API CI (`api/Jenkinsfile`)

| Stage | Action |
|---|---|
| 1 Checkout | `git clone https://github.com/amitactive2008/DevSecOps-Mega-Project.git --branch dev` |
| 2 Install | `npm ci` + `node --check` syntax validation |
| 3 Gitleaks | Secret/credential leak scan |
| 4 OWASP SCA | npm package CVE scan |
| 5 SonarQube | Project: `sample-react-app-team-b-api` |
| 6 Quality Gate | SonarQube threshold check |
| 7 Docker Build | `docker buildx build --platform linux/amd64,linux/arm64 --push -t amitactive2008/sample-react-app-api:team-b-<BUILD>` |
| 8 Trivy | Image CVE scan |
| 9 Trigger CD | Fires `team-b/sample-react-app/api/cd` with `IMAGE_TAG=team-b-<BUILD>` |

### Client CI (`client/Jenkinsfile`) — 10 stages

Same as API CI, plus **Stage 4: Unit Tests** (`npm test --coverage`) and SonarQube project `sample-react-app-team-b-client`.

---

## Directory structure

```
10-sample-react-app-team-b/
├── api/
│   ├── Jenkinsfile         ← CI pipeline
│   └── Jenkinsfile-cd      ← CD pipeline (team-b namespace)
├── client/
│   ├── Jenkinsfile         ← CI pipeline
│   └── Jenkinsfile-cd      ← CD pipeline
├── kubernetes/
│   ├── rbac.yaml           ← ServiceAccount: sample-react-app-backend (team-b)
│   ├── httproute.yaml      ← HTTPS sample-react-app-team-b.kind.local + HTTP→301
│   ├── mysql/
│   │   ├── statefulset.yaml
│   │   └── service.yaml    ← ClusterIP 'mysql' (matches DB_HOST=mysql)
│   ├── api/
│   │   ├── deployment.yaml ← Vault Agent annotations → team-b secrets
│   │   └── service.yaml    ← ClusterIP 'api-service' (matches Nginx proxy_pass)
│   └── client/
│       ├── deployment.yaml
│       └── service.yaml
└── vault-setup.sh          ← One-time bootstrap (Vault KV + policy + K8s auth + MySQL Secret + CoreDNS)
```

---

## Setup

### Prerequisites

- Steps 01–09 complete (cluster, cert-manager, Vault, Jenkins, monitoring, team-a running)
- `09-sample-react-app-react-and-nodejs/vault-setup.sh` run (enables KV v2 at secret/)

### Step 1 — Vault + Kubernetes + CoreDNS bootstrap

```bash
cd 10-sample-react-app-team-b
chmod +x vault-setup.sh
./vault-setup.sh
```

Creates:
- `secret/data/team-b/sample-react-app/{api,client}` Vault KV secrets
- Vault policy `team-b-sample-react-app`
- Kubernetes auth role → `sample-react-app-backend` SA / `team-b` namespace
- K8s Secret `sample-react-app-mysql` in `team-b` (MySQL bootstrap)
- ServiceAccount `sample-react-app-backend` in `team-b`
- Adds `sample-react-app-team-b.kind.local` to CoreDNS

### Step 2 — DNS entry

```bash
sudo sh -c 'echo "127.0.0.1 sample-react-app-team-b.kind.local" >> /etc/hosts'
```

### Step 3 — Reload Jenkins JCasC (add team-b jobs)

```bash
helm upgrade jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 08-jenkins/jenkins-values.yaml \
  --version 5.9.40

kubectl delete pod jenkins-0 -n jenkins
kubectl wait pod -n jenkins -l app.kubernetes.io/component=jenkins-controller \
  --for=condition=Ready --timeout=600s
```

Verify:
```bash
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  bash -c "find /var/jenkins_home/jobs/team-b/jobs/sample-react-app -name config.xml | sort"
# Expected: ...api/jobs/ci, ...api/jobs/cd, ...client/jobs/ci, ...client/jobs/cd
```

### Step 4 — Build Docker images via Jenkins buildkitd

```bash
DOCKER_USER=$(kubectl get secret jenkins-credentials -n jenkins \
  -o jsonpath='{.data.DOCKERHUB_USERNAME}' | base64 -d)
DOCKER_PASS=$(kubectl get secret jenkins-credentials -n jenkins \
  -o jsonpath='{.data.DOCKERHUB_PASSWORD}' | base64 -d)

kubectl create secret generic dockerhub-team-b-creds -n jenkins \
  --from-literal=username="$DOCKER_USER" \
  --from-literal=password="$DOCKER_PASS"

# Apply the build job (clones GitHub repo, builds multi-platform, pushes team-b tags)
kubectl apply -f - << 'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: build-team-b-images
  namespace: jenkins
spec:
  backoffLimit: 1
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
              docker buildx create --name tb-builder \
                --driver remote tcp://buildkitd.jenkins.svc.cluster.local:1234 \
                --use --bootstrap
              docker buildx build --platform linux/amd64,linux/arm64 --push \
                -t amitactive2008/sample-react-app-api:team-b-latest \
                -t amitactive2008/sample-react-app-api:team-b-1 \
                /src/api
              docker buildx build --platform linux/amd64,linux/arm64 --push \
                -t amitactive2008/sample-react-app-client:team-b-latest \
                -t amitactive2008/sample-react-app-client:team-b-1 \
                /src/client
              echo "Done — team-b images pushed"
          env:
            - name: DOCKER_USER
              valueFrom:
                secretKeyRef: {name: dockerhub-team-b-creds, key: username}
            - name: DOCKER_PASS
              valueFrom:
                secretKeyRef: {name: dockerhub-team-b-creds, key: password}
          resources:
            limits: {cpu: "2", memory: "1Gi"}
EOF

kubectl logs -n jenkins -l job-name=build-team-b-images -f
kubectl delete job build-team-b-images -n jenkins
kubectl delete secret dockerhub-team-b-creds -n jenkins
```

### Step 5 — Deploy (CD pipeline)

```bash
APP_DIR="10-sample-react-app-team-b"

kubectl apply -f ${APP_DIR}/kubernetes/rbac.yaml     -n team-b
kubectl apply -f ${APP_DIR}/kubernetes/mysql/         -n team-b
kubectl apply -f ${APP_DIR}/kubernetes/api/           -n team-b
kubectl apply -f ${APP_DIR}/kubernetes/client/        -n team-b
kubectl apply -f ${APP_DIR}/kubernetes/httproute.yaml -n team-b

kubectl set image deployment/sample-react-app-api    api=amitactive2008/sample-react-app-api:team-b-1    -n team-b
kubectl set image deployment/sample-react-app-client client=amitactive2008/sample-react-app-client:team-b-1 -n team-b

kubectl rollout status statefulset/sample-react-app-mysql -n team-b --timeout=3m
kubectl rollout status deployment/sample-react-app-client -n team-b --timeout=2m
kubectl rollout status deployment/sample-react-app-api    -n team-b --timeout=5m
```

### Step 6 — Trigger Jenkins CI pipelines (ongoing builds)

In Jenkins UI as `devops-user-1` or `team-b-user-1`:
1. **team-b → Sample React App → api → ci** → **Build Now**
2. **team-b → Sample React App → client → ci** → **Build Now**

CI automatically triggers CD on success.

---

## Access

| URL | Notes |
|---|---|
| `https://sample-react-app-team-b.kind.local` | React SPA (add to `/etc/hosts` first) |
| `https://sample-react-app-team-b.kind.local/api/health` | DB connectivity |
| `https://sample-react-app-team-b.kind.local/api/live` | Always `ALIVE` |

Default login: `admin@example.com` / `admin123` (seeded by migrations)

---

## Verify

```bash
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/ca.crt

# Frontend
curl -sf --cacert /tmp/ca.crt https://sample-react-app-team-b.kind.local/ \
  -o /dev/null -w "HTTP %{http_code}\n"

# API via kubectl exec (no DNS dependency)
kubectl exec -n team-b deployment/sample-react-app-api -c api -- \
  wget -qO- http://localhost:5000/live

kubectl exec -n team-b deployment/sample-react-app-api -c api -- \
  wget -qO- http://localhost:5000/health

# Vault secrets injected
kubectl exec -n team-b deployment/sample-react-app-api -c api -- \
  cat /vault/secrets/api.env | grep -v 'PASSWORD\|SECRET'

# Pods
kubectl get pods -n team-b

rm /tmp/ca.crt
```

---

## Kubernetes resources

```
team-b namespace:
├── ServiceAccount    sample-react-app-backend    ← Vault K8s auth
├── Secret            sample-react-app-mysql       ← MySQL bootstrap creds
├── StatefulSet       sample-react-app-mysql       ← MySQL 8.0, 2Gi PVC
├── Service           sample-react-app-mysql        ← headless
├── Service           mysql                         ← ClusterIP :3306
├── Deployment        sample-react-app-api          ← Node.js + vault-agent (2/2)
├── Service           api-service                   ← ClusterIP :5000
├── Deployment        sample-react-app-client       ← Nginx + React (1/1)
├── Service           sample-react-app-client       ← ClusterIP :80
├── HTTPRoute         sample-react-app-team-b       ← HTTPS → client
└── HTTPRoute         sample-react-app-team-b-http-redirect
```

---

## Current deployment state

| Resource | Image | Tag | Status |
|---|---|---|---|
| `sample-react-app-mysql` | `mysql:8.0` | — | Running 1/1 |
| `sample-react-app-api` | `amitactive2008/sample-react-app-api` | `team-b-1` | Running 2/2 (with vault-agent) |
| `sample-react-app-client` | `amitactive2008/sample-react-app-client` | `team-b-1` | Running 1/1 |

HTTPRoutes: Both `sample-react-app-team-b` and `sample-react-app-team-b-http-redirect` — **Accepted: True**

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| API pod `0/1` — no vault-agent | `kubectl rollout restart deployment/vault-agent-injector -n vault` then delete pods |
| `ImagePullBackOff: no match for platform` | Rebuild with `--platform linux/amd64,linux/arm64` |
| CoreDNS CrashLoop after `health { lameduck 5s }` on one line | Fix Corefile to multi-line `health {\n lameduck 5s\n}` |
| Jenkins team-b jobs missing | Helm upgrade + `kubectl delete pod jenkins-0 -n jenkins` |
| Vault Agent: `permission denied` on `team-b/sample-react-app/*` | Re-run `vault-setup.sh` step 2 (policy) and step 3 (K8s auth role) |

```bash
# All team-b pods
kubectl get pods -n team-b

# Vault Agent logs
kubectl logs -n team-b deployment/sample-react-app-api -c vault-agent --tail=30

# CoreDNS fix (if broken after corefile update)
kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}' | head -5
```
