# Runtime AI BankApp pods may read only their Team B application values.
path "secret/data/team-b/ai-bankapp" {
  capabilities = ["read"]
}
