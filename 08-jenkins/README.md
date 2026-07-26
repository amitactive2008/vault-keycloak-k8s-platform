# 08 — Jenkins + SonarQube

CI/CD platform and code quality gateway on the kind cluster, authenticated via **Keycloak** with folder-based RBAC in Jenkins and group-based project access in SonarQube.

---

## Configuration split — why it matters

Jenkins configuration is intentionally split into **two separate files** with different update workflows:

| File | What it contains | How to update | Restart required? |
|---|---|---|---|
| `jenkins-values.yaml` | Security realm (OIC/Keycloak), authorization (role-strategy), Kubernetes cloud, plugins, credentials | `helm upgrade` + pod restart | **Yes** — but these rarely change |
| **`jenkins-jobs.yaml`** | All folder and pipeline job definitions | `kubectl apply` OR `./reload-jobs.sh` | **No** — sidecar hot-reloads in ~15 s |

### How hot-reload works

The Jenkins pod runs two containers:
- `jenkins` — the main server
- `config-reload` — a sidecar (`kiwigrid/k8s-sidecar`) that watches Kubernetes

```
Edit jenkins-jobs.yaml
        │
        ▼
kubectl apply -f jenkins-jobs.yaml
        │  (updates ConfigMap with label: jenkins-jenkins-config=true)
        ▼
config-reload sidecar detects ConfigMap change
        │  copies jobs.yaml → /var/jenkins_home/casc_configs/jobs.yaml
        │  POSTs → http://localhost:8080/reload-configuration-as-code/
        ▼
Jenkins reloads JCasC in-place
        │  creates/updates folder and job definitions
        ▼
Done in ~15 seconds — NO RESTART ✓
```

### When to use each update method

```bash
# Job added / modified / deleted → NO restart
vim 08-jenkins/jenkins-jobs.yaml
kubectl apply -f 08-jenkins/jenkins-jobs.yaml
# OR: cd 08-jenkins && ./reload-jobs.sh [--wait]

# Security, auth, plugins changed → restart required (rarely)
vim 08-jenkins/jenkins-values.yaml
helm upgrade jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 08-jenkins/jenkins-values.yaml \
  --version 5.9.40
kubectl delete pod jenkins-0 -n jenkins
```

---

## Architecture

```
Browser
    │  HTTPS (cert-manager wildcard cert)
    ▼
Envoy Gateway (native-gateway)
    ├── jenkins.kind.local      ──► jenkins:8080    (NS: jenkins)
    └── sonarqube.kind.local    ──► sonarqube-sonarqube:9000  (NS: sonarqube)

Jenkins (2.568.1-lts)
    │  OIDC auth callback
    ▼
Keycloak (kind realm, jenkins OIDC client)
    │  groups claim: devops, team-a, team-b
    └── Role Strategy Plugin
        ├── global role: devops → Overall/Administer
        ├── item role:  team-a → team-a.* folders/jobs
        └── item role:  team-b → team-b.* folders/jobs

SonarQube (2026.3.1 Community)
    │  OIDC auth (sonar-auth-oidc plugin)
    ▼
Keycloak (kind realm, sonarqube OIDC client)
    │  groups sync
    └── group permissions
        ├── devops  → global admin
        ├── team-a  → react-app-team-a project
        └── team-b  → react-app-team-b project

Jenkins Agent pods (ephemeral, Kubernetes plugin)
    ├── jnlp         (Jenkins agent)
    ├── nodejs       (node:latest — compile + test)
    ├── sonar        (sonarsource/sonar-scanner-cli — SAST)
    ├── docker-cli   (docker build via buildkitd)
    ├── trivy        (image scanning)
    ├── gitleaks     (secret scanning)
    ├── dependency-check (OWASP SCA)
    └── kubectl      (CD deployments)

BuildKit daemon (buildkitd, non-TLS, namespace: jenkins)
    └── Handles Docker image builds from agent pods
```

---

## Components

| Component | Chart | App version | Release | Namespace |
|---|---|---|---|---|
| Jenkins | `jenkins/jenkins` | 2.568.1-lts | `jenkins` | `jenkins` |
| SonarQube Community | `sonarqube/sonarqube` | 2026.3.1 | `sonarqube` | `sonarqube` |
| BuildKit daemon | raw manifest | `moby/buildkit:master-rootless` | — | `jenkins` |

### Kubernetes resources

