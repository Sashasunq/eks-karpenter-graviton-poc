# EKS + Karpenter proof of concept — Terraform

> **Build status: incomplete.** This directory currently creates the **network and the EKS cluster**.
> Karpenter, the NodePools and the example workloads are **not implemented yet**.
> See [Current scope](#current-scope) for exactly what exists today.

---

## Purpose

A reproducible AWS proof of concept, built with Terraform, demonstrating an EKS cluster whose
compute is provisioned by [Karpenter](https://karpenter.sh) across **both x86_64 and ARM64
(AWS Graviton)** instances on **EC2 Spot**, with a documented way to deliberately place a workload
on either architecture.

The goal is not the largest possible cluster. It is a small one where every decision is visible and
every claim is checkable.

---

## Current scope

| Component | Status |
| --- | --- |
| VPC, 3 AZs, public + private subnets, IGW, NAT Gateway | **implemented** |
| Kubernetes and `karpenter.sh/discovery` subnet tags | **implemented** |
| EKS cluster, access entries, control-plane logging | **implemented** |
| Managed add-ons: VPC CNI, CoreDNS, kube-proxy, Pod Identity Agent | **implemented** |
| Bootstrap managed node group | **implemented** |
| Karpenter controller, IAM, Spot interruption queue | not implemented |
| `EC2NodeClass` and `NodePool` objects | not implemented |
| Example x86 / ARM64 / multi-arch workloads | not implemented |

Nothing in this repository has been deployed to AWS yet. Every statement below about behaviour is
therefore about **intended** behaviour, and this note will be removed once the stack has been
applied and verified.

---

## Prerequisites

| Tool | Version | Why this floor |
| --- | --- | --- |
| Terraform | **>= 1.5.7** | Required by `terraform-aws-modules/eks` v21 |
| AWS CLI | v2 | Credentials and the pre-flight checks below |
| `kubectl` | matching the cluster minor version | Not needed until the cluster exists |

Verified working with Terraform 1.5.7 and AWS provider 6.58.0.

You also need AWS credentials with permission to create VPC, EC2, IAM and EKS resources.

---

## Authentication

This configuration uses the **standard AWS provider credential chain**. It contains no profile name,
no access key, and no account ID.

Any of these work:

```bash
# IAM Identity Center (recommended)
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>

# or temporary credentials issued to you
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_SESSION_TOKEN=...

# confirm which identity Terraform will use
aws sts get-caller-identity
```

**Why no static keys.** A long-lived access key must be stored somewhere, must be rotated by
someone, and has indefinite blast radius from anywhere. Short-lived credentials expire on their own.

**How this would work in CI.** GitHub Actions would federate to AWS over OIDC:
`sts:AssumeRoleWithWebIdentity` against an IAM OIDC provider for
`token.actions.githubusercontent.com`, with the role's trust policy conditioned on the `sub` claim
matching one repository and branch. The workflow receives a short-lived session per run; no secret is
stored. That is deliberately **not** built here — see [Deliberately out of
scope](#deliberately-out-of-scope).

---

## Region

**`region` has no default and must be set explicitly.**

Kubernetes version availability, instance-family availability, Spot pool depth and Availability Zone
count all vary by region. A default would encode a guess about your account as an invisible
assumption, and the resulting failure would not look like a region problem.

Run these read-only checks before deploying. They cost nothing.

```bash
export AWS_REGION=<your-region>

# Availability Zones — the configuration clamps to what exists, but two is the minimum
aws ec2 describe-availability-zones --region "$AWS_REGION" \
  --filters "Name=opt-in-status,Values=opt-in-not-required" --query 'AvailabilityZones[].ZoneName'

# Instance families for both architectures, per zone
aws ec2 describe-instance-type-offerings --location-type availability-zone \
  --filters "Name=instance-type,Values=c7g.*,m7g.*,r7g.*" --region "$AWS_REGION" \
  --query 'InstanceTypeOfferings[].[InstanceType,Location]' --output table

# Quotas that will block a later apply. A new account can have a Spot vCPU quota of zero,
# and an increase takes hours to days.
aws service-quotas get-service-quota --service-code ec2 --quota-code L-34B43A08  # Spot vCPUs
aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE  # VPCs per region
aws service-quotas get-service-quota --service-code ec2 --quota-code L-0263D0A3  # Elastic IPs
```

---

## Deployment

Two variables are required and have no defaults — the region, and who may reach the Kubernetes API
server:

```bash
cd terraform/

export TF_VAR_region=<your-region>
export TF_VAR_endpoint_public_access_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"

terraform init
terraform validate
terraform plan
terraform apply
```

| Variable | Default | Notes |
| --- | --- | --- |
| `region` | **none — required** | See [Region](#region) |
| `endpoint_public_access_cidrs` | **none — required** | Who may reach the Kubernetes API server. See [Cluster access](#cluster-access) |
| `name` | `opsfleet-poc` | Resource prefix **and** the `karpenter.sh/discovery` tag value |
| `kubernetes_version` | `1.36` | `1.35` is a supported fallback |
| `vpc_cidr` | `10.0.0.0/16` | Must be /20 or larger. A /20 works but yields /24 private subnets, which limits pod density |
| `az_count` | `3` | Clamped to the zones the region actually has |
| `endpoint_public_access` | `true` | See [Cluster access](#cluster-access) |
| `single_nat_gateway` | `true` | Set `false` for one NAT per AZ — see [Cost](#cost) |

### Planned deployment flow

Once the remaining phases land, the intended end-to-end flow is:

1. `terraform apply` — VPC, EKS cluster, add-ons, a small managed node group, Karpenter and its
   NodePools. The result is a cluster ready to schedule workloads.
2. `aws eks update-kubeconfig --name <name> --region <region>`
3. `kubectl apply -f examples/x86-deployment.yaml` — observe Karpenter provision an x86_64 Spot node.
4. `kubectl apply -f examples/arm64-deployment.yaml` — observe it provision a Graviton Spot node.
5. Verify with `kubectl exec <pod> -- uname -m`, which returns `x86_64` and `aarch64` respectively.
6. Scale down and watch consolidation remove the nodes.
7. Tear down in order — NodePools first, then `terraform destroy` — then verify nothing was left
   behind.

Steps 1–7 are **not yet implemented or tested**. They describe the intended shape, not observed
behaviour.

---

## What this creates today

An EKS cluster and the network it sits in:

```text
  Operator workstation ──kubectl / terraform──► EKS API server endpoint
                                                public (CIDR-allowlisted) + private
                                                IAM auth, EKS Access Entries, no aws-auth
                                                logs: api / audit / authenticator -> CloudWatch
```

The VPC, across up to three Availability Zones:

```text
                         Internet Gateway
                                │
        ┌───────────────────────┼───────────────────────┐
        │                       │                       │
   public /24 (a)          public /24 (b)          public /24 (c)
        │                                                │
    NAT Gateway ◄── single, shared (var.single_nat_gateway = true)
        │
        └──────────────► default route for all private subnets
        │                       │                       │
   private /20 (a)         private /20 (b)         private /20 (c)
   nodes live here — no public IP addresses

   private subnet tags: kubernetes.io/role/internal-elb = 1
                        karpenter.sh/discovery          = <name>
   public  subnet tags: kubernetes.io/role/elb          = 1

   in the private subnets: bootstrap managed node group
                           2 x on-demand amd64, m6i.large / m5.large
                           node security group tagged karpenter.sh/discovery = <name>
```

**Why the private subnets are /20.** The VPC CNI assigns pod IP addresses from the subnet, so subnet
size is what bounds pod density per zone. IP exhaustion is the classic EKS wall, and it is far
cheaper to avoid at design time than to fix later.

**Why only private subnets carry `karpenter.sh/discovery`.** Karpenter's `EC2NodeClass` selects
subnets by that tag. Tagging the public subnets too would let it place workload nodes with public IP
addresses — a security failure that would look like a typo.

**Why three AZs.** Each instance-type-per-AZ pair is an independent EC2 Spot capacity pool. More
pools means a materially better chance of getting capacity, and adding them costs nothing.

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

## Cost

**This costs money while it runs. Destroy it when you are done.**

Today the billable resources are the **EKS control plane at $0.10 per hour** (standard-support
Kubernetes versions; **$0.60** on extended support — a 6x difference, and the concrete cost of
falling behind), the **two on-demand bootstrap instances**, the **NAT Gateway** (hourly plus
per-GB) and its **Elastic IP**, plus small charges for EBS root volumes and CloudWatch Logs.

Karpenter-provisioned Spot capacity will be added in a later phase and consolidates to zero when
idle. The four items above do not: they are the always-on floor, and they run whether or not
anything is scheduled.

Levers already taken:

| Lever | Effect |
| --- | --- |
| **One NAT Gateway**, not one per AZ | Roughly a third of the NAT hourly cost. Accepts an AZ-level single point of failure for egress — correct for a short-lived proof of concept, wrong for production, which is why it is `var.single_nat_gateway` |
| No public IPs on nodes | IPv4 addresses are billed hourly. Here the cheap choice and the safe choice agree |
| No load balancers | Nothing in the demo needs ingress |
| No customer-managed KMS key | The platform default costs nothing — see [Encryption](#encryption) |
| Control-plane logs limited to three types, 7-day retention | CloudWatch bills by ingested volume |
| VPC endpoints **not** used | ~8 interface endpoints across 3 AZs cost more than one NAT at this scale — and they cannot reach public container registries at all, which is the decisive reason |

Exact figures are region-dependent and are not quoted here. Pull them from the AWS Pricing
Calculator for your region rather than trusting a number in a README.

---

## Deliberately out of scope

Absences that are decisions, not oversights:

| Not here | Why |
| --- | --- |
| Remote state backend | See [Terraform state](#terraform-state) |
| CI/CD pipeline | The authentication model is documented above; building a pipeline would add infrastructure the assessment does not ask for |
| GitOps controller (Argo CD / Flux) | In production, in-cluster objects belong to a GitOps controller rather than to Terraform. Here, a single `terraform apply` producing a schedulable cluster is worth more than the lifecycle boundary |
| One NAT Gateway per AZ | Cost, for a stack that lives hours. `var.single_nat_gateway = false` flips it |
| VPC endpoints | See [Cost](#cost) |
| Ingress controller, observability stack, NetworkPolicy, admission control | Real production controls that demonstrate nothing about Karpenter and would obscure what does |
| Customer-managed KMS key for envelope encryption | The platform default is enabled and covers more; a CMK is justified by compliance or key-ownership requirements, not by wanting to look thorough — see [Encryption](#encryption) |
| Pinned add-on versions | A pin is only meaningful once the available versions have been enumerated — see [Add-on versions](#add-on-versions) |
| VPC CNI prefix delegation | Raises pod density per node and is worth enabling in production; it is a tuning parameter that would obscure the bootstrap layer here |

---

## Repository layout

```text
terraform/
├── README.md
├── versions.tf     required_version and provider constraints
├── providers.tf    AWS provider; standard credential chain; default tags
├── variables.tf    region (no default), name, vpc_cidr, az_count, single_nat_gateway, tags
├── vpc.tf          AZ discovery, subnet CIDR maths, the VPC module and its tags
├── eks.tf          cluster, endpoint access, access entries, logging, add-ons, bootstrap node group
├── outputs.tf      values an operator or a later phase actually consumes
├── .gitignore
└── .terraform.lock.hcl   provider checksums for darwin/linux on amd64 and arm64
```

The configuration is a single flat root module. There are no wrapper modules: abstraction earns its
place when there is a second caller, and there is one.
