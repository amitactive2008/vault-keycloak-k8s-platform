# 09 — Team A React and Node.js CI/CD

This module deploys the sample user-management application into the `team-a`
namespace. Jenkins builds the API and client, pushes multi-platform images to
Docker Hub, and starts separate CD jobs that apply the Kubernetes manifests.

## Source and pipeline repositories

The application source and platform automation intentionally live in different
repositories:

| Content | Repository | Branch |
|---|---|---|
| React client and Node.js API source | `https://github.com/amitactive2008/DevSecOps-Mega-Project.git` | Jenkins parameter `SOURCE_BRANCH` (default: `dev`) |
| Jenkinsfiles and Kubernetes manifests | This platform repository | `v5-codeX-gwApi-jenkins-reactApp` until these changes are merged |

The Jenkins jobs use this platform repository as their SCM so Jenkins can load
the local pipeline definitions. Each CI pipeline then checks out the application
repository in its first stage.

## Deployment flow

```text
API CI ──build/push──> sample-react-app-api:team-a-<build>
  │
  └──trigger──> API CD ──apply──> MySQL + API + HTTPRoute in team-a

Client CI ──build/push──> sample-react-app-client:team-a-<build>
  │
  └──trigger──> Client CD ──apply──> Client + HTTPRoute in team-a
```

Traffic follows this path:

```text
https://sample-react-app.kind.local
  -> Envoy Gateway
  -> sample-react-app-client:80
  -> Nginx /api proxy
  -> api-service:5000
  -> mysql:3306
```

The API pod uses Vault Agent injection. Its init container waits for MySQL, then
the API container loads `/vault/secrets/api.env`, runs the Sequelize migrations
and seeders, and starts the server.

> `NODE_ENV=development` is deliberate for this local environment. The upstream
> application's production database configuration forces MySQL TLS, while the
> study-only in-cluster MySQL instance is not configured for TLS.

## Files in this module

```text
09-sample-app-react-and-nodejs/
├── api/
│   ├── Jenkinsfile                 # API CI
│   └── cd/Jenkinsfile              # API CD
├── client/
│   ├── Jenkinsfile                 # Client CI
│   └── cd/Jenkinsfile              # Client CD
├── kubernetes/
│   ├── rbac.yaml
│   ├── httproute.yaml
│   ├── mysql/
│   ├── api/
│   └── client/
└── vault-setup.sh                  # Vault, MySQL Secret, SA, and local DNS setup
```

The older `api/cd/k8s` and `client/cd/k8s` Kustomize examples are retained for
study, but the Team A Jenkins CD jobs use `kubernetes/` as the canonical
deployment manifests. They do not require External Secrets Operator or the
Secrets Store CSI driver.

## Jenkins jobs

The jobs are defined in
`08-jenkins/jobs/jenkins-jobs-team-a.yaml`:

```text
team-a/sample-react-app/api/ci
team-a/sample-react-app/api/cd
team-a/sample-react-app/client/ci
team-a/sample-react-app/client/cd
```

The CI jobs perform:

1. Application source checkout.
2. `npm ci` plus API syntax checks or client tests.
3. Gitleaks scanning.
4. OWASP Dependency-Check using the Jenkins `NVD_API_KEY` credential. This
   stage is temporarily skipped with `when { expression { false } }`; remove
   that `when` block from both CI Jenkinsfiles to re-enable it.
5. SonarQube analysis. The quality-gate wait is temporarily disabled until the
   SonarQube-to-Jenkins webhook is verified.
6. BuildKit multi-platform build for `linux/amd64,linux/arm64`.
7. Docker Hub push using the Jenkins `dockerhub` credential.
8. Trivy image scanning.
9. Automatic start of the matching CD job.

Images are published as:

- `amitactive2008/sample-react-app-api:team-a-<BUILD_NUMBER>`
- `amitactive2008/sample-react-app-api:team-a-latest`
- `amitactive2008/sample-react-app-client:team-a-<BUILD_NUMBER>`
- `amitactive2008/sample-react-app-client:team-a-latest`

The CD jobs use the Jenkins file credential `external-kubeconfig`, deploy only
to `team-a`, wait for rollouts, and run an in-pod smoke test.

## Prerequisites

Complete modules 01 through 08 first. Before starting these pipelines, verify:

```bash
kubectl get gateway native-gateway
kubectl get pods -n vault
kubectl get pods -n jenkins
kubectl get pods -n sonarqube
kubectl get namespace team-a
```

Jenkins must contain these credentials:

- `dockerhub`
- `NVD_API_KEY` (required when Dependency-Check is re-enabled)
- `external-kubeconfig`

See `08-jenkins/setup/credentials-template.yaml` and the module 08 README. Never
commit the populated credentials file or a kubeconfig.

## Setup

Run commands from the repository root.

### 1. Configure Vault and Team A bootstrap resources

```bash
./09-sample-app-react-and-nodejs/vault-setup.sh
```

The script is idempotent where practical. It:

- creates or updates `secret/data/team-a/sample-react-app/api`;
- creates the `team-a-sample-react-app` Vault policy and Kubernetes auth role;
- applies ServiceAccount `sample-react-app-backend`;
- creates the MySQL bootstrap Secret without printing its values; and
- adds the application hostname to the kind CoreDNS hosts block.

The checked-in values are insecure demo values. Change them before using this
outside a disposable study cluster.

