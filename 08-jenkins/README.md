# 08 — Jenkins + SonarQube

CI/CD platform and code quality gateway on the kind cluster, authenticated via **Keycloak** with folder-based RBAC in Jenkins and group-based project access in SonarQube.

---

## Configuration split — why it matters

Jenkins configuration is split across **separate files** with different update workflows:

| File(s) | What it contains | How to update | Restart required? |
|---|---|---|---|
| `jenkins-values.yaml` | Security realm (OIC/Keycloak), authorization, Kubernetes cloud, plugins, and SonarQube integration | `helm upgrade` + pod restart | **Yes** — but these rarely change |
| `vault/policies/*.hcl`, `vault-setup.sh` | Vault access for ephemeral CI/CD agents | `./vault-setup.sh` | **No** |
| `Jenkins-agent*.yaml` | Agent containers, ServiceAccounts, and Vault Agent injection | Start a new build | **No** — every build gets a new pod |
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
    ├── jenkins.kind.local           ──► jenkins:8080    (NS: jenkins)
    ├── jenkins-resources.kind.local ──► jenkins:8080    (isolated static files)
    └── sonarqube.kind.local         ──► sonarqube-sonarqube:9000  (NS: sonarqube)

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
    ├── CI ServiceAccount: jenkins-ci
    │   ├── Vault role: jenkins-ci
    │   └── Docker Hub + NVD files rendered under /vault/secrets
    └── CD ServiceAccount: jenkins-cd-external
        ├── Vault role: jenkins-cd-external
        ├── restricted kubeconfig rendered under /vault/secrets
        └── kubectl deploys only through context external

BuildKit daemon (buildkitd, non-TLS, namespace: jenkins)
    └── Handles Docker image builds from agent pods

Target Kubernetes cluster
    └── Namespace team-a (namespace-scoped jenkins-deployer RBAC)
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
    └── ai-bankapp/
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
sudo sh -c 'echo "127.0.0.1 jenkins.kind.local jenkins-resources.kind.local sonarqube.kind.local" >> /etc/hosts'

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -
```

### Step 2 — Prepare the remote-cluster kubeconfig

Apply the provided namespace-scoped deployer resources to the target cluster
with an administrator context, then generate its kubeconfig outside the
repository:

```bash
kubectl --context <remote-admin-context> apply \
  -f 08-jenkins/remote-cluster/jenkins-deployer.yaml

./08-jenkins/remote-cluster/create-kubeconfig.sh \
  <remote-admin-context> /secure/path/external-kubeconfig
```

The template creates a persistent ServiceAccount token because this selected
design intentionally uses a static kubeconfig. Rotating that token requires
recreating `jenkins-deployer-token`, regenerating the file, and updating Vault.

The generated kubeconfig must:

- contain only the target cluster, user, and one context named `external`;
- use an API address reachable from Jenkins agent pods;
- contain the target cluster CA and never use `insecure-skip-tls-verify`; and
- be limited to the namespaces and actions required by the CD pipeline.

Verify the file before storing it:

```bash
KUBECONFIG=/path/to/external-kubeconfig kubectl config current-context
KUBECONFIG=/path/to/external-kubeconfig \
  kubectl auth can-i create deployments -n team-a
KUBECONFIG=/path/to/external-kubeconfig \
  kubectl auth can-i delete namespaces
```

The expected context is `external`, deployment access is `yes`, and namespace
deletion is `no`.

For a local integration test, the `external` context may point back to the kind
cluster through an API address reachable from Jenkins pods. This proves the
authentication and RBAC flow, but it is not a substitute for testing network
reachability, CA trust, and platform prerequisites on the intended remote
cluster. Replace the Vault value before using that cluster as a deployment
target.

### Step 3 — Run setup.sh

```bash
cd 08-jenkins
chmod +x setup.sh
./setup.sh
```

The script is **idempotent** — safe to re-run. It:
1. Updates CoreDNS with the Jenkins, Jenkins resource-root, and SonarQube hosts
2. Creates Keycloak OIDC clients (`jenkins`, `sonarqube`) with groups mapper
3. Copies cert-manager CA cert to `sonarqube` namespace for HTTPS trust
4. Applies namespace/RBAC/buildkitd manifests from `setup/`
5. Applies the isolated shared, external-CD, and Team B CI/CD ServiceAccounts
6. Helm install/upgrade SonarQube `2026.3.1`
7. Helm install/upgrade Jenkins `5.9.40`
8. Applies HTTPRoutes
9. Waits for readiness (up to 10 minutes for plugin downloads)
10. Configures SonarQube via API: OIDC, groups, projects, permissions
11. Generates SonarQube analysis token → stored as `sonarqube-token` Secret in `jenkins` namespace

### Step 4 — Configure Jenkins access to Vault

After `setup.sh` creates the Jenkins ServiceAccounts, configure the corresponding
Vault policies and Kubernetes-auth roles:

```bash
cd 08-jenkins
export VAULT_TOKEN="$(jq -r '.root_token' ../02-vault/cluster-keys.json)"
./vault-setup.sh
unset VAULT_TOKEN
```

The script is idempotent and does not write runtime secrets. It creates:

| Vault role | Kubernetes identity | Allowed path |
|---|---|---|
| `jenkins-ci` | `jenkins/jenkins-ci` | `secret/data/devops/jenkins/ci` |
| `jenkins-cd-external` | `jenkins/jenkins-cd-external` | `secret/data/devops/jenkins/clusters/external` |
| `jenkins-ci-team-b` | `jenkins/jenkins-ci-team-b` | `secret/data/team-b/jenkins/ci` |

### Step 5 — Store the runtime values in Vault

Use the Vault UI at `https://vault.kind.local/ui` and create these KV v2
secrets under the `secret` mount:

