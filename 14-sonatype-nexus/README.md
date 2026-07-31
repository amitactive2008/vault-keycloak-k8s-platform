# Sonatype Nexus Repository

Single-node Sonatype Nexus Repository 3.94 for the local kind platform. It runs
in the `artifactory` namespace and is exposed through Envoy Gateway at
`https://nexus.kind.local`.

> **Study-only configuration.** The chart uses embedded H2 storage and a
> single `ReadWriteOnce` volume. It is not a production or highly available
> Nexus design.

## Supported Keycloak integration and license requirement

The supported Keycloak integration is Nexus Repository's native OpenID Connect
(OIDC) realm. It provisions users from Keycloak and maps the `groups` claim to
Nexus roles.

Native OIDC is a **Nexus Repository Pro feature** in self-hosted Nexus 3.86 and
later. This module uses the public OIDC REST API added in Nexus 3.93. The
repositories and local RBAC roles work in Community Edition, but supported
Keycloak authentication and authorization require a valid Pro or trial license.
The module does not install an unsupported third-party authentication plugin.

Do not commit the `.lic` file, generated Nexus admin password, or OIDC client
secret. All three remain outside Git.

## Repositories

| Name | Format | Type | Purpose |
|---|---|---|---|
| `devops` | raw | hosted | General DevOps artifacts |
| `docker-image` | Docker | hosted | Container images with path-based routing |
| `helm-charts` | Helm | hosted | Packaged Helm charts |
| `extra` | raw | hosted | Miscellaneous files |
| `maven-snapshot-team-a` | Maven 2 | hosted, snapshots only | Team A Maven/JAR snapshots |
| `maven-snapshot-team-b` | Maven 2 | hosted, snapshots only | Team B Maven/JAR snapshots |

Nexus repository names are normalized to lowercase; therefore the requested
`Devops` repository is created as `devops`.

## Authorization model

Anonymous access is disabled. "Everyone" means every authenticated Keycloak
user, including users added to other groups later.

| Keycloak identity | Nexus role | Effective access |
|---|---|---|
| Any authenticated user | `nexus-read-all` through Default Role Realm | Read and browse every repository |
| `devops` group | `devops` | Add, edit, delete, read, browse, and upload in every repository |
| `team-a` group | `team-a` | Full component access to `maven-snapshot-team-a`; read all others |
| `team-b` group | `team-b` | Full component access to `maven-snapshot-team-b`; read all others |

The `devops` role manages repository content but intentionally does not grant
Nexus server administration (`nx-admin`). This follows the requirement for full
access to all repositories without also granting license, realm, or system
configuration access.

## Files

| Path | Purpose |
|---|---|
| `nexus-chart/` | Local Helm chart: PVC, Deployment, Service, and HTTPRoute |
| `values.yaml` | Environment-specific image, storage, and Gateway values |
| `setup.sh` | Deploy Nexus and idempotently create repositories and local RBAC |
| `configure-keycloak.sh` | Create/update the Keycloak client and `groups` mapper |
| `install-license.sh` | Upload a user-supplied Pro/trial license and restart Nexus |
| `configure-oidc.sh` | Configure native OIDC, required realms, and claim mappings |

## Prerequisites

- Modules 01 and 03 are complete.
- `native-gateway` is Programmed and the wildcard certificate is Ready.
- The `kind` Keycloak realm contains `devops`, `team-a`, and `team-b`.
- At least 20 GiB of local kind storage and roughly 3 GiB of memory are
  available for Nexus.
- A Nexus Repository Pro/trial license is available for Keycloak SSO.

## Step 1 — Add local DNS

```bash
echo "127.0.0.1 nexus.kind.local" | sudo tee -a /etc/hosts
```

## Step 2 — Deploy and provision Community features

The first run deploys Nexus, creates a random admin password in a Kubernetes
Secret, and then pauses if the Community Edition EULA is not accepted:

```bash
cd 14-sonatype-nexus
./setup.sh
```

Read the EULA URL displayed by Nexus. If you accept it, explicitly rerun:

```bash
ACCEPT_NEXUS_EULA=true ./setup.sh
```

`ACCEPT_NEXUS_EULA=true` records your acceptance in Nexus. The script then
creates all six repositories, disables anonymous access, creates the four local
roles, and enables `nexus-read-all` as the default authenticated-user role.

Retrieve the runtime admin password only when needed:

```bash
kubectl get secret nexus-admin-credentials -n artifactory \
  -o jsonpath='{.data.password}' | base64 --decode
echo
```

## Step 3 — Configure Keycloak

```bash
./configure-keycloak.sh
```

The script creates the confidential `nexus-repository` client with:

- callback: `https://nexus.kind.local/oidc/callback*`
- standard authorization-code flow
- flat `groups` claim in ID, access, and userinfo tokens
- runtime client secret in
  `Secret/nexus-oidc-client` in the `artifactory` namespace

## Step 4 — Install the Pro or trial license

Keep the license outside the repository and pass its absolute path:

```bash
./install-license.sh /absolute/path/to/nexus-repository.lic
```

The script uploads the license through the supported licensing API and restarts
Nexus so Pro features become active.

## Step 5 — Configure native OIDC

```bash
./configure-oidc.sh
```

This configures these Keycloak claims:

| Nexus field | Keycloak value |
|---|---|
| Username | `preferred_username` |
| First name | `given_name` |
| Last name | `family_name` |
| Email | `email` |
| Groups | `groups` |
| JWT algorithm | `RS256` |

It also enables OAuth2, Docker token, user token, local authentication, and
Default Role realms. The local admin remains available for recovery.

## Step 6 — Validate browser access

Open `https://nexus.kind.local`, choose **Continue with SSO**, and test:

1. `team-a-user-1` can upload only to `maven-snapshot-team-a`.
2. `team-b-user-1` can upload only to `maven-snapshot-team-b`.
3. `devops-user-1` can upload to every repository.
4. All three users can browse/download from every repository.
5. An unauthenticated request receives `401`.

Nexus role IDs `devops`, `team-a`, and `team-b` intentionally match the exact
flat group names sent by Keycloak. In **Settings → Security → Roles**, verify
the OAuth2 external roles show the matching local permissions after the first
login.

## Client usage

Browser SSO is not used directly by Maven, Docker, or Helm clients. After an
SSO login, create a Nexus user token and use the token name/passcode in client
configuration.

### Maven Team A

```xml
<server>
  <id>team-a-snapshots</id>
  <username>${env.NEXUS_TOKEN_NAME}</username>
  <password>${env.NEXUS_TOKEN_PASSCODE}</password>
</server>
```

```xml
<snapshotRepository>
  <id>team-a-snapshots</id>
  <url>https://nexus.kind.local/repository/maven-snapshot-team-a/</url>
</snapshotRepository>
```

Team B uses
`https://nexus.kind.local/repository/maven-snapshot-team-b/`.

### Helm

```bash
curl --user "${NEXUS_TOKEN_NAME}:${NEXUS_TOKEN_PASSCODE}" \
  --upload-file my-chart-0.1.0.tgz \
  https://nexus.kind.local/repository/helm-charts/my-chart-0.1.0.tgz
```

### Docker

Path-based Docker routing is enabled:

```bash
printf '%s' "${NEXUS_TOKEN_PASSCODE}" | docker login nexus.kind.local \
  --username "${NEXUS_TOKEN_NAME}" \
  --password-stdin
docker tag my-app:1.0 nexus.kind.local/docker-image/my-app:1.0
docker push nexus.kind.local/docker-image/my-app:1.0
```

## Verification commands

```bash
kubectl get pods,pvc,service,httproute -n artifactory
kubectl get httproute nexus -n artifactory \
  -o jsonpath='{.status.parents[0].conditions}'
curl https://nexus.kind.local/service/rest/v1/status
```

List repositories with the local admin credential without printing it:

```bash
NEXUS_ADMIN_PASSWORD=$(kubectl get secret nexus-admin-credentials \
  -n artifactory -o jsonpath='{.data.password}' | base64 --decode)
curl --user "admin:${NEXUS_ADMIN_PASSWORD}" \
  https://nexus.kind.local/service/rest/v1/repositories
unset NEXUS_ADMIN_PASSWORD
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `Missing or invalid license` from `/security/oauth2` | Community Edition is active | Install a Pro/trial license and restart |
| `PKIX path building failed` | The platform CA was not imported | Rerun `setup.sh`; it rebuilds the Nexus JVM truststore |
| Keycloak login works but write is denied | Group claim or matching role is missing | Verify flat `groups` mapper and exact lowercase role/group names |
| Maven or Docker rejects the SSO password | Format clients do not perform browser SSO | Use a Nexus user token |
| Docker path returns `404` | Path-based routing is disabled or image path omits repository | Rerun `setup.sh` and use `nexus.kind.local/docker-image/...` |
| Pod stays Pending | Insufficient memory or PVC capacity | Free kind resources or adjust `values.yaml` |

## Uninstall

```bash
helm uninstall nexus -n artifactory
kubectl delete namespace artifactory
```

Deleting the namespace also removes the PVC, repositories, runtime passwords,
and OIDC client secret from the cluster.