For host access, add this entry once:

```bash
echo "127.0.0.1 sample-react-app.kind.local" | sudo tee -a /etc/hosts
```

### 2. Load the Team A Jenkins jobs

```bash
cd 08-jenkins
./reload-jobs.sh jobs/jenkins-jobs-team-a.yaml
cd ..
```

This updates the job ConfigMap and reloads JCasC without restarting Jenkins.

### 3. Start CI

In the Jenkins UI, use:

```text
team-a > sample-react-app > api > ci
team-a > sample-react-app > client > ci
```

Choose **Build with Parameters** to override `SOURCE_BRANCH`; otherwise use the
default `dev`. On the first run after creating a declarative job, Jenkins can
show **Build Now** until it has parsed the Jenkinsfile once. The default branch
still applies.

Each successful CI build automatically supplies its immutable image tag to the
matching CD job. Do not manually start CD with `team-a-latest` when you need a
reproducible deployment.

## Kubernetes resources

| Kind | Name | Purpose |
|---|---|---|
| ServiceAccount | `sample-react-app-backend` | Vault Kubernetes authentication |
| Secret | `sample-react-app-mysql` | MySQL bootstrap credentials |
| StatefulSet | `sample-react-app-mysql` | MySQL 8.0 with a 2 Gi PVC |
| Service | `mysql` | API database endpoint |
| Deployment | `sample-react-app-api` | Express API plus Vault Agent |
| Service | `api-service` | Nginx upstream for `/api` |
| Deployment | `sample-react-app-client` | React static files on Nginx |
| Service | `sample-react-app-client` | Gateway backend |
| HTTPRoute | `sample-react-app` | HTTPS application route |
| HTTPRoute | `sample-react-app-http-redirect` | HTTP-to-HTTPS redirect |

The `api-service` and `mysql` service names must remain stable because the
upstream Nginx configuration and Vault database settings refer to them.

## Verify

Check the deployment:

```bash
kubectl get pods,svc,httproute -n team-a
kubectl rollout status statefulset/sample-react-app-mysql \
  -n team-a --timeout=5m
kubectl rollout status deployment/sample-react-app-api \
  -n team-a --timeout=7m
kubectl rollout status deployment/sample-react-app-client \
  -n team-a --timeout=5m
```

Confirm the deployed immutable image tags:

```bash
kubectl get deployment -n team-a \
  sample-react-app-api sample-react-app-client \
  -o jsonpath='{range .items[*]}{.metadata.name}{": "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

Test through Envoy Gateway:

```bash
kubectl get secret kind-local-ca-secret -n cert-manager \
  -o jsonpath='{.data.tls\.crt}' | base64 --decode > /tmp/kind-local-ca.crt

curl --fail --cacert /tmp/kind-local-ca.crt \
  https://sample-react-app.kind.local/
curl --fail --cacert /tmp/kind-local-ca.crt \
  https://sample-react-app.kind.local/api/live
curl --fail --cacert /tmp/kind-local-ca.crt \
  https://sample-react-app.kind.local/api/health
```

The seed data in the upstream study application creates
`admin@example.com` / `admin123`. These are demo-only credentials.

## Troubleshooting

### CI waits in Dependency-Check

The first NVD synchronization is large. Both jobs share
`/dependency-check-data`; one build updates it while the other waits on
`odc.update.lock`. This is expected and avoids database corruption. The stage
is currently disabled in both CI Jenkinsfiles so this initial import does not
block application delivery.

### SonarQube scanner returns HTTP 401

Verify the runtime token Secret exists:

```bash
kubectl get secret sonarqube-token -n jenkins
```

If it is missing or invalid, generate a SonarQube analysis token, store it in
that Secret, and restart Jenkins so JCasC refreshes credential
`sonarqube-token`. Never print or commit the token.

The quality-gate wait is also temporarily disabled in both CI Jenkinsfiles. Its
webhook timeout otherwise marks the overall build `ABORTED` after later stages
continue. Remove the `when` condition after verifying the webhook end to end.

### CI does not start CD

Check the final CI stages and make sure the job definition points to this
platform branch:

```bash
kubectl exec -n jenkins jenkins-0 -c jenkins -- \
  find /var/jenkins_home/jobs/team-a/jobs/sample-react-app \
  -name config.xml
```

Also verify that Docker Hub credentials are valid and BuildKit is ready:

```bash
kubectl get deployment,service,pods -n jenkins -l app=buildkitd
```

### API is waiting or restarting

```bash
kubectl get pods -n team-a
kubectl logs -n team-a statefulset/sample-react-app-mysql --tail=50
kubectl logs -n team-a deployment/sample-react-app-api -c vault-agent --tail=50
kubectl logs -n team-a deployment/sample-react-app-api -c api --tail=50
```

If `/vault/secrets/api.env` is absent, verify that Vault is unsealed, rerun
`vault-setup.sh`, and recreate the API pod so the admission webhook can inject
Vault Agent.

### Route is not accepted

```bash
kubectl get gateway native-gateway
kubectl describe httproute sample-react-app -n team-a
```

The route must reference `native-gateway` and have accepted/resolved
conditions. Follow module 01 if the Gateway itself is missing.

## Offline validation

From the repository root:

```bash
make validate
```

This checks repository syntax and manifests without changing the cluster.
