# Contributing

This repository is organized as a numbered learning path. Contributions should
keep each step understandable, reproducible, and safe to review.

## Workflow

1. Create a focused branch from the intended base branch.
2. Read `AGENTS.md`, the root `README.md`, and the README for the module you are
   changing.
3. Make one logical change at a time.
4. Update documentation beside the affected manifests or scripts.
5. Run `make validate`.
6. Review `git diff --check` and `git diff` before committing.

Use conventional commit subjects when possible:

```text
feat(vault): add audit device configuration
fix(keycloak): preserve gateway hostname
docs: clarify local TLS bootstrap
chore: improve repository validation
```

## File conventions

- YAML: two-space indentation and one logical resource per document.
- Shell: Bash, executable mode, `set -euo pipefail`, and quoted variables.
- Helm: defaults in chart values; local overrides in the parent module.
- Kubernetes: explicit namespaces and stable labels.
- Documentation: relative links and commands that run from the documented
  directory.

## Secrets

Never commit generated credentials or cluster identity material. Copy template
files locally, fill in your values, and leave the generated file ignored:

```bash
cp 08-jenkins/setup/credentials-template.yaml \
  08-jenkins/setup/credentials.yaml
```

See `SECURITY.md` for the demo security model and reporting guidance.

## Pull requests

Describe the behavior change, affected modules, validation performed, and any
manual migration or teardown needed. Screenshots are useful only for UI-facing
changes.

