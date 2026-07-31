# 11 — Team B AI BankApp

This module packages the imported Spring Boot banking demo for the local kind
platform. Jenkins builds and scans the application, pushes both a
multi-platform image and an OCI Helm chart to Docker Hub, and triggers a
separate CD job. CD pulls the immutable chart version and deploys MySQL,
Ollama, and the application into the `team-b` namespace.

This is a study application, not a real banking system.

## Architecture

```text
team-b/ai-bankapp/ci
  ├── Gitleaks
  ├── Checkstyle (audit)
  ├── Semgrep
  ├── Maven package (tests skipped)
  ├── Trivy rendered-Helm misconfiguration gate
  ├── BuildKit OCI image build
  ├── Trivy
  ├── Docker Hub image push
  └── Helm lint, package, and OCI push
            │
            ▼
team-b/ai-bankapp/cd
  ├── namespace-scoped Kubernetes preflight
  ├── pull immutable chart from Docker Hub
  ├── Helm upgrade/install with matching image tag
  ├── MySQL + Ollama + application rollout
  ├── actuator smoke test
  └── OWASP ZAP baseline scan (audit)

https://ai-bankapp.kind.local
  └── Envoy Gateway / HTTPRoute
      └── ai-bankapp:8080
          ├── ai-bankapp-mysql:3306
          └── ai-bankapp-ollama:11434 (TinyLlama)
```

## Security boundaries

| Consumer | Identity | Allowed access |
|---|---|---|
| Team B CI pod | `jenkins/jenkins-ci-team-b` | Vault `secret/data/team-b/jenkins/ci` |
| Team B CD pod | `jenkins/jenkins-cd-team-b` | Kubernetes resources in `team-b` only |
| BankApp and MySQL pods | `team-b/ai-bankapp` | Vault `secret/data/team-b/ai-bankapp` |

The Jenkins controller does not receive Docker Hub credentials. Vault Agent
renders them only in the ephemeral CI pod. MySQL and the Spring application
also receive their database values from Vault Agent; this deployment does not
create a Kubernetes Secret for database credentials.

## Jenkins stages

Jenkins is the only CI/CD system for this module. The copied GitHub Actions,
AWS/EC2, and Compose deployment artifacts were removed after their relevant
local-platform behavior was implemented in the Jenkins pipelines.

| Control | Jenkins behavior |
|---|---|
| Gitleaks | Blocking source scan |
| Checkstyle | Audit-only |
| Semgrep | Blocking Java, OWASP Top 10, and secret rules |
| Maven build | `clean package -DskipTests` as requested |
| Helm security | Trivy renders the Team B values and blocks on High/Critical misconfigurations |
| Container build | Remote BuildKit packages the JAR produced by the Maven stage |
| Trivy | Blocks on fixed High/Critical findings before push |
| Registry push | Docker Hub immutable and `team-b-latest` tags |
| Chart publish | OCI chart `ai-bankapp-chart:0.1.<BUILD_NUMBER>` on Docker Hub |
| Deployment | Pull exact OCI chart version and run namespace-scoped Helm upgrade |
| OWASP ZAP | Audit-only scan after rollout |

The Maven baseline uses Spring Boot `3.5.14`, Spring Framework `6.2.19`,
Tomcat `10.1.55`, Thymeleaf `3.1.5.RELEASE`, and Jackson `2.21.4`. Keep these
versions at or above their documented security floors; Trivy remains the
blocking check for newly disclosed fixed vulnerabilities.

The Dockerfile intentionally consumes `target/bankapp-*.jar`; run
`./mvnw clean package -DskipTests` before building the image outside Jenkins.
This prevents Maven dependencies from being resolved a second time inside
BuildKit.

Gitleaks scans the application source tree with `--no-git`; the imported
repository's former Git history is not part of this repository.

## Vault paths

Create this CI value through the Vault UI:

| Logical KV v2 path | Keys |
|---|---|
| `team-b/jenkins/ci` | `dockerhub_username`, `dockerhub_token` |

The application bootstrap script creates and preserves:

