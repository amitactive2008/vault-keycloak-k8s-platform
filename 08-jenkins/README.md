# 08 — Jenkins + SonarQube

CI/CD platform and code quality gateway on the kind cluster, authenticated via **Keycloak** with folder-based RBAC in Jenkins and group-based project access in SonarQube.

---

## Configuration split — why it matters

Jenkins configuration is split across **separate files** with different update workflows:

| File(s) | What it contains | How to update | Restart required? |
|---|---|---|---|
| `jenkins-values.yaml` | Security realm (OIC/Keycloak), authorization (role-strategy), Kubernetes cloud, plugins, JCasC credential definitions | `helm upgrade` + pod restart | **Yes** — but these rarely change |
| `setup/credentials.yaml` | Runtime secrets: DockerHub, NVD API key, `external-kubeconfig` kubeconfig | `kubectl apply` + pod restart | **Yes** — env vars injected at startup |
| `jobs/jenkins-jobs-devops.yaml` | DevOps folder tree | `./reload-jobs.sh` | **No** — sidecar hot-reloads in ~15 s |
| `jobs/jenkins-jobs-team-a.yaml` | Team A folders + pipeline jobs | `./reload-jobs.sh` | **No** — sidecar hot-reloads in ~15 s |
| `jobs/jenkins-jobs-team-b.yaml` | Team B folders + pipeline jobs | `./reload-jobs.sh` | **No** — sidecar hot-reloads in ~15 s |

Each `jobs/*.yaml` is a **separate Kubernetes ConfigMap** with a unique name and data key. The config-reload sidecar watches all of them independently — updating team-a's jobs never touches team-b's or devops's ConfigMap.

### How hot-reload works

The Jenkins pod runs two containers:
- `jenkins` — the main server
- `config-reload` — a sidecar (`kiwigrid/k8s-sidecar`) that watches Kubernetes

```
Edit jobs/jenkins-jobs-team-a.yaml
        │
        ▼
kubectl apply -f jobs/jenkins-jobs-team-a.yaml
        │  (updates ConfigMap jenkins-jobs-team-a, label: jenkins-jenkins-config=true)
        ▼
config-reload sidecar detects ConfigMap change
        │  copies jobs-team-a.yaml → /var/jenkins_home/casc_configs/jobs-team-a.yaml
        │  POSTs → http://localhost:8080/reload-configuration-as-code/
        ▼
Jenkins reloads JCasC in-place
        │  creates/updates team-a folder and job definitions only
        ▼
Done in ~15 seconds — NO RESTART ✓
```

### When to use each update method

```bash
# Add/modify/delete a job in team-a → NO restart
vim 08-jenkins/jobs/jenkins-jobs-team-a.yaml
cd 08-jenkins && ./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml

# Apply ALL teams at once → NO restart
cd 08-jenkins && ./reload-jobs.sh

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
| `StatefulSet` | `jenkins` | Jenkins controller, 10Gi PVC |
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
│   └── sample-react-app/
│       ├── api/
│       │   ├── ci
│       │   └── cd
│       └── client/
│           ├── ci
│           └── cd
└── team-b/
    └── sample-react-app/
        ├── api/
        │   ├── ci
        │   └── cd
        └── client/
            ├── ci
            └── cd
```

---

## Access matrix

### Jenkins

| Keycloak group | Jenkins access |
|---|---|
| *(anonymous)* | Dashboard view only — can see the home page, cannot view jobs or trigger builds |
| `devops` | Global admin — all folders and jobs |
| `team-a` | `team-a/*` only |
| `team-b` | `team-b/*` only |

### SonarQube

| Keycloak group | SonarQube access |
|---|---|
| `devops` | Global admin — all projects |
| `team-a` | `react-app-team-a` project only |
| `team-b` | `react-app-team-b` project only |

---

## Installation

### Step 1 — Add DNS entries and create the Jenkins namespace

```bash
sudo sh -c 'echo "127.0.0.1 jenkins.kind.local sonarqube.kind.local" >> /etc/hosts'

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
```

### Step 2 — Fill in real credentials

Create the ignored runtime credentials file from the safe template, then replace
every placeholder with your actual values:

```bash
cp 08-jenkins/setup/credentials-template.yaml \
  08-jenkins/setup/credentials.yaml
vim 08-jenkins/setup/credentials.yaml
```

If the ignored file already exists, do not overwrite it; edit it in place.
Never commit this file or paste its values into an issue or build log.

The Secret contains three credentials:

