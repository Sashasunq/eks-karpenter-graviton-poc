# Networking for the EKS + Karpenter proof of concept.
#
# Nothing here is EKS-specific in the sense of depending on a cluster existing —
# but the tags are the contract that later phases rely on, so they are applied
# now rather than retrofitted.

data "aws_availability_zones" "available" {
  state = "available"

  # Local Zones and Wavelength Zones appear in an unfiltered list and cannot
  # host EKS nodes. Excluding opt-in zones avoids a failure that surfaces much
  # later as an unschedulable node.
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  # Clamped, not assumed: a few regions have only two Availability Zones.
  azs = slice(
    data.aws_availability_zones.available.names,
    0,
    min(var.az_count, length(data.aws_availability_zones.available.names))
  )

  # Private subnets are /20 (4091 usable addresses each with a /16 VPC). The VPC
  # CNI allocates pod IPs from the subnet, so this is what bounds how many pods
  # the zone can hold.
  private_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 4, i)]

  # Public subnets are /24 and hold only the NAT Gateway and future load
  # balancers. Numbered from 48 so they sit above the private range and the two
  # cannot collide as az_count changes.
  public_subnets = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 48)]

  tags = merge(
    {
      Project   = var.name
      ManagedBy = "terraform"
    },
    var.tags
  )
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.6"

  name = var.name
  cidr = var.vpc_cidr

  azs             = local.azs
  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # Required by the VPC CNI and by EKS private endpoint resolution.
  enable_dns_hostnames = true
  enable_dns_support   = true

  create_igw         = true
  enable_nat_gateway = true

  # One NAT Gateway rather than one per zone: see variables.tf. This is the
  # single largest cost lever in the proof of concept and the single largest
  # availability compromise, which is why it is a variable and not a constant.
  single_nat_gateway     = var.single_nat_gateway
  one_nat_gateway_per_az = !var.single_nat_gateway

  # Nodes never get public addresses. Anything that needs to be reachable gets a
  # load balancer in the public subnets instead.
  map_public_ip_on_launch = false

  public_subnet_tags = {
    # Tells the AWS Load Balancer Controller where to place internet-facing
    # load balancers. Not used in this phase; placed now so the tag is not
    # forgotten when it is.
    "kubernetes.io/role/elb" = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"

    # This is the wiring, not decoration. Karpenter's EC2NodeClass selects
    # subnets by this tag, so a missing or misplaced tag is the most common
    # Karpenter setup failure.
    #
    # Only private subnets carry it. Tagging the public subnets too would let
    # Karpenter place workload nodes with public IP addresses — a security
    # failure that would look like a typo.
    "karpenter.sh/discovery" = var.name
  }

  tags = local.tags
}