| Logical KV v2 path | Keys |
|---|---|
| `team-b/ai-bankapp` | `DB_ROOT_PASSWORD`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` |

Do not commit, paste into job parameters, or print any of these values.

## Prerequisites

Complete modules 01 through 08. Verify:

```bash
kubectl get gateway native-gateway
kubectl get pods -n vault
kubectl get pods -n jenkins
kubectl get deployment buildkitd -n jenkins
```

The kind nodes need enough free resources for Jenkins build agents, MySQL, and
Ollama. The first TinyLlama pull can take several minutes and is retained on a
3 Gi persistent volume.

The Vault-stored account must be allowed to push under `amitactive2008`:

- `amitactive2008/ai-bankapp` stores application images;
- `amitactive2008/ai-bankapp-chart` stores OCI Helm charts and is created
  automatically by the first successful chart push.

Keep both repositories public for this study flow. Kubernetes pulls the
application image and the CD Helm client pulls the chart anonymously. A private
registry requires separate pull-only credentials; do not reuse a broad
push-capable token in the CD pod.

## Setup

Run from the repository root.

### 1. Apply Team B Jenkins identities and RBAC

```bash
kubectl apply -f 08-jenkins/setup/rbac.yaml
kubectl apply -f 08-jenkins/setup/team-b-rbac.yaml
```

This creates the `team-b` namespace, Team B CI/CD ServiceAccounts, and the
namespace-scoped CD RoleBinding.

### 2. Configure the Jenkins Vault role

```bash
export VAULT_TOKEN="$(jq -r '.root_token' 02-vault/cluster-keys.json)"
./08-jenkins/vault-setup.sh
unset VAULT_TOKEN
```

Then use the Vault UI to create `secret/team-b/jenkins/ci` with the Docker Hub
username and access token.

### 3. Configure application secrets and Vault Agent access

```bash
./11-ai-bankapp/AI-BankApp-DevOps/vault-setup.sh
```

The script generates missing database passwords, preserves existing values on
reruns, writes the `team-b-ai-bankapp` policy, and binds it to
`team-b/ai-bankapp`.

### 4. Load the Team B Jenkins jobs

```bash
cd 08-jenkins
./reload-jobs.sh jobs/jenkins-jobs-team-b.yaml
cd ..
```

The jobs appear at:

```text
team-b/ai-bankapp/ci
team-b/ai-bankapp/cd
```

Run CI. One successful build publishes the immutable pair below and then starts
CD with both values:

```text
amitactive2008/ai-bankapp:team-b-<BUILD_NUMBER>
oci://registry-1.docker.io/amitactive2008/ai-bankapp-chart:0.1.<BUILD_NUMBER>
```

Manual CD runs require an image tag and a chart version that already exist in
Docker Hub. The `0.1.1` default assumes CI build 1 still exists; select the
version printed by the CI build for later runs.

### 5. Add the local hostname

```bash
echo "127.0.0.1 ai-bankapp.kind.local" | sudo tee -a /etc/hosts
```

Open `https://ai-bankapp.kind.local`.

## Helm chart

The reusable defaults live in `helm/ai-bankapp/values.yaml`. Local Team B
settings—Docker Hub image, Vault path and role, Gateway parent, and hostname—
live in `helm/team-b-values.yaml`.

```text
helm/
├── ai-bankapp/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── application.yaml
│       ├── httproute.yaml
│       ├── mysql.yaml
│       ├── ollama.yaml
│       └── serviceaccount.yaml
└── team-b-values.yaml
```

Validate and render it locally:

```bash
helm lint 11-ai-bankapp/AI-BankApp-DevOps/helm/ai-bankapp \
  -f 11-ai-bankapp/AI-BankApp-DevOps/helm/team-b-values.yaml

helm template ai-bankapp \
  11-ai-bankapp/AI-BankApp-DevOps/helm/ai-bankapp \
  --namespace team-b \
  -f 11-ai-bankapp/AI-BankApp-DevOps/helm/team-b-values.yaml \
  --set-string image.tag=team-b-latest

trivy config \
  --severity HIGH,CRITICAL \
  --exit-code 1 \
  --helm-values 11-ai-bankapp/AI-BankApp-DevOps/helm/team-b-values.yaml \
  --helm-set-string image.tag=team-b-latest \
  11-ai-bankapp/AI-BankApp-DevOps/helm/ai-bankapp
```

The first CD run uses Helm's `--take-ownership` option to adopt resources
created by the former raw-manifest pipeline without changing their stable names
or selectors. Later runs use `--atomic` for rollback protection. The raw
`kubernetes/` manifests were removed so Helm is the single deployment owner.
The Team B Jenkins role can manage only the chart's namespace-scoped resources;
its read-only ReplicaSet permission is used by Helm to wait for Deployment
rollouts.

## Kubernetes resources

| Resource | Name | Purpose |
|---|---|---|
| ServiceAccount | `ai-bankapp` | Vault Kubernetes authentication |
| StatefulSet | `ai-bankapp-mysql` | MySQL 8 with persistent storage |
| Deployment | `ai-bankapp-ollama` | Local TinyLlama inference |
| Deployment | `ai-bankapp` | Spring Boot application |
| Service | `ai-bankapp-mysql` | JDBC endpoint |
| Service | `ai-bankapp-ollama` | Ollama API |
| Service | `ai-bankapp` | Application endpoint |
| HTTPRoute | `ai-bankapp` | HTTPS route |
| HTTPRoute | `ai-bankapp-http-redirect` | HTTP-to-HTTPS redirect |

## Verification

```bash
kubectl get pods,svc,pvc,httproute -n team-b
kubectl rollout status statefulset/ai-bankapp-mysql -n team-b --timeout=7m
kubectl rollout status deployment/ai-bankapp-ollama -n team-b --timeout=7m
kubectl rollout status deployment/ai-bankapp -n team-b --timeout=7m

kubectl get deployment ai-bankapp -n team-b \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'

helm status ai-bankapp -n team-b
helm get values ai-bankapp -n team-b

curl --fail https://ai-bankapp.kind.local/actuator/health
```

The login and registration pages are at `/login` and `/register`.

## Known limitations

- Maven tests are deliberately skipped, and this Team B pipeline does not run
  NVD-backed Dependency-Check. Trivy still blocks fixed High/Critical image
  vulnerabilities. This reduces pipeline assurance.
- Checkstyle and ZAP are audit-only.
- Floating scanner and Ollama container tags are appropriate only for this
  study setup; pin digests before treating builds as reproducible.
- TinyLlama receives the signed-in user's balance and recent transaction
  summary as prompt context. Keep Ollama private and do not replace it with an
  external AI endpoint without a data-handling review.
- The application is a demonstration and does not implement the concurrency,
  audit, fraud, regulatory, or recovery controls expected from financial
  software.

## Offline validation

From the repository root:

```bash
make validate
```