| Key | Purpose | Default |
|-----|---------|---------|
| `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` | DockerHub push access for pipeline builds | `amitactive2008` / set yours |
| `NVD_API_KEY` | OWASP Dependency-Check NVD database (free key at nvd.nist.gov) | set yours |
| `EXTERNAL_KUBECONFIG_B64` | Base64-encoded kubeconfig for the vault kind cluster (`external-kubeconfig` credential in Jenkins) | sourced from `01-cloud-provider-kind-setup-with-gw-api/vault-kube-config` |

Apply the Secret:

```bash
kubectl apply -f 08-jenkins/setup/credentials.yaml
```

> **Updating the kubeconfig** — after creating or recreating the vault cluster,
> export a fresh kubeconfig and replace its host-only API endpoint with the
> in-cluster Kubernetes service before encoding it:
> ```bash
> KUBECONFIG_FILE=01-cloud-provider-kind-setup-with-gw-api/vault-kube-config
> kind export kubeconfig --name vault --kubeconfig "$KUBECONFIG_FILE"
> KUBECONFIG="$KUBECONFIG_FILE" kubectl config set-cluster kind-vault \
>   --server=https://kubernetes.default.svc:443
> base64 < "$KUBECONFIG_FILE" | tr -d '\n'
> ```
> Paste the output as the `EXTERNAL_KUBECONFIG_B64` value in `credentials.yaml`, then re-apply the Secret and restart the pod:
> ```bash
> kubectl apply -f 08-jenkins/setup/credentials.yaml
> kubectl delete pod jenkins-0 -n jenkins
> ```

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

Job definitions are stored in `jobs/` (one ConfigMap per team). Use the helper script to validate, apply, and confirm reload:

```bash
cd 08-jenkins

# Apply all job files
./reload-jobs.sh

# Apply a single team's file
./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml
```

The script:
1. Validates each YAML file before applying
2. Runs `kubectl apply` for each ConfigMap
3. Directly triggers JCasC reload on Jenkins (no waiting for sidecar)
4. Waits until job configs appear in Jenkins and prints the final job tree

All folders and pipeline jobs appear in Jenkins within ~15 seconds — **no pod restart needed**.

---

## Managing jobs (no restart workflow)

Job files live in `08-jenkins/jobs/` — one file per team:

```
jobs/
├── jenkins-jobs-devops.yaml   ← devops folder tree (k8s, vault, keycloak…)
├── jenkins-jobs-team-a.yaml   ← team-a: sample-react-app api+client ci/cd
└── jenkins-jobs-team-b.yaml   ← team-b: sample-react-app api+client ci/cd
```

### Updating jobs — step by step

**1. Edit the relevant file**

```bash
# Example: add a new pipeline job to team-a
vim 08-jenkins/jobs/jenkins-jobs-team-a.yaml
```

Each file contains a Groovy Job DSL script inside a JCasC `jobs.script` block.  
Add or modify `folder()` / `pipelineJob()` entries in that script.

**2. Apply with `./reload-jobs.sh`**

Run from the `08-jenkins/` directory:

```bash
# Apply all job files (devops + team-a + team-b)
cd 08-jenkins && ./reload-jobs.sh

# Apply a single file only
cd 08-jenkins && ./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml
```

**What the script does:**

| Step | Action |
|------|--------|
| Validate | Runs `kubectl apply --dry-run=client` for each YAML file — exits on error |
| Apply | Runs `kubectl apply -f` for each ConfigMap |
| Reload | POSTs directly to `http://localhost:8080/reload-configuration-as-code/` on the Jenkins pod |
| Confirm | Waits until `config.xml` files appear under `/var/jenkins_home/jobs` |
| Report | Prints the full job tree so you can verify the result |

**3. Verify in Jenkins UI**

Open `https://jenkins.kind.local` — the new folders/jobs appear without any pod restart.

---

### Jobs not showing after reload?

If jobs disappear or don't appear after running `./reload-jobs.sh`, re-run the script — it triggers a fresh JCasC reload every time:

```bash
cd 08-jenkins && ./reload-jobs.sh
```

To debug manually:

```bash
# Check JCasC reload logs on the Jenkins controller
kubectl logs -n jenkins jenkins-0 -c jenkins --tail=30 \
  | grep -i "casc\|job\|dsl\|reload"

# Check sidecar file sync logs
kubectl logs -n jenkins jenkins-0 -c config-reload --tail=20

# Manually trigger a JCasC reload
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  curl -sf -X POST \
  "http://localhost:8080/reload-configuration-as-code/?casc-reload-token=jenkins-0"

# Confirm job configs are on disk
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  find /var/jenkins_home/jobs -name config.xml | sort
```

---

### What triggers each update method

