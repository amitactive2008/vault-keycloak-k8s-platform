# Team B CI agents may read only the AI BankApp build credentials.
path "secret/data/team-b/jenkins/ci" {
  capabilities = ["read"]
}
