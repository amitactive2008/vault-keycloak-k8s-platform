# Jenkins CI agents may read only the shared build credentials.
path "secret/data/devops/jenkins/ci" {
  capabilities = ["read"]
}
