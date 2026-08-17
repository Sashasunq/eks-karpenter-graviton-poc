provider "aws" {
  region = var.region

  # The guardrail that matters most in this file.
  #
  # Credentials come from the standard AWS chain, so the account being deployed
  # into is decided by whatever happened to be loaded — a shared `[default]`
  # profile, a stale exported session, a forgotten AWS_PROFILE. Getting that
  # wrong creates a VPC, an EKS cluster and a NAT Gateway somewhere they do not
  # belong, and on a production account the consequence is not just a bill.
  #
  # With this set, the provider verifies the caller's account before creating
  # anything and stops if it is not one you named.
  allowed_account_ids = var.allowed_account_ids

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

      # --output json is not redundant. The exec plugin expects an
      # ExecCredential object on stdout, and the AWS CLI honours whatever
      # `output` the operator's profile sets. With `output = table` — a
      # perfectly ordinary setting — `aws eks get-token` prints an ASCII table
      # and the provider fails with:
      #
      #   Kubernetes cluster unreachable: getting credentials: decoding stdout:
      #   couldn't get version/kind; json parse error
      #
      # which points at the cluster rather than at a CLI setting. Forcing the
      # format here makes the configuration independent of the operator's
      # profile, which is what "reproducible on someone else's machine" means.
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region, "--output", "json"]
    }
  }
}
