provider "aws" {
  region = var.region

  # No profile, no access keys, no account ID anywhere in this repository.
  # Credentials come from the standard AWS provider chain — environment
  # variables, an SSO session, an assumed role, or an instance/container role.
  # That keeps the configuration portable and leaves no static credential to
  # leak or rotate.

  default_tags {
    tags = local.tags
  }
}

# The Helm provider talks to the cluster this same configuration creates.
#
# Authentication is an exec plugin rather than a stored token or kubeconfig. A
# token fetched once at plan time expires; `aws eks get-token` mints a fresh one
# for each operation. A kubeconfig is worse still — it is a snapshot, and
# recreating the cluster changes its endpoint and CA, so any stored copy is
# wrong from that moment on.
#
# The endpoint and CA data are read from the EKS module directly. They are
# deliberately not Terraform outputs: consuming them internally keeps them out
# of the terminal and out of anything that reads outputs.
#
# Consequence worth knowing: on a cold run, before the cluster exists, these
# values are unknown at plan time. See the README, "Planning before the cluster
# exists".
provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}
