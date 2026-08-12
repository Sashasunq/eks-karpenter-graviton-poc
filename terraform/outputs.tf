output "region" {
  description = "Region this configuration is deployed into."
  value       = var.region
}

output "name" {
  description = "Resource name prefix, and the value of the karpenter.sh/discovery tag."
  value       = var.name
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  description = "CIDR block of the VPC."
  value       = module.vpc.vpc_cidr_block
}

output "azs" {
  description = "Availability Zones actually used, after clamping az_count to what the region offers."
  value       = module.vpc.azs
}

output "private_subnets" {
  description = "Private subnet IDs. Nodes are placed here; these carry the karpenter.sh/discovery tag."
  value       = module.vpc.private_subnets
}

output "public_subnets" {
  description = "Public subnet IDs. NAT Gateway and future internet-facing load balancers only."
  value       = module.vpc.public_subnets
}

output "nat_public_ips" {
  description = "Public IP addresses of the NAT Gateway(s) — the egress addresses of the whole cluster."
  value       = module.vpc.nat_public_ips
}
