variable "region" {
  description = <<-EOT
    AWS region to deploy into. Deliberately has no default.

    Kubernetes version availability, instance-family availability, Spot pool
    depth and Availability Zone count all vary by region. A default region would
    encode a guess about someone else's account as an invisible assumption, and
    the resulting failure would not look like a region problem. Set it
    explicitly, and run the pre-flight checks in the README first.
  EOT
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]$", var.region))
    error_message = "Region must look like an AWS region identifier, for example eu-west-1 or us-east-2."
  }
}

variable "allowed_account_ids" {
  description = <<-EOT
    AWS account IDs this configuration is permitted to deploy into. Required,
    with no default.

    Terraform picks up credentials from the standard AWS chain, which means a
    forgotten AWS_PROFILE, a stale exported session or a shared `[default]`
    profile silently decides which account gets a new VPC, an EKS cluster and a
    NAT Gateway. That failure is quiet, it is expensive, and on a production
    account it is worse than expensive.

    Naming the account turns "whichever credentials happened to be loaded" into
    a value the plan has to agree with. If the caller is in a different account,
    the provider stops before creating anything.

    Find yours:
      aws sts get-caller-identity --query Account --output text

    Keep the value out of version control — pass it on the command line or in a
    tfvars file, which .gitignore already excludes.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.allowed_account_ids) > 0
    error_message = "At least one account ID is required. This is a guardrail against deploying into whichever account your credentials happen to point at."
  }

  validation {
    condition     = alltrue([for a in var.allowed_account_ids : can(regex("^[0-9]{12}$", a))])
    error_message = "Each entry must be a 12-digit AWS account ID. Find yours with: aws sts get-caller-identity --query Account --output text"
  }
}

variable "name" {
  description = <<-EOT
    Name prefix for every resource, and the value used for the
    karpenter.sh/discovery tag. Karpenter finds its subnets and security groups
    by that tag rather than by ID, so this string is part of the wiring, not
    just a label.
  EOT
  type        = string
  default     = "opsfleet-poc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "Name must be lowercase alphanumeric with hyphens, 3-32 characters, and must be a valid EKS cluster name."
  }
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes minor version for the EKS cluster.

    1.36 is chosen because the whole chain was verified against current
    documentation: EKS standard support, Karpenter >= 1.13 required (1.14.0 is
    current), managed add-ons published, and AWS's own Karpenter getting-started
    guide currently runs this exact pair. 1.35 is a supported fallback and is a
    single-variable change.

    Verify availability in your region before deploying:
      aws eks describe-cluster-versions --region <region>
  EOT
  type        = string
  default     = "1.36"

  validation {
    condition     = can(regex("^1\\.(3[4-9]|[4-9][0-9])$", var.kubernetes_version))
    error_message = "kubernetes_version must be 1.34 or later. Earlier versions are in extended support, which costs 6x more per cluster-hour."
  }
}

variable "karpenter_version" {
  description = <<-EOT
    Karpenter Helm chart version. The chart and the controller are released
    together.

    Must satisfy the published compatibility matrix for the chosen Kubernetes
    version: 1.36 requires Karpenter >= 1.13, 1.35 requires >= 1.9. Karpenter
    follows semantic versioning at v1.x and puts breaking changes in minor
    releases, so read the upgrade notes before moving this.

    Pinned rather than floating: a moving chart version in a deployment whose
    stated goal is reproducibility is a contradiction.
  EOT
  type        = string
  default     = "1.14.0"

  validation {
    condition     = can(regex("^1\\.(1[3-9]|[2-9][0-9])\\.[0-9]+$", var.karpenter_version))
    error_message = "karpenter_version must be 1.13.0 or later, which is the minimum for Kubernetes 1.36. If deploying against 1.35, 1.9+ is sufficient and this validation can be relaxed deliberately."
  }
}

variable "endpoint_public_access_cidrs" {
  description = <<-EOT
    CIDR blocks allowed to reach the public EKS API server endpoint.

    Deliberately has no default. The upstream default is 0.0.0.0/0, and a
    configuration whose secure operation depends on the operator remembering to
    override an insecure default is not secure.

    Normally this is your own address as a /32:
      echo "[\"$(curl -s https://checkip.amazonaws.com)/32\"]"

    Authentication is still IAM — a public endpoint is not an unauthenticated
    endpoint. This is defence in depth, and it is the layer that still stands if
    credentials leak.
  EOT
  type        = list(string)

  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0
    error_message = "At least one CIDR block is required. To have no public endpoint at all, set endpoint_public_access = false instead."
  }

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(cidrhost(c, 0))])
    error_message = "Every entry must be a valid CIDR block, for example 203.0.113.10/32."
  }

  validation {
    condition     = !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "0.0.0.0/0 exposes the Kubernetes API server to the entire internet. Pass an explicit allowlist. If you genuinely need this, change it here deliberately rather than inheriting it."
  }
}

variable "endpoint_public_access" {
  description = <<-EOT
    Whether the EKS API server has a public endpoint.

    True for this proof of concept: Terraform and kubectl run from a developer
    workstation, and a private-only endpoint would require a VPN, a bastion or
    an SSM tunnel — infrastructure that demonstrates nothing about Karpenter.
    Production inverts this; see the README.
  EOT
  type        = bool
  default     = true
}

variable "vpc_cidr" {
  description = <<-EOT
    CIDR block for the VPC. A /16 gives the private subnets room to be /20 each,
    which matters because the VPC CNI assigns pod IP addresses from the subnet —
    node capacity is bounded by subnet size, and IP exhaustion is the classic EKS
    wall.
  EOT
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid CIDR block of /20 or larger (a smaller prefix number)."
  }
}

variable "az_count" {
  description = <<-EOT
    Number of Availability Zones to spread subnets across.

    Three is the default because each instance-type-per-AZ pair is an
    independent EC2 Spot capacity pool, and more pools is free capacity
    insurance. The value is clamped to the number of zones the region actually
    has, so a two-AZ region still works.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 6
    error_message = "az_count must be between 2 and 6. Two is the minimum for any meaningful Spot or availability story."
  }
}

variable "single_nat_gateway" {
  description = <<-EOT
    Use one NAT Gateway for all private subnets instead of one per Availability
    Zone.

    Defaults to true because this is a short-lived proof of concept: one NAT
    costs a third of three, and the failure it exposes us to — losing egress if
    that one zone fails — costs a re-run rather than an outage. Production
    inverts this. See README, "Cost" and "Deliberately out of scope".
  EOT
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to every resource, merged with the defaults set in locals."
  type        = map(string)
  default     = {}
}
