# team-b-policy — scoped to secret/data/team-b/* only
# Maps to Keycloak group: /team-b

# Read / write own secrets
path "secret/data/team-b/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# List and manage metadata (versions, delete markers)
path "secret/metadata/team-b/*" {
  capabilities = ["read", "list", "delete"]
}

# Delete all versions of a secret
path "secret/delete/team-b/*" {
  capabilities = ["update"]
}

# Undelete (restore) versions
path "secret/undelete/team-b/*" {
  capabilities = ["update"]
}

# Permanently destroy a version
path "secret/destroy/team-b/*" {
  capabilities = ["update"]
}
