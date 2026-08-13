# Karpenter: its AWS resources, and the controller itself.
#
# The NodePools and EC2NodeClass that tell Karpenter *what* to provision come in
# the next phase. This file gets the controller running and correctly wired.

################################################################################
# AWS resources
#
# The submodule creates, by default:
#   - the controller IAM role and a scoped policy (not EC2FullAccess)
#   - an EKS Pod Identity association binding that role to the karpenter
#     service account in kube-system
#   - a node IAM role and the instance profile Karpenter attaches to the
#     instances it launches
#   - an EKS access entry for that node role, so those instances can join
#   - an SQS queue and EventBridge rules for Spot interruption, capacity
#     rebalance and instance state change
#
# Writing those trust policies by hand is several hundred lines with a large
# surface for subtle error. The judgment being exercised is knowing what not to
# rewrite.
################################################################################

module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 21.24"

  cluster_name = module.eks.cluster_name

  # Pod Identity, not IRSA. IRSA needs an OIDC provider, a trust policy
  # templated with the cluster's issuer URL, and a service-account annotation
  # carrying a role ARN — three coupled things to keep consistent. Pod Identity
  # needs one association, and the binding is a visible AWS resource rather than
  # a Kubernetes annotation you have to know to look for.
  #
  # This is the module default; set explicitly because it is a decision.
  create_pod_identity_association = true
  namespace                       = "kube-system"
  service_account                 = "karpenter"

  # Creates the SQS queue and EventBridge rules. Without this, Karpenter has no
  # way to learn about a Spot interruption notice, and "Spot interruption
  # handling" becomes a claim rather than a mechanism.
  enable_spot_termination = true

  # Break-glass access to Karpenter-provisioned nodes without an SSH key or an
  # inbound shell port. The rest of the node role is the EKS-required minimum.
  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }

  tags = local.tags
}

################################################################################
# The controller
#
# Chart and controller are released together and the chart version is pinned:
# a floating version in a deliberately reproducible deployment is a
# contradiction.
#
# Only two things are overridden. Everything else is left at the chart's
# defaults, which are good and are load-bearing — see below.
################################################################################

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = var.karpenter_version

  # Block until the controller is actually up, so a later phase that applies
  # NodePools does not race the CRDs into existence.
  wait = true

  values = [yamlencode({
    settings = {
      clusterName = module.eks.cluster_name

      # This one line is the difference between Spot interruption handling
      # existing and merely having been provisioned. Without it the queue is
      # created and nothing reads from it.
      interruptionQueue = module.karpenter.queue_name
    }

    # The chart's own documented values. Stated explicitly because they are what
    # size the bootstrap node group: 1 CPU and 1 GiB per replica, two replicas.
    # A 4 GiB instance would leave almost nothing for CoreDNS and the DaemonSets.
    controller = {
      resources = {
        requests = { cpu = "1", memory = "1Gi" }
        limits   = { cpu = "1", memory = "1Gi" }
      }
    }
  })]

  depends_on = [module.karpenter]
}

# Chart defaults deliberately left alone, because they solve real problems:
#
#   affinity.nodeAffinity: karpenter.sh/nodepool DoesNotExist
#     Karpenter will not schedule onto a node it provisioned itself. Without
#     this a controller can end up managing the node it is running on, and
#     consolidating itself away. This is the correct mechanism, and it is why
#     no nodeSelector pinning the controller to the system node group is added
#     here — that would be a second, weaker expression of the same intent.
#
#   podAntiAffinity: requiredDuringScheduling, topologyKey kubernetes.io/hostname
#     The two replicas must land on two different nodes. With a single-node
#     bootstrap group, one replica would sit Pending forever. This is why the
#     node group has min_size = 2, and it is a hard requirement rather than a
#     preference.
#
#   topologySpreadConstraints: zone, whenUnsatisfiable DoNotSchedule
#     Those two nodes must also be in different Availability Zones, which the
#     managed node group across three private subnets provides.
#
#   priorityClassName: system-cluster-critical, and a PodDisruptionBudget
#     The controller is not evicted to make room for application workloads.
