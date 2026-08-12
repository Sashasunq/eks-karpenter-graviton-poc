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
