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
