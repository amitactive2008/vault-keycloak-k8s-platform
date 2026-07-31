# Gitea Package Registry

Single-node Gitea 1.26 Package Registry for the local kind platform. It runs in
the `artifactory` namespace and is exposed through Envoy Gateway at
`https://gitea.kind.local`.

> **Study-only configuration.** The chart uses SQLite and one `ReadWriteOnce`
> volume. It is intentionally small and is not a production or highly
> available Gitea design.

Gitea is used here only as an artifact registry. Gitea Actions and Git over SSH
and HTTP are disabled because Jenkins and the existing source repositories
remain the CI/CD and source-control systems.

## Why Gitea

Gitea provides an MIT-licensed package registry and supports Keycloak through
OpenID Connect without a commercial license.

Gitea packages belong to a user or organization. This module creates six
private organization namespaces that preserve the requested public names:

| Package owner | Format used | Purpose |
|---|---|---|
| `devops` | Generic | General DevOps artifacts |
| `docker-image` | OCI Container | Docker/OCI images |
| `helm-charts` | Helm | Packaged Helm charts |
| `extra` | Generic | Miscellaneous files |
| `maven-snapshot-team-a` | Maven | Team A Maven/JAR snapshots |
| `maven-snapshot-team-b` | Maven | Team B Maven/JAR snapshots |

Gitea does not enforce a snapshot-only Maven policy. Jenkins must publish
`-SNAPSHOT` versions to the two Maven namespaces. Gitea also rejects an upload
when the same Maven name and version already exists, so CI should use unique
snapshot versions or delete the old version before republishing.

## Authorization model

Anonymous access and local self-registration are disabled. The setup adds
`artifact-readers` as a default Keycloak group and assigns it to existing realm
users.

| Keycloak group | Gitea team mapping | Effective package access |
|---|---|---|
| `artifact-readers` | `Readers` in every package owner | Read all packages |
| `devops` | `Publishers` in every package owner | Upload and delete all packages |
| `team-a` | `Publishers` in `maven-snapshot-team-a` | Manage Team A Maven packages |
| `team-b` | `Publishers` in `maven-snapshot-team-b` | Manage Team B Maven packages |

Group-to-team membership is reconciled every time a user signs in through
Keycloak. The local `admin` account is retained only for recovery and initial
automation.

## Files

| Path | Purpose |
|---|---|
| `gitea-chart/` | Local Helm chart with PVC, Deployment, Service, and HTTPRoute |
| `values.yaml` | Environment-specific image, storage, and Gateway values |
| `setup.sh` | Deploy Gitea and create package owners and access teams |
| `configure-keycloak.sh` | Configure the Keycloak client, default readers group, and Gitea OIDC source |

## Prerequisites

- Modules 01 and 03 are complete.
- `native-gateway` is Programmed and the wildcard certificate is Ready.
- The `kind` Keycloak realm contains `devops`, `team-a`, and `team-b`.
- At least 20 GiB of local kind storage is available.
- `kubectl`, Helm, `curl`, Python 3, and OpenSSL are installed.

## Step 1 — Add local DNS

```bash
echo "127.0.0.1 gitea.kind.local" | sudo tee -a /etc/hosts
```

## Step 2 — Deploy and provision Gitea

```bash
cd 14-gitea-package-registry
./setup.sh
```

The script:

1. creates or reuses the `artifactory` namespace;
2. copies the local platform CA into a runtime Kubernetes Secret;
3. generates stable runtime admin, OIDC, and encryption values in
   `Secret/gitea-runtime-credentials`;
4. installs the local Helm chart;
5. creates the local recovery administrator;
6. creates all six package-owner organizations; and
7. creates `Readers` and `Publishers` teams in each organization.

The generated credentials are never written to the repository.

## Step 3 — Configure Keycloak SSO and authorization

```bash
./configure-keycloak.sh
```

The script creates or updates:

- confidential Keycloak client `gitea-package-registry`;
- callback
  `https://gitea.kind.local/user/oauth2/keycloak/callback`;
- flat `groups` claim in ID, access, and userinfo tokens;
- default Keycloak group `artifact-readers`;
- membership of existing users in `artifact-readers`;
- Gitea `keycloak` OpenID Connect authentication source; and
- group-to-team mappings for readers, DevOps, Team A, and Team B.

The platform CA is added to Gitea's trust bundle, so TLS verification remains
enabled for Keycloak.

## Step 4 — Log in to the UI

Open `https://gitea.kind.local` and select **Sign in with keycloak**. The demo
users from module 03 use the study-only password `password`.

Examples:

- `devops-user-1` can manage packages in all six owners.
- `team-a-user-1` can manage Team A Maven packages and read all others.
- `team-b-user-1` can manage Team B Maven packages and read all others.

