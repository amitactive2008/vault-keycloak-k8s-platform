# 10 — Team B AI BankApp

This module packages the imported Spring Boot banking demo for the local kind
platform. Jenkins builds and scans the application, pushes a multi-platform
image to Docker Hub, and triggers a separate CD job that deploys MySQL, Ollama,
and the application into the `team-b` namespace.

This is a study application, not a real banking system.

## Architecture

```text
team-b/ai-bankapp/ci
  ├── Gitleaks
  ├── Checkstyle (audit)
  ├── Semgrep
  ├── Dependency-Check/NVD (disabled)
  ├── Maven package (tests skipped)
  ├── BuildKit OCI image build
  ├── Trivy
  └── Docker Hub push
            │
            ▼
team-b/ai-bankapp/cd
  ├── namespace-scoped Kubernetes preflight
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

## Jenkins stage mapping

The imported `.github/workflows/` files remain only as upstream reference.
Because they are nested inside this module, GitHub does not execute them for
the platform repository. Semgrep excludes that reference-only directory through
`.semgrepignore`; it continues to scan the application source, Jenkins
pipelines, and deployable manifests. Their relevant behavior is represented in
Jenkins:

| Upstream action | Jenkins behavior |
|---|---|
| Gitleaks | Blocking source scan |
| Checkstyle | Audit-only, matching the upstream `|| true` behavior |
| Semgrep | Blocking Java, OWASP Top 10, and secret rules |
| OWASP Dependency-Check/NVD | Present but disabled as requested |
| Maven build | `clean package -DskipTests` as requested |
| Container build | Remote BuildKit |
| Trivy | Blocks on fixed High/Critical findings before push |
| Amazon ECR push | Replaced with Docker Hub |
| EC2/Compose deployment | Replaced with namespace-scoped Kubernetes CD |
| OWASP ZAP | Audit-only scan after rollout |

The Maven baseline uses Spring Boot `3.5.14`, Tomcat `10.1.55`, Thymeleaf
`3.1.5.RELEASE`, and Jackson `2.21.4`. Keep these versions at or above their
documented security floors; Trivy remains the blocking check for newly
disclosed fixed vulnerabilities.

Gitleaks scans the imported source tree, not the source repository's former Git
history, because that history was not copied into this repository.

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

The Docker Hub repository `amitactive2008/ai-bankapp` must exist and allow the
Vault-stored Docker Hub account to push.

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
./10-ai-bankapp/AI-BankApp-DevOps/vault-setup.sh
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

Run CI. A successful immutable image push automatically starts CD with tag
`team-b-<BUILD_NUMBER>`. Manual CD runs default to `team-b-latest`.

### 5. Add the local hostname

```bash
echo "127.0.0.1 ai-bankapp.kind.local" | sudo tee -a /etc/hosts
```

Open `https://ai-bankapp.kind.local`.

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

curl --fail https://ai-bankapp.kind.local/actuator/health
```

The login and registration pages are at `/login` and `/register`.

## Local Compose development

Compose is optional and does not use Vault:

```bash
cp .env.example .env
# Replace both placeholder passwords in .env.
docker compose up --build
```

The `.env` file is ignored by Git.

## Known limitations

- Maven tests and the NVD-backed Dependency-Check stage are deliberately
  skipped. This reduces pipeline assurance.
- Checkstyle and ZAP are audit-only, mirroring the imported workflow.
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
