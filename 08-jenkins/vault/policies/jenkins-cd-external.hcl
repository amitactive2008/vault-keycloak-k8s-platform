# The initial external-cluster CD agent may read only its own kubeconfig.
path "secret/data/devops/jenkins/clusters/external" {
  capabilities = ["read"]
}
