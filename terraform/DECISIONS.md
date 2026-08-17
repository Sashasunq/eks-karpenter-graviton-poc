# Design decisions

Why this stack is built the way it is, and what the rejected alternative was in each case.

The operational side — how to run it, how to verify it, how to tear it down — is in
[README.md](README.md). What happened when it was actually run is in [RUN-LOG.md](RUN-LOG.md).

---

## The cluster

Kubernetes **1.36**, chosen after checking the whole chain rather than because it is newest:

| Link | Status |
| --- | --- |
| EKS standard support | 1.36 in standard support until 2027-08-02 |
| Karpenter | 1.36 requires Karpenter >= 1.13; 1.14.0 is current |
| Vendor-tested pair | AWS's own Karpenter getting-started guide currently runs 1.36 with Karpenter 1.14.0 |
| Managed add-ons | published for 1.36 |
| `terraform-aws-modules/eks` | passes `kubernetes_version` through unconstrained |

`1.35` is a supported fallback and is a one-variable change. Verify availability in your region
before deploying — version availability is regional:

```bash
aws eks describe-cluster-versions --region "$AWS_REGION"
```

### Cluster access

**Endpoint.** Public *and* private access are both enabled. Public because Terraform and `kubectl`
run from a workstation, and a private-only endpoint would need a VPN, a bastion or an SSM tunnel —
infrastructure that demonstrates nothing about Karpenter. Private because in-cluster traffic to the
API server should not leave the VPC.

**`endpoint_public_access_cidrs` is required and has no default.** The upstream default is
`0.0.0.0/0`. A configuration whose secure operation depends on the operator remembering to override
an insecure default is not secure, so passing `0.0.0.0/0` is rejected by a variable validation. Pass
your own address:

```bash
echo "[\"$(curl -s https://checkip.amazonaws.com)/32\"]"
```

Authentication is still IAM — **a public endpoint is not an unauthenticated endpoint**. The CIDR
allowlist is defence in depth, and it is the layer still standing if credentials leak.

If you narrow this and then change networks, you lock yourself out; widen it again through the AWS
API or Terraform.

**Authorization.** `authentication_mode = "API"` — **EKS Access Entries only, no `aws-auth`
ConfigMap.** A malformed edit to that ConfigMap can lock every principal out of a cluster with no
undo. Access entries are AWS resources, so the recovery path does not run through the cluster you
are locked out of.

`enable_cluster_creator_admin_permissions = true` grants the identity running Terraform
cluster-admin via an access entry. The module default is `false`, so this is a **deliberate grant**
rather than something inherited by whoever happened to create the cluster. It is what makes the
verification procedure work from your workstation.

**In production:** private-only endpoint, access over SSM Session Manager or a VPN, no bastion with
an inbound shell port. Humans via SSO groups mapped to namespace-scoped Kubernetes roles, no
standing cluster-admin for anyone, and none at all for CI.

### Encryption

**No customer-managed KMS key is created, and that is deliberate.**

EKS enables envelope encryption of *all* Kubernetes API data by default on Kubernetes 1.28 and
later, using KMS v2 with an AWS-owned key. It costs nothing, needs no configuration and no IAM
permissions, and covers more than the secrets-only encryption that a customer-managed key
historically provided.

A customer-managed key (CMK) remains the right choice when **key ownership, key-policy control, or
an auditable CloudTrail record of key usage** is an actual requirement — compliance regimes
frequently make it one. It is the wrong choice here: it adds a monthly charge, and it adds a failure
mode where **disabling or deleting the key degrades the cluster beyond recovery**. That is a poor
trade for a cluster that exists for a few hours.

The Terraform module creates a CMK by default; `create_kms_key = false` and
`encryption_config = null` turn that off in favour of the platform default. Building a KMS key here
would be creating infrastructure to demonstrate a pattern the platform has since superseded.

EBS volumes and CloudWatch Logs are separate concerns and are not covered by this.

### Control-plane logging

Enabled: **`api`**, **`audit`**, **`authenticator`**.

- `api` — what was asked of the API server
- `audit` — who did what; the attributable record
- `authenticator` — IAM-to-Kubernetes authentication, and the first place to look when `kubectl`
  returns 401 or 403

