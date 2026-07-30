# Repository guide for coding agents

## Purpose

This repository is a local, study-only Kubernetes platform built in numbered
deployment order. It combines kind, Envoy Gateway, cert-manager, Vault,
Keycloak, monitoring, Jenkins, and sample workloads.

Treat the repository as infrastructure code. Prefer small, reviewable changes
that preserve the existing learning flow.

## Read before changing files

1. Read this file and the root `README.md`.
2. Read the `README.md` in every numbered module you will edit.
3. Check `git status --short`; never overwrite unrelated user changes.
4. Follow the numbered dependency order. A later module may depend on names,
   namespaces, hostnames, secrets, or resources defined by an earlier module.

## Repository map

| Path | Responsibility |
|---|---|
| `01-cloud-provider-kind-setup-with-gw-api/` | kind cluster, Gateway API, Envoy Gateway, cert-manager |
| `02-vault/` | Vault HA/Raft deployment |
| `03-keycloak/` | Keycloak and PostgreSQL Helm chart |
| `04-vault-keycloak-integration/` | Vault OIDC policies and Keycloak integration |
| `05-k8s-oidc-with-keycloak/` | Kubernetes API OIDC and team RBAC |
| `06-application/` | Vault Agent sample web application |
| `07-monitoring/` | Prometheus, Grafana, Alertmanager, blackbox exporter |
| `08-jenkins/` | Jenkins, SonarQube, JCasC, and job definitions |
| `09-sample-app-react-and-nodejs/` | Team A application deployment and CI/CD manifests |
| `10-ai-bankapp/` | Team B Spring Boot, MySQL, Ollama, Vault, and Jenkins example |
| `11-argocd/`, `12-valero-backup/`, `13-istio/` | Planned modules; see their local READMEs |

## Change rules

- Keep module numbers and public resource names stable unless the task explicitly
  requires a migration.
- Use Gateway API `HTTPRoute` resources for local ingress. Do not reintroduce
  nginx Ingress resources.
- Keep shell scripts in Bash with `set -euo pipefail`. Quote expansions unless
  intentional word splitting is documented.
- Keep reusable defaults in chart `values.yaml` files and environment-specific
  values in the module-level override file.
- Make setup scripts idempotent when practical.
- Update the closest README whenever commands, paths, dependencies, hostnames,
  credentials, or behavior change.
- Do not add generated output, vendored dependencies, cluster state, or local
  absolute paths.

## Security boundaries

The checked-in passwords are intentionally insecure demo values and must never
be presented as production defaults. Never commit:

- Vault unseal keys or root tokens
- kubeconfig files, client keys, or generated CA copies
- Jenkins runtime credentials
- API keys, access tokens, private keys, or `.env` files

Use an `.example` or `-template` file with unmistakable placeholders. If a
secret is found in Git history, remove it from the current tree and tell the
maintainer to rotate it; deleting a file does not revoke or erase the secret.

## Validation

Run from the repository root:

```bash
make validate
```

The command performs offline checks for conflict markers, secrets, Bash syntax,
JSON syntax, YAML syntax, Markdown links, Helm charts, and Kustomize overlays.
Some checks are skipped with an explicit message when their optional tool is not
installed.

Do not run cluster-mutating commands as validation unless the user asks for an
integration test. State which checks were run and any checks that were skipped.