| Kind | Name | Purpose |
|---|---|---|
| `Deployment` | `jenkins` | Jenkins controller, 10Gi PVC |
| `Deployment` | `sonarqube-sonarqube` | SonarQube, 10Gi PVC |
| `Deployment` | `buildkitd` | Rootless BuildKit for Docker builds |
| `ClusterRole` | `jenkins-agent-runner` | Agent pod lifecycle management |
| `ClusterRole` | `jenkins-deploy-local` | CD pipeline cluster deployments |
| `PVC` | `dependency-check-data` | OWASP dependency-check NVD cache |
| `Secret` | `buildkit-client-certs` | Stub (TLS-less local mode) |
| `HTTPRoute` | `jenkins` / `sonarqube` | HTTPS external access |

---

## Folder structure

```
Jenkins
├── devops/
│   ├── k8s/                ← Kubernetes cluster management
│   ├── terraform-module/   ← Terraform module pipelines
│   ├── terragrunt/         ← Terragrunt deployment pipelines
│   ├── vault/              ← Vault management pipelines
│   └── keycloak/           ← Keycloak IAM pipelines
├── team-a/
│   ├── ci/
│   │   └── react-app       ← React frontend CI (client/Jenkinsfile)
│   └── cd/
│       └── react-app       ← React frontend CD (jenkins/Jenkinsfile-cd-local)
└── team-b/
    ├── ci/
    │   └── react-app
    └── cd/
        └── react-app
```

---

## Access matrix

### Jenkins

| Keycloak group | Jenkins access |
|---|---|
| `devops` | Global admin — all folders and jobs |
| `team-a` | `team-a/ci/react-app` + `team-a/cd/react-app` only |
| `team-b` | `team-b/ci/react-app` + `team-b/cd/react-app` only |

### SonarQube

| Keycloak group | SonarQube access |
|---|---|
| `devops` | Global admin — all projects |
| `team-a` | `react-app-team-a` project only |
| `team-b` | `react-app-team-b` project only |

---

## Installation

### Step 1 — Add DNS entries

```bash
sudo sh -c 'echo "127.0.0.1 jenkins.kind.local sonarqube.kind.local" >> /etc/hosts'
```

### Step 2 — Fill in real credentials (optional)

Copy and edit the credentials file:

```bash
cp 08-jenkins/setup/credentials-template.yaml 08-jenkins/setup/credentials.yaml
# Edit: DOCKERHUB_USERNAME, DOCKERHUB_PASSWORD, NVD_API_KEY
```

### Step 3 — Run setup.sh

```bash
cd 08-jenkins
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — safe to re-run. It:
1. Updates CoreDNS with `jenkins.kind.local` + `sonarqube.kind.local`
2. Creates Keycloak OIDC clients (`jenkins`, `sonarqube`) with groups mapper
3. Copies cert-manager CA cert to `sonarqube` namespace for HTTPS trust
4. Applies namespace/RBAC/buildkitd manifests from `setup/`
5. Applies `jenkins-credentials` Secret
6. Helm install/upgrade SonarQube `2026.3.1`
7. Helm install/upgrade Jenkins `5.9.40`
8. Applies HTTPRoutes
9. Waits for readiness (up to 10 minutes for plugin downloads)
10. Configures SonarQube via API: OIDC, groups, projects, permissions
11. Generates SonarQube analysis token → stored as `sonarqube-token` Secret in `jenkins` namespace

### Step 4 — Apply job definitions (NO restart needed)

Job definitions are stored in `jenkins-jobs.yaml` (separate from Helm values) and applied independently:

```bash
kubectl apply -f 08-jenkins/jenkins-jobs.yaml
```

The `config-reload` sidecar detects the ConfigMap change and reloads JCasC in ~15 seconds.  
All folders and pipeline jobs appear in Jenkins without any pod restart.

---

## Managing jobs (no restart workflow)

This is the everyday workflow for adding, modifying, or removing Jenkins jobs:

```bash
# 1. Edit job definitions
vim 08-jenkins/jenkins-jobs.yaml

# 2. Apply — sidecar auto-reloads JCasC within 15 seconds
kubectl apply -f 08-jenkins/jenkins-jobs.yaml

# OR use the helper script (validates YAML, shows job list after reload)
cd 08-jenkins && ./reload-jobs.sh

