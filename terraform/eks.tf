# EKS cluster and the bootstrap compute that Karpenter will later run on.
#
# Karpenter itself is added in the next phase. This file deliberately stops at
# "a cluster with enough capacity to host a controller", because the bootstrap
# layer should be boring.

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.24"

  name               = var.name
  kubernetes_version = var.kubernetes_version

  vpc_id = module.vpc.vpc_id
  # Control plane ENIs and all nodes live in the private subnets.
  subnet_ids = module.vpc.private_subnets

  ############################################################################
  # API server endpoint
  #
  # Public access is on because Terraform and kubectl run from a workstation,
  # but the allowlist is a required input with no default — see variables.tf.
  # Private access stays on so in-cluster traffic to the API server never
  # leaves the VPC.
  ############################################################################

  endpoint_public_access       = var.endpoint_public_access
  endpoint_private_access      = true
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  ############################################################################
  # Access management
  #
  # API mode only. The aws-auth ConfigMap is not used at all: a malformed edit
  # to it can lock every principal out of the cluster with no undo, whereas
  # access entries are AWS resources and the recovery path does not run through
  # the cluster you are locked out of.
  #
  # The module default is API_AND_CONFIG_MAP, which would leave the ConfigMap
  # path available. Set explicitly rather than inherited.
  ############################################################################

  authentication_mode = "API"

  # Grants the identity running Terraform cluster-admin, via an access entry.
  # The module default is false, so this is a deliberate grant and not an
  # accident of who happened to create the cluster. It is what makes the
  # verification procedure work from the operator's workstation.
  #
  # In production this would be an SSO group mapped to a namespace-scoped role
  # instead, with no standing cluster-admin for anyone and none for CI.
  enable_cluster_creator_admin_permissions = true

  ############################################################################
  # Encryption
  #
  # EKS enables envelope encryption of all Kubernetes API data by default on
  # 1.28 and later, using KMS v2 with an AWS-owned key, at no cost and with no
  # configuration. Setting encryption_config = null keeps that default and stops
  # the module creating a customer-managed key.
  #
  # A CMK is the right choice when key ownership, key-policy control, or an
  # auditable CloudTrail record of key use is actually required. It is the wrong
  # choice here: it adds a monthly charge and a failure mode where disabling or
  # deleting the key degrades the cluster beyond recovery — a poor trade for a
  # cluster that exists for a few hours.
  ############################################################################

  create_kms_key    = false
  encryption_config = null

  ############################################################################
  # Control plane logging
  #
  # api          — what was requested of the API server
  # audit        — who did what, the attributable record
  # authenticator — IAM-to-Kubernetes authentication, the first place to look
  #                 when kubectl returns 401 or 403
  #
  # controllerManager and scheduler are omitted: they are high-volume, they
  # answer questions this proof of concept does not ask, and CloudWatch charges
  # by ingested volume. In production they earn their place when diagnosing
  # scheduling or controller behaviour, and would be enabled deliberately.
  ############################################################################

  enabled_log_types                      = ["api", "audit", "authenticator"]
  create_cloudwatch_log_group            = true
  cloudwatch_log_group_retention_in_days = 7 # short-lived stack; production sets this to the detection window

  ############################################################################
  # Managed add-ons
  #
  # Only what is needed to have a working cluster that Karpenter can later run
  # on. eks-pod-identity-agent is the one that is easy to forget and hard to
  # diagnose: without it, Pod Identity fails silently and the controller reports
  # AccessDenied with no mention of the agent.
  #
  # Versions are intentionally not pinned yet — see the README, "Add-on
  # versions". They become explicit pins once pre-flight has enumerated the
  # versions actually available for this Kubernetes version.
  ############################################################################

  addons = {
    # Created before any node joins, so nodes never come up without a CNI.
    vpc-cni = {
      before_compute = true
      most_recent    = true
    }
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent = true
    }
  }

  ############################################################################
  # Bootstrap node group
  #
  # Karpenter is a pod and needs a node before it can provision any. This is
  # that node group, and nothing else runs here.
  #
  # Two nodes, not one: a single node makes the whole control loop a
  # single-node failure domain, and it gives the Karpenter controller's
  # replicas nowhere to spread. Two is the smallest number that is not a
  # single point of failure.
  #
  # On-demand, not Spot: the controller that manages Spot capacity must not
  # itself depend on Spot. If its node is reclaimed and nothing is left to
  # provision a replacement, the cluster cannot recover on its own.
  #
  # amd64, not Graviton: the bootstrap layer should be boring. ARM64 is
  # demonstrated later, through Karpenter, where it is the point.
  #
  # m6i.large / m5.large are 2 vCPU and 8 GiB. The Karpenter Helm chart requests
  # 1 CPU and 1 GiB per replica, and CoreDNS plus the DaemonSets take their
  # share, so a 4 GiB instance would leave almost no headroom. Two instance
  # types of identical shape so the node group is not blocked if one is
  # unavailable in a zone.
  ############################################################################

  eks_managed_node_groups = {
    system = {
      ami_type       = "AL2023_x86_64_STANDARD"
      capacity_type  = "ON_DEMAND"
      instance_types = ["m6i.large", "m5.large"]

      min_size     = 2
      desired_size = 2

      # Equal to desired_size, not higher. A managed node group can temporarily
      # run up to max_size during an update, and 3 x m6i.large is 6 vCPU —
      # above the 5 vCPU default quota on a new account. Growth belongs to
      # Karpenter anyway, so there is nothing to gain from headroom here.
      max_size = 2

      labels = {
        "node-role" = "system"
      }
    }
  }

  # Karpenter's EC2NodeClass selects security groups by tag, the same way it
  # selects subnets. Applied now so the tag is not retrofitted in the phase that
  # depends on it.
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.name
  }

  tags = local.tags
}