`controllerManager` and `scheduler` are **not** enabled. They are high-volume, CloudWatch bills by
ingested volume, and they answer questions this proof of concept does not ask. In production they
earn their place when diagnosing scheduling or controller behaviour, and would be turned on
deliberately rather than by default.

Log group retention is **7 days** — enough for a stack measured in hours. Production sets retention
to at least the detection window, which is a security requirement rather than a cost one.

### Add-on versions

Four managed add-ons: `vpc-cni` (created before any node joins, so a node never comes up without a
CNI), `coredns`, `kube-proxy`, `eks-pod-identity-agent`.

**Versions are not pinned yet.** The add-ons resolve to the most recent version compatible with the
cluster's Kubernetes version. That is a deliberate, temporary position rather than an oversight:

- A pin is only meaningful against versions that have been confirmed to exist for the chosen
  Kubernetes version. Pinning from documentation before running
  `aws eks describe-addon-versions` produces a configuration that fails at apply for a reason that
  looks like a bug.
- Pinning some add-ons and not others would be worse than pinning none.

**The trade-off, stated plainly:** unpinned add-ons mean two applies weeks apart can install
different versions, which is a gap in reproducibility. The intended resolution is to pin all four
once pre-flight has enumerated the versions actually available:

```bash
aws eks describe-addon-versions --kubernetes-version 1.36 --region "$AWS_REGION" \
  --query 'addons[].{name:addonName,versions:addonVersions[0].addonVersion}'
```

`eks-pod-identity-agent` is the one that is easy to forget and hard to diagnose: without it, EKS Pod
Identity fails silently and the workload reports `AccessDenied` with no mention of the agent.

### Karpenter

Karpenter 1.14.0, installed as a Helm chart from `oci://public.ecr.aws/karpenter`. The chart version
is pinned; a floating version in a deliberately reproducible deployment is a contradiction.

**What Terraform creates on the AWS side** (`terraform-aws-modules/eks//modules/karpenter`):

| Resource | Why it matters |
| --- | --- |
| Controller IAM role + **scoped** policy | Not `AmazonEC2FullAccess`. The controller can manage the instances it owns, not the account |
| **EKS Pod Identity association** | Binds that role to the `karpenter` service account in `kube-system` |
| Node IAM role + instance profile | What Karpenter attaches to the instances it launches |
| EKS **access entry** for the node role | Without it, provisioned nodes cannot join the cluster |
| **SQS queue + EventBridge rules** | Spot interruption, capacity rebalance, instance state change |

**Pod Identity, not IRSA.** IRSA needs an OIDC provider, a trust policy templated with the cluster's
issuer URL, and a service-account annotation carrying a role ARN — three coupled things that must
stay consistent. Pod Identity needs one association, and the binding is a visible AWS resource
(`aws eks list-pod-identity-associations`) rather than a Kubernetes annotation you have to know to
look for. It also requires the `eks-pod-identity-agent` add-on: without it, credentials fail
silently and the controller logs `AccessDenied` with no mention of the agent.

**Spot interruption handling is wired, not merely provisioned.** The queue exists because
`enable_spot_termination = true`; it is *read* because `settings.interruptionQueue` points the
controller at it. Creating the queue without that value is a common and quiet failure — everything
looks configured and nothing consumes the notices.

> **Not yet verified.** Nothing here has been deployed. In particular, interruption handling is
> **configured**, not **demonstrated**: proving it requires triggering a real interruption (AWS Fault
> Injection Service) and observing the controller cordon and drain. Terminating an instance by hand
> tests node-failure recovery, which is a different thing and does not evidence this path.

**Chart defaults deliberately left alone**, because they solve real problems:

| Default | What it prevents |
| --- | --- |
| `nodeAffinity: karpenter.sh/nodepool DoesNotExist` | Karpenter scheduling onto a node it provisioned — and then consolidating itself away. **This is why no `nodeSelector` pinning the controller to the system group is added**: it would be a second, weaker expression of the same intent |
| `podAntiAffinity` on `kubernetes.io/hostname`, **required** | The two replicas landing on one node. With a single-node bootstrap group one replica would sit `Pending` forever — which is why `min_size = 2` is a hard requirement and not a preference |
| `topologySpreadConstraints` on zone, `DoNotSchedule` | Both replicas in one Availability Zone |
| `priorityClassName: system-cluster-critical` + PDB | The controller being evicted to make room for application workloads |