For local recovery, select the normal **Sign In** form and use username `admin`.
Retrieve its generated password only when needed:

```bash
kubectl get secret gitea-runtime-credentials -n artifactory \
  -o jsonpath='{.data.admin-password}' | base64 --decode
echo
```

## Step 5 — Create automation tokens

Browser SSO cannot be used by Jenkins, Maven, Docker, or Helm. Sign in through
Keycloak, open **Settings → Applications**, and generate a token with:

- `read:package` for download-only clients; or
- `write:package` for publishers.

Use a dedicated Keycloak/Jenkins service identity instead of a personal token
for pipelines. Store the username and token in Vault, not in Git or Jenkins
JCasC. The existing DevOps CI secret can be extended without printing values:

```bash
vault kv patch secret/devops/jenkins/ci \
  gitea_username="${GITEA_USERNAME}" \
  gitea_token="${GITEA_TOKEN}" \
  gitea_registry="gitea.kind.local"
unset GITEA_USERNAME GITEA_TOKEN
```

The Jenkins Vault policy must explicitly allow that path, as module 08 already
does for `secret/data/devops/jenkins/ci`.

## Package client examples

### Maven Team A

Add the token to Maven `settings.xml`:

```xml
<server>
  <id>gitea-team-a</id>
  <configuration>
    <httpHeaders>
      <property>
        <name>Authorization</name>
        <value>token ${env.GITEA_TOKEN}</value>
      </property>
    </httpHeaders>
  </configuration>
</server>
```

Use this snapshot repository in `pom.xml`:

```xml
<snapshotRepository>
  <id>gitea-team-a</id>
  <url>https://gitea.kind.local/api/packages/maven-snapshot-team-a/maven</url>
</snapshotRepository>
```

Team B uses:

```text
https://gitea.kind.local/api/packages/maven-snapshot-team-b/maven
```

### Docker/OCI images

```bash
printf '%s' "${GITEA_TOKEN}" | docker login gitea.kind.local \
  --username "${GITEA_USERNAME}" \
  --password-stdin
docker tag my-app:1.0 gitea.kind.local/docker-image/my-app:1.0
docker push gitea.kind.local/docker-image/my-app:1.0
```

### Helm charts

The native Gitea Helm registry uses an HTTP chart upload:

```bash
curl --fail-with-body \
  --user "${GITEA_USERNAME}:${GITEA_TOKEN}" \
  --request POST \
  --upload-file my-chart-0.1.0.tgz \
  https://gitea.kind.local/api/packages/helm-charts/helm/api/charts
```

Add it as a chart repository:

```bash
helm repo add platform \
  --username "${GITEA_USERNAME}" \
  --password "${GITEA_TOKEN}" \
  https://gitea.kind.local/api/packages/helm-charts/helm
```

### Generic artifacts

```bash
curl --fail-with-body \
  --user "${GITEA_USERNAME}:${GITEA_TOKEN}" \
  --upload-file artifact.tar.gz \
  https://gitea.kind.local/api/packages/devops/generic/platform-bundle/1.0.0/artifact.tar.gz
```

Use owner `extra` instead of `devops` for miscellaneous artifacts.

## Verification

```bash
kubectl get pods,pvc,service,httproute -n artifactory
kubectl get httproute gitea -n artifactory \
  -o jsonpath='{.status.parents[0].conditions}'
curl https://gitea.kind.local/api/healthz
```

Because sign-in is required globally, anonymous package requests must not
return package content:

```bash
curl --output /dev/null --silent --write-out '%{http_code}\n' \
  https://gitea.kind.local/api/packages/devops/generic/example/1.0/file
```

After each user's first SSO login, verify team synchronization under the
organization's **People → Teams** page.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Sign in with keycloak` is missing | OIDC setup was not run | Run `./configure-keycloak.sh` |
| Keycloak returns an invalid redirect URI | Client callback is stale | Rerun `./configure-keycloak.sh` |
| `x509: certificate signed by unknown authority` | Platform CA Secret is stale | Rerun `./setup.sh`, then restart Gitea |
| SSO works but no package owners are visible | Group-to-team sync has not run | Sign out/in and verify the flat `groups` claim |
| Maven reports a duplicate version | Gitea does not overwrite versions | Publish a unique version or delete the old package |
| Docker or Helm rejects the Keycloak password | CLI clients do not perform browser OIDC | Use a scoped Gitea token |
| Pod stays Pending | PVC or memory capacity is unavailable | Free kind resources or adjust `values.yaml` |

## Uninstall

```bash
helm uninstall gitea -n artifactory
kubectl delete pvc gitea-data -n artifactory
kubectl delete secret gitea-runtime-credentials gitea-kind-local-ca \
  -n artifactory --ignore-not-found
```

Deleting `gitea-data` permanently removes the SQLite database and all packages.
