# EKS + Karpenter proof of concept — Terraform

> **Deployed and verified three times**, `eu-central-1`, 2026-08-17. Both architectures confirmed by
> `uname -m`, Spot confirmed against the EC2 API, provisioning and consolidation observed live, and
> the final run applied *and* destroyed in one pass each with nothing left behind.
> Results, and the six things that go wrong on the way: [Run log](RUN-LOG.md#run-log).

---
## Purpose

A reproducible AWS proof of concept, built with Terraform, demonstrating an EKS cluster whose
compute is provisioned by [Karpenter](https://karpenter.sh) across **both x86_64 and ARM64
(AWS Graviton)** instances on **EC2 Spot**, with a documented way to deliberately place a workload
on either architecture.

The goal is not the largest possible cluster. It is a small one where every decision is visible and
every claim is checkable.

**→ [Scheduling workloads on x86_64 and ARM64](#scheduling-workloads-on-x86_64-and-arm64)** — the
headline capability, with the manifests and the commands.

**→ [RUN-LOG.md](RUN-LOG.md)** — what happened when this was applied to a real account three times,
and the **six things that go wrong** doing it. None of them is a configuration error and none is
findable by `terraform validate`.

**→ [DECISIONS.md](DECISIONS.md)** — why the cluster is built this way, and the rejected alternative
in each case.

---

## Current scope

| Component | Status |
| --- | --- |
| VPC, 3 AZs, public + private subnets, IGW, NAT Gateway | **implemented** |
| Kubernetes and `karpenter.sh/discovery` subnet tags | **implemented** |
| EKS cluster, access entries, control-plane logging | **implemented** |
| Managed add-ons: VPC CNI, CoreDNS, kube-proxy, Pod Identity Agent | **implemented** |
| Bootstrap managed node group | **implemented** |
| Karpenter controller IAM, Pod Identity, Spot interruption queue | **implemented** |
| Karpenter controller (Helm) | **implemented** |
| `EC2NodeClass` and two `NodePool` objects | **implemented** |
| Example x86 / ARM64 / multi-arch workloads | **implemented** |

---

## Prerequisites

| Tool | Version | Why this floor |
| --- | --- | --- |
| Terraform | **>= 1.5.7** | Required by `terraform-aws-modules/eks` v21 |
| AWS CLI | v2 | Credentials and the pre-flight checks below |
| `kubectl` | matching the cluster minor version | Not needed until the cluster exists |
| Helm | not required | Terraform's Helm provider is used; the `helm` CLI is only useful for debugging |

Verified working with Terraform 1.5.7 and AWS provider 6.58.0.

You also need AWS credentials with permission to create VPC, EC2, IAM and EKS resources.

### One account-level prerequisite

**The EC2 Spot service-linked role must exist in the account.** It normally does; a brand-new
account has never requested Spot, so it does not, and Karpenter cannot create it itself:

```bash
aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1 \
  || aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

This is deliberately **not** in the Terraform. The role is account-global rather than
stack-scoped, so creating it here would fail in every account that already has one, and destroying
it would break Spot for anything else in the account. A one-line prerequisite is the honest shape.

Skip it and every Spot launch fails with `UnfulfillableCapacity`, with the real cause buried inside
the error — see [RUN-LOG.md, failure 3](RUN-LOG.md#what-will-go-wrong-and-what-it-actually-is).

A new account may also have its first EC2 launches held for validation, and Standard Spot vCPU
quota at the default of 5. Both are covered in [Region](#region).

---

## Authentication

This configuration uses the **standard AWS provider credential chain**. It contains no profile name,
no access key, and no account ID.

**Set `AWS_PROFILE` explicitly.** Relying on a `[default]` profile is how infrastructure ends up in
the wrong account; `allowed_account_ids` is the backstop, not the plan.

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
A static key sitting in a `[default]` profile is also the most common way a configuration lands in
an account nobody meant to touch.

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

### Step zero: which account is this going into?

Terraform reads credentials from the standard AWS chain. That means the account it deploys into is
decided by whatever happens to be loaded — a shared `[default]` profile, a stale exported session, a
forgotten `AWS_PROFILE`. This configuration creates a VPC, an EKS cluster and a NAT Gateway, and
putting those somewhere they do not belong is expensive at best.

**Check, then name the account.** `allowed_account_ids` is a required variable with no default; the
provider verifies the caller against it and refuses to create anything if they disagree.

```bash
export AWS_PROFILE=<the-profile-you-mean>     # set it explicitly; do not rely on [default]
aws sts get-caller-identity                   # read it, do not skim it
```

### Then deploy

Three variables are required and have no defaults — the account, the region, and who may reach the
Kubernetes API server:

```bash
cd terraform/

export TF_VAR_allowed_account_ids="[\"$(aws sts get-caller-identity --query Account --output text)\"]"
export TF_VAR_region=<your-region>
export TF_VAR_endpoint_public_access_cidrs="[\"$(curl -s https://checkip.amazonaws.com)/32\"]"

terraform init
terraform validate
terraform plan
terraform apply
```

The account-ID line above reads the account you are *currently* authenticated to, which is only safe
once you have run `get-caller-identity` and confirmed it is the one you intend. Otherwise set the
value literally.

| Variable | Default | Notes |
| --- | --- | --- |
| `allowed_account_ids` | **none — required** | The accounts this may deploy into. See [Step zero](#step-zero-which-account-is-this-going-into) |
| `region` | **none — required** | See [Region](#region) |
| `endpoint_public_access_cidrs` | **none — required** | Who may reach the Kubernetes API server. See [Cluster access](DECISIONS.md#cluster-access) |
| `name` | `opsfleet-poc` | Resource prefix **and** the `karpenter.sh/discovery` tag value |
| `kubernetes_version` | `1.36` | `1.35` is a supported fallback |
| `karpenter_version` | `1.14.0` | Chart and controller are released together. 1.36 requires >= 1.13 |
| `ami_alias` | `al2023@v20260810` | One alias serves both architectures. Use `al2023@latest` if this release is unavailable in your region |
| `nodepool_cpu_limit` | `4` | Per-NodePool ceiling |
| `consolidate_after` | `1m` | Short so consolidation is observable; production sets it above workload warm-up |
| `vpc_cidr` | `10.0.0.0/16` | Must be /20 or larger. A /20 works but yields /24 private subnets, which limits pod density |
| `az_count` | `3` | Clamped to the zones the region actually has |
| `endpoint_public_access` | `true` | See [Cluster access](DECISIONS.md#cluster-access) |
| `single_nat_gateway` | `true` | Set `false` for one NAT per AZ — see [Cost](#cost) |

---

## Scheduling workloads on x86_64 and ARM64

The contract, in one sentence:

> **A pod requests an architecture. Karpenter picks an instance type that satisfies it.
> A workload manifest never names an instance type.**

Two NodePools exist — `x86-spot` and `arm64-spot`. They are identical apart from one requirement,
and you never reference them by name: the scheduler matches on the well-known
`kubernetes.io/arch` label, and Karpenter provisions from whichever pool can satisfy the pod.

### Deploy to x86_64

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64      # ← the only line that decides this
```

```bash
kubectl apply -f examples/x86-deployment.yaml
kubectl exec deploy/demo-x86 -- uname -m        # x86_64
```

### Deploy to ARM64 / Graviton

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64      # ← and this one
```

```bash
kubectl apply -f examples/arm64-deployment.yaml
kubectl exec deploy/demo-arm64 -- uname -m      # aarch64
```

`examples/arm64-deployment.yaml` is byte-identical to `examples/x86-deployment.yaml` apart from the
resource name and that one word. **That is the honest summary of Graviton adoption at the cluster
level: it is a scheduling change.**

### Let Karpenter choose

Most workloads should say "either" once their image supports it, and let the provisioner decide on
price and availability. `nodeSelector` cannot express that, so this uses `nodeAffinity`:

```yaml
spec:
  template:
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: kubernetes.io/arch
                    operator: In
                    values: ["amd64", "arm64"]
```

```bash
kubectl apply -f examples/multi-arch-deployment.yaml
```

### A third option, when a platform team owns placement

Both NodePools also label their nodes `workload-arch: x86` / `workload-arch: graviton`. Selecting on
a custom label instead of `kubernetes.io/arch` decouples the workload from the well-known key, which
is useful when the platform team wants to change placement policy without editing every manifest.
Mentioned because it exists; `kubernetes.io/arch` is the right default.

### The part that actually takes work

**The cluster side of ARM adoption is one line. The image side is the migration.**

The container image must have a `linux/arm64` variant — which means every dependency, including
native extensions and vendored binaries, must exist for ARM:

```bash
docker buildx build --platform linux/amd64,linux/arm64 -t <repo>:<tag> --push .
docker manifest inspect <image>        # confirm both architectures before deploying
```

Get it wrong and the pod crash-loops with `exec format error` — which reads like a broken image
rather than a missing architecture, and is the most common way an ARM rollout fails.

The demo image here (`public.ecr.aws/amazonlinux/amazonlinux:2023`) was checked against the registry
API for both architectures *before* these manifests were written, for exactly that reason.

### Proving where a pod actually landed

```bash
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
```

**`uname -m` is the proof, not the node label.** A label reports what Karpenter believes; `uname`
reports what the kernel is running on. And for capacity type, ask AWS rather than the cluster:

```bash
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' \
  --output table
```

`InstanceLifecycle: spot` from the EC2 API is independent confirmation of the
`karpenter.sh/capacity-type=spot` label.

---

## Verification

Roughly 25 minutes end to end, most of it EKS creating the control plane.

```bash
# 1. cluster
terraform apply                                     # ~15-20 min
aws eks update-kubeconfig --name opsfleet-poc --region "$AWS_REGION"

kubectl get nodes                                   # 2 bootstrap nodes, Ready
kubectl -n kube-system get deploy karpenter         # 2/2
kubectl get nodepools,ec2nodeclasses                # both NodePools Ready=True
```

If a NodePool is not `Ready`, look at the NodeClass status before anything else — unresolved
selectors mean the `karpenter.sh/discovery` tags did not match, which is the most common Karpenter
setup failure:

```bash
kubectl get ec2nodeclass default -o yaml | grep -A20 '^status:'
```

```bash
# 2. x86, then ARM64
kubectl apply -f examples/x86-deployment.yaml
kubectl get nodeclaims -w                           # ~60-90s to Ready

kubectl apply -f examples/arm64-deployment.yaml
kubectl get nodeclaims -w

# 3. the evidence
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,node.kubernetes.io/instance-type
kubectl exec deploy/demo-x86   -- uname -m          # x86_64
kubectl exec deploy/demo-arm64 -- uname -m          # aarch64

# 4. Spot, confirmed against AWS rather than against a label
aws ec2 describe-instances \
  --filters "Name=tag:karpenter.sh/nodepool,Values=*" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].[InstanceType,InstanceLifecycle,Placement.AvailabilityZone]' \
  --output table

# 5. consolidation
kubectl delete -f examples/
kubectl get nodeclaims -w                           # nodes drain and go, after consolidateAfter
```

`uname -m` is the proof. A node label reports what Karpenter believes; `uname` reports what the
kernel is running on, and `InstanceLifecycle` from the EC2 API is independent of both.

### What is configured but not demonstrated

**Spot interruption handling.** The SQS queue and EventBridge rules exist and the controller is
pointed at them, but proving the path works means triggering a real interruption with AWS Fault
Injection Service and watching the controller cordon and drain. Terminating an instance by hand
tests *node-failure recovery*, which is a different mechanism and does not evidence this one.

Until that test is run, the honest claim is "configured", not "verified".

---

## Cleanup

**Order matters, and it is not sufficient on its own.** Both halves of that sentence were learned
the hard way — see [Run log](RUN-LOG.md#run-log).

Karpenter-provisioned instances are not in Terraform state, so they must drain while the controller
is still alive to drain them:

```bash
kubectl delete -f examples/                             # 1. workloads
kubectl delete nodepool --all                           # 2. stop provisioning
kubectl wait --for=delete nodeclaim --all --timeout=10m # 3. wait for nodes to actually go
terraform destroy                                       # 4. only now
```

That worked: both NodeClaims reported `condition met` and `kubectl get nodeclaims` returned
`No resources found` before Terraform started.

### It still did not finish, and here is what to expect

```text
Error: deleting Security Group (sg-…): DependencyViolation: resource has a dependent object
```

A **secondary ENI created by the VPC CNI outlived its instance**:

```text
eni-0f40584c111aad9f3   available   aws-K8S-i-04a43fa47de55c436
```

The instance was gone; the interface was detached but still present, still referencing the node
security group. That blocks the security group, which blocks the subnet, which blocks the VPC.

**Why the ordered teardown did not prevent it:** it addresses instances Karpenter owns and Terraform
does not. This ENI belongs to the **VPC CNI**, which is a different lifecycle — the interface can
survive its instance when the two teardowns interleave. Draining NodeClaims first is necessary and
does not cover it.

Check for it, and clear it if present:

```bash
VPC=$(terraform output -raw vpc_id)

aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
  --query 'NetworkInterfaces[].[NetworkInterfaceId,Status,Description]' --output text

# any 'available' interface left behind is an orphan; delete it, then re-run destroy
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" \
  "Name=status,Values=available" --query 'NetworkInterfaces[].NetworkInterfaceId' --output text \
  | xargs -n1 -r aws ec2 delete-network-interface --network-interface-id

terraform destroy
```

### Then verify, rather than assume

```bash
terraform state list | wc -l                                    # 0
aws eks list-clusters --query 'length(clusters)'                 # 0
aws ec2 describe-instances --filters "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[])'                   # 0
aws ec2 describe-nat-gateways --filter "Name=state,Values=available" --query 'length(NatGateways)'
aws ec2 describe-volumes --filters "Name=status,Values=available" --query 'length(Volumes)'
aws ec2 describe-addresses --query 'length(Addresses)'
aws ec2 describe-vpcs --filters "Name=tag:Project,Values=opsfleet-poc" --query 'length(Vpcs)'
```

**This step is the deliverable, not a formality.** On the first teardown, Terraform printed an error
and the orphan was obvious. With slightly different timing it could have printed `Destroy complete`
with that ENI still holding a security group — and "it destroyed cleanly" would have been a claim
rather than a fact. Orphaned EBS volumes and Elastic IPs are the same story with a monthly bill
attached.

**Not removed by `terraform destroy`, deliberately:** `AWSServiceRoleForEC2Spot`, from
[Prerequisites](#one-account-level-prerequisite). It is account-global rather than stack-scoped, and
deleting it would break Spot for everything else in the account.

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
| No customer-managed KMS key | The platform default costs nothing — see [Encryption](DECISIONS.md#encryption) |
| Control-plane logs limited to three types, 7-day retention | CloudWatch bills by ingested volume |
| VPC endpoints **not** used | ~8 interface endpoints across 3 AZs cost more than one NAT at this scale — and they cannot reach public container registries at all, which is the decisive reason |

Exact figures are region-dependent and are not quoted here. Pull them from the AWS Pricing
Calculator for your region rather than trusting a number in a README.

---

## Deliberately out of scope

Absences that are decisions, not oversights:

| Not here | Why |
| --- | --- |
| Remote state backend | See [Terraform state](DECISIONS.md#terraform-state) |
| CI/CD pipeline | The authentication model is documented above; building a pipeline would add infrastructure the assessment does not ask for |
| GitOps controller (Argo CD / Flux) | In production, in-cluster objects — the Karpenter chart and the NodePools — belong to a GitOps controller rather than to Terraform. Terraform would still create the IAM role, the Pod Identity association and the SQS queue, because those are AWS resources. Here, a single `terraform apply` producing a schedulable cluster is worth more than that boundary, and the cost is the plan-time limitation described above |
| One NAT Gateway per AZ | Cost, for a stack that lives hours. `var.single_nat_gateway = false` flips it |
| VPC endpoints | See [Cost](#cost) |
| Ingress controller, observability stack, NetworkPolicy, admission control | Real production controls that demonstrate nothing about Karpenter and would obscure what does |
| Customer-managed KMS key for envelope encryption | The platform default is enabled and covers more; a CMK is justified by compliance or key-ownership requirements, not by wanting to look thorough — see [Encryption](DECISIONS.md#encryption) |
| Pinned add-on versions | A pin is only meaningful once the available versions have been enumerated — see [Add-on versions](DECISIONS.md#add-on-versions) |
| VPC CNI prefix delegation | Raises pod density per node and is worth enabling in production; it is a tuning parameter that would obscure the bootstrap layer here |

---

## Repository layout

```text
terraform/
├── README.md       how to run it, verify it and tear it down  ← you are here
├── RUN-LOG.md      what happened on three real runs, and what goes wrong
├── DECISIONS.md    why the cluster is built this way
├── versions.tf     required_version and provider constraints
├── providers.tf    AWS provider (standard credential chain, default tags); Helm provider via exec auth
├── variables.tf    region (no default), name, vpc_cidr, az_count, single_nat_gateway, tags
├── vpc.tf          AZ discovery, subnet CIDR maths, the VPC module and its tags
├── eks.tf          cluster, endpoint access, access entries, logging, add-ons, bootstrap node group
├── karpenter.tf    controller IAM, Pod Identity, interruption queue, Helm release
├── karpenter-nodepools.tf   EC2NodeClass + NodePools, via the local chart below
├── charts/karpenter-resources/   the manifests, readable as Kubernetes YAML
├── outputs.tf      values an operator or a later phase actually consumes
├── .gitignore
└── .terraform.lock.hcl   provider checksums for darwin/linux on amd64 and arm64
```

The configuration is a single flat root module. There are no wrapper modules: abstraction earns its
place when there is a second caller, and there is one.
