terraform {
  # 1.5.7 is the floor required by terraform-aws-modules/eks v21, which this
  # configuration adopts in the next phase. Pinning the floor now rather than
  # later keeps the requirement visible from the start.
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source = "hashicorp/aws"

      # >= 6.52 is required by terraform-aws-modules/eks v21 and >= 6.28 by
      # terraform-aws-modules/vpc v6. The ~> constraint allows patch and minor
      # updates within 6.x; .terraform.lock.hcl is the actual pin, including
      # provider checksums.
      version = "~> 6.58"
    }

    # Installs the Karpenter chart. Version 3.x changed the provider schema:
    # `kubernetes` and `exec` are attributes rather than nested blocks.
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.2"
    }
  }
}