| Change type | File to edit | Update command | Restart? |
|---|---|---|---|
| Add/modify/delete a devops job or folder | `jobs/jenkins-jobs-devops.yaml` | `./reload-jobs.sh` | No |
| Add/modify/delete a team-a job or folder | `jobs/jenkins-jobs-team-a.yaml` | `./reload-jobs.sh` | No |
| Add/modify/delete a team-b job or folder | `jobs/jenkins-jobs-team-b.yaml` | `./reload-jobs.sh` | No |
| Update DockerHub / NVD / kubeconfig credentials | `setup/credentials.yaml` | `kubectl apply` + `kubectl delete pod jenkins-0 -n jenkins` | Yes |
| Change authorization roles (e.g. anonymous access) | `jenkins-values.yaml` | `helm upgrade` (updates ConfigMap → config-reload applies automatically) | No |
| Change security/auth (OIC config, plugins) | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Add/remove a plugin | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Change Kubernetes cloud config | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |

---

## Credentials

All runtime secrets are stored in a single Kubernetes Secret (`jenkins-credentials`) and injected as environment variables into the Jenkins pod. JCasC reads them at startup using `${ENV_VAR}` interpolation.

### Defined credentials

| Jenkins Credential ID | Type | Source key in Secret | Used by |
|---|---|---|---|
| `dockerhub` | Username/Password | `DOCKERHUB_USERNAME` / `DOCKERHUB_PASSWORD` | Pipeline `docker build` / `docker push` steps |
| `NVD_API_KEY` | Secret Text | `NVD_API_KEY` | OWASP Dependency-Check plugin |
| `sonarqube-token` | Secret Text | `SONARQUBE_TOKEN` (from `sonarqube-token` Secret) | SonarQube scanner |
| `external-kubeconfig` | Secret File (`config`) | `EXTERNAL_KUBECONFIG_B64` | `kubectl` steps targeting the vault kind cluster |

### Using `external-kubeconfig` in a pipeline

```groovy
withCredentials([file(credentialsId: 'external-kubeconfig', variable: 'KUBECONFIG')]) {
    sh 'kubectl get nodes --kubeconfig=$KUBECONFIG'
}
```

> **Note:** The Jenkins kubeconfig must use
> `server: https://kubernetes.default.svc:443`. The host-only kind endpoint
> `https://127.0.0.1:6443` points back to the Jenkins pod when used in a
> pipeline and cannot reach the API server.

### Updating the kubeconfig (`external-kubeconfig`)

The kubeconfig is sourced from
`01-cloud-provider-kind-setup-with-gw-api/vault-kube-config`. Refresh it after
the cluster is recreated:

```bash
# 1. Export current credentials and use the in-cluster API endpoint
KUBECONFIG_FILE=01-cloud-provider-kind-setup-with-gw-api/vault-kube-config
kind export kubeconfig --name vault --kubeconfig "$KUBECONFIG_FILE"
KUBECONFIG="$KUBECONFIG_FILE" kubectl config set-cluster kind-vault \
  --server=https://kubernetes.default.svc:443

# 2. Regenerate the base64 value
KUBECONFIG_B64=$(base64 < "$KUBECONFIG_FILE" | tr -d '\n')

# 3. Update EXTERNAL_KUBECONFIG_B64 in credentials.yaml with the new value
vim 08-jenkins/setup/credentials.yaml

# 4. Apply and restart
kubectl apply -f 08-jenkins/setup/credentials.yaml
kubectl delete pod jenkins-0 -n jenkins
kubectl wait pod -n jenkins -l app.kubernetes.io/component=jenkins-controller \
  --for=condition=Ready --timeout=300s
```

### Verify credentials in Jenkins

```bash
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  curl -sf -u "admin:Admin@Jenkins2024!" \
  "http://localhost:8080/credentials/store/system/domain/_/api/json?depth=1" \
  | python3 -c "
import json,sys
for c in json.load(sys.stdin).get('credentials',[]):
    print(f\"  {c['id']:30s} {c['typeName']}\")
"
# Expected output:
#   dockerhub                      Username with password
#   NVD_API_KEY                    Secret text
#   sonarqube-token                Secret text
#   external-kubeconfig            Secret file
```

---

## Access

| Service | URL | Local admin |
|---|---|---|
| Jenkins | https://jenkins.kind.local | `admin` / `Admin@Jenkins2024!` — log in at `/login` (EscapeHatch, bypasses Keycloak) |
| SonarQube | https://sonarqube.kind.local | `admin` / `admin` |

