# The EC2NodeClass and the two NodePools — what Karpenter is allowed to
# provision.
#
# Applied as a small local Helm chart rather than as Terraform resources. Both
# obvious alternatives are worse here:
#
#   kubernetes_manifest requires the CRDs to exist at *plan* time, and the CRDs
#   arrive with the Karpenter chart in this same apply. A first run would fail
#   on a plan, not on anything real.
#
#   A third-party kubectl provider solves that, at the cost of adding an
#   unmaintained-by-HashiCorp dependency to a configuration whose supply chain
#   is otherwise pinned to the official registry.
#
# A chart uses the Helm provider that is already here, applies at apply time so
# the CRD ordering works, and keeps the manifests readable as Kubernetes YAML in
# charts/karpenter-resources/templates/ — which is what a reviewer wants to see.

resource "helm_release" "karpenter_resources" {
  name      = "karpenter-resources"
  namespace = "kube-system"
  chart     = "${path.module}/charts/karpenter-resources"

  values = [yamlencode({
    nodeIamRoleName = module.karpenter.node_iam_role_name
    discoveryTag    = var.name
    amiAlias        = var.ami_alias
    zones           = module.vpc.azs

    cpuLimit         = var.nodepool_cpu_limit
    expireAfter      = "720h"
    consolidateAfter = var.consolidate_after

    tags = local.tags
  })]

  # The CRDs ship with the Karpenter chart, so that release has to land first.
  #
  # module.eks and module.vpc for the destroy-ordering reason explained in
  # karpenter.tf: removing *this* release is what deletes the EC2NodeClass, and
  # its finalizer needs both a reachable API server and a working egress path to
  # IAM before it will let go.
  depends_on = [helm_release.karpenter, module.eks, module.vpc]
}