# To wait for confirmation the reload completed:
./reload-jobs.sh --wait
```

### What triggers each update method

| Change type | File to edit | Update command | Restart? |
|---|---|---|---|
| Add/modify/delete a job or folder | `jenkins-jobs.yaml` | `kubectl apply` | No |
| Change security/auth (OIC config) | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Add/remove a plugin | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Change Kubernetes cloud config | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Change credentials/SonarQube config | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |

---

## Access

| Service | URL | Local admin |
|---|---|---|
| Jenkins | https://jenkins.kind.local | `admin` / `Admin@Jenkins2024!` |
| SonarQube | https://sonarqube.kind.local | `admin` / `admin` |

### Jenkins SSO login
1. Open `https://jenkins.kind.local`
2. Click **Sign in with Keycloak**
3. Log in with a Keycloak user

### SonarQube SSO login
1. Open `https://sonarqube.kind.local`
2. Click **Log in with OpenID Connect** (after OIDC plugin is loaded)
3. Log in with a Keycloak user

### Test users (Keycloak password: `password`)

| Username | Group | Jenkins | SonarQube |
|---|---|---|---|
| `devops-user-1` | devops | Admin (all) | Admin (all) |
| `team-a-user-1` | team-a | team-a folder only | react-app-team-a only |
| `team-b-user-1` | team-b | team-b folder only | react-app-team-b only |

---

## Verify

```bash
# All pods running
kubectl get pods -n jenkins
kubectl get pods -n sonarqube

# HTTPRoutes accepted
kubectl get httproute -n jenkins
kubectl get httproute -n sonarqube

# Jenkins health
curl -sf https://jenkins.kind.local/login | grep -c "Jenkins"

# SonarQube health
curl -sf https://sonarqube.kind.local/api/system/status | python3 -m json.tool

# Check Jenkins OIDC config via JCasC
kubectl exec -n jenkins deployment/jenkins -c jenkins -- \
  cat /var/jenkins_home/casc_configs/security.yaml 2>/dev/null | grep -A5 "oic:"

# Verify folder structure in Jenkins
curl -su admin:Admin@Jenkins2024! \
  https://jenkins.kind.local/api/json?tree=jobs[name,jobs[name]] \
  | python3 -m json.tool
```

---

## Upgrading the stack

### Jenkins upgrade

1. Check release notes: https://www.jenkins.io/changelog-stable/

```bash
# 1. Update Helm repo
helm repo update jenkins

# 2. Check available versions
helm search repo jenkins/jenkins --versions | head -5

# 3. Review breaking changes in jenkins-values.yaml
#    Especially: plugin versions, JCasC schema changes

# 4. Upgrade (--atomic rolls back on failure)
helm upgrade jenkins jenkins/jenkins \
  --namespace jenkins \
  --values 08-jenkins/jenkins-values.yaml \
  --version <NEW_VERSION> \
  --atomic \
  --timeout 15m

# 5. Verify
kubectl rollout status deployment/jenkins -n jenkins
curl -sf https://jenkins.kind.local/login
```

**Plugin upgrades**: Update `installPlugins` in `jenkins-values.yaml` with pinned versions:
```yaml
installPlugins:
  - oic-auth:4.x.x
  - role-strategy:777.xxx
```
Pin versions to avoid unexpected breaking changes on restart.

### SonarQube upgrade

1. Read the upgrade notes: https://docs.sonarsource.com/sonarqube-server/latest/server-upgrade-and-maintenance/upgrade/

```bash
# SonarQube requires sequential upgrades between LTS versions.
# Check supported upgrade paths before jumping multiple versions.

# 1. Update repo
helm repo update sonarqube

# 2. Check available versions
helm search repo sonarqube/sonarqube --versions | head -5

# 3. Upgrade
helm upgrade sonarqube sonarqube/sonarqube \
  --namespace sonarqube \
  --values 08-jenkins/sonarqube-values.yaml \
  --version <NEW_VERSION> \
  --atomic \
  --timeout 10m

# 4. SonarQube may trigger DB migration on first startup after upgrade
#    Monitor logs:
kubectl logs -n sonarqube -l app=sonarqube-sonarqube -f | grep -i "migration\|upgrade\|error"

# 5. Re-run setup.sh to reconfigure OIDC settings if they were reset
cd 08-jenkins && ./setup.sh
```

**sonar-auth-oidc plugin**: The plugin version in `sonarqube-values.yaml` may need updating for compatibility with new SonarQube versions:
```yaml
plugins:
  install:
    - "https://github.com/vaulttec/sonar-auth-oidc/releases/download/v2.2.0/sonar-auth-oidc-plugin-2.2.0.jar"
```
Check: https://github.com/vaulttec/sonar-auth-oidc/releases for compatible versions.

### Rollback

```bash
# Jenkins
helm rollback jenkins -n jenkins
# SonarQube
helm rollback sonarqube -n sonarqube
```

## Known limitations