### Jenkins SSO login
1. Open `https://jenkins.kind.local` — the Jenkins dashboard loads without requiring a login (anonymous read access)
2. Click **"Sign in"** (top-right header) or **"Log in to Jenkins"** (dashboard welcome message)
3. Jenkins redirects you to Keycloak
4. Log in with a Keycloak user → redirected back to Jenkins with your group permissions applied

> **Why anonymous read?** Without it, the OIC plugin intercepts every unauthenticated request and immediately redirects to Keycloak — users never see the Jenkins UI or get a chance to click a login button. The `anonymous-read` global role grants `Overall/Read` only, so unauthenticated users can see the dashboard but cannot view jobs, trigger builds, or access any sensitive data.

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
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
  cat /var/jenkins_home/casc_configs/security.yaml 2>/dev/null | grep -A5 "oic:"

# Verify folder structure in Jenkins
curl -su admin:Admin@Jenkins2024! \
  https://jenkins.kind.local/api/json?tree=jobs[name,jobs[name]] \
  | python3 -m json.tool

# Verify all 4 credentials exist
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  curl -sf -u "admin:Admin@Jenkins2024!" \
  "http://localhost:8080/credentials/store/system/domain/_/api/json?depth=1" \
  | python3 -c "
import json,sys
for c in json.load(sys.stdin).get('credentials',[]):
    print(f\"  {c['id']:30s} {c['typeName']}\")
"
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
kubectl rollout status statefulset/jenkins -n jenkins
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

### SonarQube OIDC is provided by a community plugin

SonarQube Community does not provide the repository's Keycloak integration by
itself. This setup installs `sonar-auth-oidc` v3.0.0 from the URL pinned in
`sonarqube-values.yaml`, then `setup.sh` configures its issuer, client, and
groups settings. Treat a SonarQube or plugin upgrade as a compatibility change:
test it before upgrading the study environment.

If the plugin prevents SonarQube from starting, remove or update the pinned
plugin, redeploy SonarQube, and use the local `admin` account while diagnosing
the compatibility problem. The Keycloak group and project permissions created
by `setup.sh` remain useful after OIDC is restored.

### Jenkins — local `admin` user (EscapeHatch login)

With OIDC as the security realm, the **"Sign in"** button on the Jenkins UI always redirects to Keycloak. The local `admin` user bypasses Keycloak via the **EscapeHatch** feature of the oic-auth plugin.

**Login URL:** `https://jenkins.kind.local/securityRealm/escapeHatch`

The EscapeHatch page shows the local username/password form. Use:

| Field | Value |
|-------|-------|
| Username | `admin` |
| Password | `Admin@Jenkins2024!` |

This gives full admin access (`Overall/Administer`) — same as the `devops` Keycloak group.

> **How it works:** The EscapeHatch property is configured in JCasC under `securityRealm.oic.properties`. It BCrypt-hashes the secret at startup and validates credentials independently of Keycloak. The `devops` group is injected into the session so all admin roles apply immediately.

#### Using the Jenkins API / CLI as admin

After logging in via the EscapeHatch, create an API token for scripted access:

1. Log in at `https://jenkins.kind.local/securityRealm/escapeHatch` with the
   configured local administrator credentials
2. Go to **admin → Configure → API Token → Add New Token**
3. Use that token for API calls:

```bash
curl -su admin:<token> https://jenkins.kind.local/api/json
```

Alternatively, log in via Keycloak as `devops-user-1` (password: `password`) and generate a token for that user.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Jenkins login fails with "Login provider denied" | Keycloak `groups` in scope | Verify `scopes: "openid email profile"` (no `groups`) in values |
| Jenkins shows no Keycloak button | oic-auth plugin not installed | Check: `kubectl exec -n jenkins statefulset/jenkins -- ls /var/jenkins_home/plugins \| grep oic` |
| team-a user sees all jobs | RBAC not applied | Re-run `./setup.sh` — JCasC should provision roles |
| SonarQube OIDC button missing | Plugin not loaded or version incompatible | Check logs: `kubectl logs -n sonarqube -l app=sonarqube-sonarqube \| grep -i oidc` |
| SonarQube → Keycloak HTTPS fails | CA cert not in JVM trust store | Verify `caCerts.enabled: true` and `kind-local-ca-cert` Secret exists in `sonarqube` ns |
| Jenkins agents stuck Pending | RBAC / ServiceAccount issue | `kubectl get events -n jenkins \| grep -i forbidden` |
| SonarQube quality gate timeout | Webhook not configured | Re-run `./setup.sh` step 10 |

### Useful commands

```bash
# Jenkins: view installed plugins
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
  ls /var/jenkins_home/plugins | grep -v ".jpi.pinned"

# Jenkins: view JCasC applied config
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
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
