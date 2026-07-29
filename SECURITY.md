# Security policy

## Scope

This project is a local learning environment, not a production reference
architecture. Several checked-in passwords are intentionally predictable demo
values. Run it only on a trusted workstation and disposable local cluster.

## Never commit

- `02-vault/cluster-keys.json`
- `05-k8s-oidc-with-keycloak/kubeconfig-oidc.yaml`
- `05-k8s-oidc-with-keycloak/keycloak-local-ca.crt`
- `08-jenkins/setup/credentials.yaml`
- private keys, API keys, access tokens, or local `.env` files

Use the checked-in `.example` and `-template` files instead.

## Exposed credential response

If a real credential is committed:

1. Revoke or rotate it immediately.
2. Remove it from the current tree.
3. Purge it from Git history if the repository was shared.
4. Invalidate derived credentials, such as kubeconfig client certificates, when
   appropriate.

Deleting a file in a new commit does not remove it from earlier commits.

## Required rotation after repository cleanup

`08-jenkins/setup/credentials.yaml` was previously tracked even though it was
documented as a local-only file. Before sharing this repository, rotate the
Docker registry credential and NVD API key that were stored there, and recreate
the kind cluster or otherwise invalidate the embedded kubeconfig client
certificate. Purge the file from Git history if any earlier commit was pushed.

## Reporting

Do not open a public issue containing a working secret. Contact the repository
owner privately with the affected path, commit, and suggested remediation.