| Logical path | Required keys |
|---|---|
| `devops/jenkins/ci` | `dockerhub_username`, `dockerhub_token`, `nvd_api_key` |
| `devops/jenkins/clusters/external` | `kubeconfig` containing the raw, multiline YAML |
| `team-b/jenkins/ci` | `dockerhub_username`, `dockerhub_token` |

Do not base64-encode the kubeconfig. Do not commit or paste any value into a
README, issue, job parameter, or build log.

### Step 6 — Apply job definitions (NO restart needed)

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
└── jenkins-jobs-team-b.yaml   ← team-b: AI BankApp ci/cd
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
| Rotate DockerHub / NVD / kubeconfig credentials | Vault KV under `devops/jenkins` | Update Vault; start a new build | No |
| Change authorization roles (e.g. anonymous access) | `jenkins-values.yaml` | `helm upgrade` (updates ConfigMap → config-reload applies automatically) | No |
| Change security/auth (OIC config, plugins) | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Add/remove a plugin | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |
| Change Kubernetes cloud config | `jenkins-values.yaml` | `helm upgrade` + `kubectl delete pod` | Yes |

---

## Vault-backed build and deployment credentials

DockerHub, NVD, and remote-cluster credentials are never loaded into the Jenkins
controller. Vault Agent authenticates each ephemeral pod with its Kubernetes
ServiceAccount and writes only its permitted files:

```text
jenkins-ci pod
└── /vault/secrets/{dockerhub-username,dockerhub-token,nvd-api-key}

jenkins-cd-external pod
└── /vault/secrets/kubeconfig

jenkins-ci-team-b pod
└── /vault/secrets/{dockerhub-username,dockerhub-token}
```

The CI and CD roles cannot read each other's paths. `agent-pre-populate-only`
causes the build container to start only after Vault has rendered the files; a
missing secret or denied policy therefore fails closed.

The static kubeconfig is an explicit study-environment trade-off. Its bearer
token remains valid until the `jenkins-deployer-token` Secret is replaced or
deleted. Rotate it by recreating the Secret on the target cluster, regenerating
the kubeconfig, updating the Vault value, and starting a new CD build.

The SonarQube analysis token remains a Jenkins credential because `setup.sh`
generates it after SonarQube starts and JCasC supplies it to the SonarQube
plugin. It is not part of `secret/data/devops/jenkins`.

### Add another target cluster

For each additional cluster:

1. create `secret/devops/jenkins/clusters/<name>` with a raw `kubeconfig` key;
2. add a policy that reads only that exact path;
3. add a `jenkins-cd-<name>` ServiceAccount and Vault Kubernetes-auth role;
4. copy `Jenkins-agent-cd.yaml`, changing its ServiceAccount, Vault role, and
   injected path; and
5. use that agent file from a dedicated CD job.

Do not inject every cluster kubeconfig into one pod or interpolate an
unvalidated build parameter into a Vault path.

---

## Access

| Service | URL | Local admin |
|---|---|---|
| Jenkins | https://jenkins.kind.local | Local demo admin — use `/securityRealm/escapeHatch` |
| Jenkins resource root | https://jenkins-resources.kind.local | No direct login; isolated static build content |
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

# Controller and security settings managed by JCasC
kubectl exec -n jenkins jenkins-0 -c jenkins -- sh -c \
  'grep -E "<numExecutors>|projectNamingStrategy" /var/jenkins_home/config.xml;
   printf "JAVA_OPTS=%s\n" "$JAVA_OPTS"'

# SonarQube health
curl -sf https://sonarqube.kind.local/api/system/status | python3 -m json.tool

# Check Jenkins OIDC config via JCasC
kubectl exec -n jenkins statefulset/jenkins -c jenkins -- \
  cat /var/jenkins_home/casc_configs/security.yaml 2>/dev/null | grep -A5 "oic:"

# Verify folder structure in Jenkins
curl -su admin:Admin@Jenkins2024! \
  https://jenkins.kind.local/api/json?tree=jobs[name,jobs[name]] \
  | python3 -m json.tool

# Vault-backed agent identities
kubectl get serviceaccount -n jenkins \
  jenkins-ci jenkins-cd-external jenkins-ci-team-b jenkins-cd-team-b

# Only the SonarQube integration remains in Jenkins credentials
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  grep -R 'id: \"sonarqube-token\"' /var/jenkins_home/casc_configs
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

The controller runs with zero executors, project names are checked by the
Role-based Strategy, and OIDC user/group identifiers are explicitly
case-sensitive. Jenkins also enforces its UI CSP. Build artifacts are served
through `jenkins-resources.kind.local`, so do not disable
`hudson.model.DirectoryBrowserSupport.CSP` to make reports render.

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

### Pipeline security stages are not all blocking

The Team A Dependency-Check stages and SonarQube quality-gate waits are
temporarily disabled in their Jenkinsfiles. Trivy and SonarQube scanner
failures are currently non-blocking. This keeps the study pipeline deployable,
but it must not be interpreted as a production security gate. Module 09 lists
the exact stage behavior.

### Remote-cluster bootstrap is separate

The stored kubeconfig provides authentication and namespace-scoped
authorization only. It does not install Gateway API, Envoy Gateway,
cert-manager, Vault Agent Injector, or the application Vault role on a new
cluster. Bootstrap those dependencies first, and ensure the kubeconfig API
server address is reachable from Jenkins agent pods.

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