### Bootstrap node group

Karpenter is a pod, so it needs a node before it can provision any. This group is that node, and
nothing else runs here.

| Setting | Value | Why |
| --- | --- | --- |
| Size | `min 2`, `desired 2`, `max 3` | **Two, not one.** One node makes the whole control loop a single-node failure domain and gives the Karpenter controller's replicas nowhere to spread. Two is the smallest number that is not a single point of failure. `max 3` because this group is not where growth happens |
| Capacity type | **On-demand** | The controller that manages Spot capacity must not itself depend on Spot. If its node is reclaimed and nothing is left to provision a replacement, the cluster cannot recover on its own |
| Architecture | **amd64** (`AL2023_x86_64_STANDARD`) | The bootstrap layer should be boring. ARM64 is demonstrated later through Karpenter, where it is the point |
| Instance types | `m6i.large`, `m5.large` | 2 vCPU / 8 GiB. The Karpenter chart requests 1 CPU and 1 GiB per replica, and CoreDNS plus the DaemonSets take their share; a 4 GiB instance leaves almost no headroom. Two types of identical shape so the group is not blocked if one is unavailable in a zone |
| Placement | Private subnets | No public IP addresses, no SSH key, no inbound shell port. Break-glass access is via SSM |

**Alternatives considered.** A Fargate profile is the other option in the official Karpenter guide,
and it is rejected here: no DaemonSet support, slower pod start, and it forces IRSA rather than EKS
Pod Identity. **EKS Auto Mode** is AWS-managed Karpenter — it would satisfy "nodes autoscale" while
bypassing everything this proof of concept exists to demonstrate, and it adds a per-instance
management fee.

---

## Planning before the cluster exists

The Helm provider is configured from the EKS cluster this same configuration creates, so on a cold
run its `host` and `cluster_ca_certificate` are unknown at plan time. That is often assumed to
require a two-stage `-target` bootstrap.

**It does not, and this was measured rather than assumed.** A cold plan against an empty account
resolves the whole configuration in one pass:

```text
Plan: 82 to add, 0 to change, 0 to destroy.
```

Both `helm_release.karpenter` and `helm_release.karpenter_resources` are in that plan.

The reason is worth knowing: with no state there are no Helm releases to refresh, so the provider is
never actually configured during plan — unknown values in a provider block only matter when the
provider has to be used. On later runs the cluster exists and the values are known, so the question
never arises again.

**No `-target` is needed at any point.** Hard-coding an endpoint to work around a problem that does
not occur would trade a visible inconvenience for an invisible staleness bug.

**In production this would not arise**, because the boundary would be drawn differently: Terraform
would own the AWS resources and a GitOps controller would own everything inside the cluster. That
boundary is relaxed here on purpose — see [Deliberately out of scope](README.md#deliberately-out-of-scope).

---

## Terraform state

**This configuration uses local state**, deliberately, and that is a decision rather than a default.

**Why local here.** There is one operator, one apply at a time, and the stack is created, verified
and destroyed within hours. A remote backend needs bootstrap infrastructure — a bucket, a key, a
policy — created by something that is not in this repository, which would make it impossible to
clone and run. It would also create a resource `terraform destroy` cannot remove, leaving the
cleanup story incomplete.

**What that costs.** No locking, no history, and **losing the state file orphans the
infrastructure** — nothing would then be able to destroy it except manual work. That risk is
acceptable for a stack measured in hours; it is not acceptable for anything else.

**Where state belongs in production.** A versioned, SSE-KMS-encrypted, access-logged S3 bucket with
Block Public Access enabled, in an account separate from the workloads it describes, one key prefix
per environment. Locking via the S3 backend's native lockfile support. Environments separated by
**directories and accounts, not workspaces** — workspaces share a backend and a provider
configuration, so the blast radius of an apply is not visible from where you are standing. The CI
plan role read-only, the apply role separate and assumed only after approval.

State is never committed. `.gitignore` covers `*.tfstate*`, `*.tfvars`, `*.tfplan` and `.terraform/`.

---
