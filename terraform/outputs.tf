# Outputs are limited to what an operator or a later phase actually consumes.
#
# Terraform state is sensitive, and every output is one more value rendered to
# the terminal and stored in state. The cluster endpoint and certificate
# authority data are deliberately not exposed: the Helm and Kubernetes providers
# read them from the module directly in the next phase, and `aws eks
# update-kubeconfig` fetches them at run time for humans.

output "region" {
  description = "Region this configuration is deployed into."
  value       = var.region
}

output "name" {
  description = "Resource name prefix, and the value of the karpenter.sh/discovery tag on subnets and the node security group."
  value       = var.name
}

output "configure_kubectl" {
  description = "Command to configure kubectl against this cluster."
  value       = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.region}"
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "cluster_version" {
  description = "Kubernetes version the control plane is actually running, which is worth checking against what was requested."
  value       = module.eks.cluster_version
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}

output "azs" {
  description = "Availability Zones actually used, after clamping az_count to what the region offers."
  value       = module.vpc.azs
}

output "private_subnets" {
  description = "Private subnet IDs. Nodes are placed here; these carry the karpenter.sh/discovery tag."
  value       = module.vpc.private_subnets
}

output "nat_public_ips" {
  description = "Public IP address(es) of the NAT Gateway — the egress address of the whole cluster, and useful when something upstream needs an allowlist entry."
  value       = module.vpc.nat_public_ips
}
