# team-a-policy — scoped to secret/data/team-a/* only
# Maps to Keycloak group: /team-a

# Read / write own secrets
path "secret/data/team-a/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# List and manage metadata (versions, delete markers)
path "secret/metadata/team-a/*" {
  capabilities = ["read", "list", "delete"]
}

# Delete all versions of a secret
path "secret/delete/team-a/*" {
  capabilities = ["update"]
}

# Undelete (restore) versions
path "secret/undelete/team-a/*" {
  capabilities = ["update"]
}

# Permanently destroy a version
path "secret/destroy/team-a/*" {
  capabilities = ["update"]
}