### SonarQube — No Keycloak SSO (Community Edition 2026.x)

The `sonar-auth-oidc` community plugin (vaulttec v2.1.1) depends on `org.sonar.api.web.ServletFilter` which was **removed** from the SonarQube Plugin API in the 2026.x series. The plugin crashes SonarQube at startup.

**SonarQube Community 2026.x does NOT have built-in OIDC or SAML support.**

Alternatives:
- Monitor https://github.com/vaulttec/sonar-auth-oidc for a new release compatible with SonarQube 2026+
- Upgrade to **SonarQube Developer Edition** (includes built-in SAML/OIDC)
- Use SonarQube's built-in GitHub/GitLab OAuth if those SCM providers are in use

**Current state**: SonarQube uses **local authentication** (admin/admin). Groups (`devops`, `team-a`, `team-b`) and project permissions are provisioned by `setup.sh` via the SonarQube REST API and take effect when SSO is eventually added.

### Jenkins — local `admin` user requires browser login for API tokens

With OIDC as the security realm, the local `admin` user cannot authenticate via basic auth (username/password) in REST API calls. To use the Jenkins API or CLI after initial setup:

1. Go to `https://jenkins.kind.local/securityRealm/commenceLogin?from=/` in a browser
2. Login via Keycloak as `devops-user-1` (password: `password`)
3. Go to **User → Configure → API Token → Add New Token**
4. Use that token for API calls: `curl -u devops-user-1:<token> https://jenkins.kind.local/api/json`

Alternatively, use the `EscapeHatch` feature of oic-auth plugin (see plugin docs) to create a local bypass user.

---



The `09-sample-app-react-and-nodejs/` directory contains:
- `api/` — Node.js REST API with Sequelize/MySQL
- `client/` — React frontend with nginx
- `api/Jenkinsfile` — 9-stage CI pipeline (compile → gitleaks → SCA → SAST → quality gate → docker → trivy → deploy)
- `client/Jenkinsfile` — 9-stage CI pipeline for React frontend
- `Jenkinsfile-cd-local` — CD pipeline using `kubectl + kustomize`

Jenkins jobs (`team-a/ci/react-app`, `team-b/ci/react-app`) currently point to the GitHub repo `amitactive2008/DevSecOps-Mega-Project`. Update the Git URL in `jenkins-values.yaml` when you fork the repo or use a local Git server.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Jenkins login fails with "Login provider denied" | Keycloak `groups` in scope | Verify `scopes: "openid email profile"` (no `groups`) in values |
| Jenkins shows no Keycloak button | oic-auth plugin not installed | Check: `kubectl exec -n jenkins deployment/jenkins -- ls /var/jenkins_home/plugins \| grep oic` |
| team-a user sees all jobs | RBAC not applied | Re-run `./setup.sh` — JCasC should provision roles |
| SonarQube OIDC button missing | Plugin not loaded or version incompatible | Check logs: `kubectl logs -n sonarqube -l app=sonarqube-sonarqube \| grep -i oidc` |
| SonarQube → Keycloak HTTPS fails | CA cert not in JVM trust store | Verify `caCerts.enabled: true` and `kind-local-ca-cert` Secret exists in `sonarqube` ns |
| Jenkins agents stuck Pending | RBAC / ServiceAccount issue | `kubectl get events -n jenkins \| grep -i forbidden` |
| SonarQube quality gate timeout | Webhook not configured | Re-run `./setup.sh` step 10 |

### Useful commands

```bash
# Jenkins: view installed plugins
kubectl exec -n jenkins deployment/jenkins -c jenkins -- \
  ls /var/jenkins_home/plugins | grep -v ".jpi.pinned"

# Jenkins: view JCasC applied config
kubectl exec -n jenkins deployment/jenkins -c jenkins -- \
  cat /var/jenkins_home/casc_configs/security.yaml

# SonarQube: check OIDC plugin is loaded
curl -su admin:admin https://sonarqube.kind.local/api/plugins/installed \
  | python3 -c "import json,sys; ps=json.load(sys.stdin)['plugins']; \
    [print(p['key'],p['version']) for p in ps if 'oidc' in p['key'].lower()]"

# SonarQube: list configured settings
curl -su admin:admin \
  "https://sonarqube.kind.local/api/settings/values?keys=sonar.auth.oidc.enabled,sonar.auth.oidc.issuerUri" \
  | python3 -m json.tool

# Port-forward Jenkins for direct API access
kubectl port-forward -n jenkins svc/jenkins 8081:8080 &
# curl http://localhost:8081/api/json
```
