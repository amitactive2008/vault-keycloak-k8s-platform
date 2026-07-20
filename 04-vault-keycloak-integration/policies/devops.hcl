# devops-policy — full admin access to ALL Vault paths
# Maps to Keycloak group: /devops

path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
