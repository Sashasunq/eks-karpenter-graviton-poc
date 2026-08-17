# EKS + Karpenter proof of concept — Terraform

> **Deployed and verified three times**, `eu-central-1`, 2026-08-17. Both architectures confirmed by
> `uname -m`, Spot confirmed against the EC2 API, provisioning and consolidation observed live, and
> the final run applied *and* destroyed in one pass each with nothing left behind.
> Results, and the six failures found on the way: [Run log](#run-log).

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

## Run log

Applied to a real AWS account in `eu-central-1` on 2026-08-17, verified, and destroyed. Everything
below is measured, not intended.

### Three runs

| | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- |
| `terraform apply` | 3 attempts | **1 attempt**, 11m12s | **1 attempt**, 10m53s |
| `terraform destroy` | 2 attempts + manual cleanup | 2 attempts + manual cleanup | **1 attempt**, 10m37s, nothing left |

Runs 1 and 2 each exposed failures that were fixed in code. **Run 3 is the one that makes
"reproducible" a measured claim rather than an intention** — apply and destroy both clean, no
intervention, verified against AWS afterwards.

### Results

| Phase | Result |
| --- | --- |
| Cold `terraform plan`, empty account | **82 resources, one pass.** No `-target` bootstrap needed — see [Planning before the cluster exists](#planning-before-the-cluster-exists) |
| EKS control plane | **ACTIVE in 8m30s**, Kubernetes 1.36 |
| Bootstrap node group | 2 × `m6i.large`, on-demand, in separate AZs |
| Karpenter | **2/2 replicas**, on two different nodes — the chart's required `podAntiAffinity` in action, which is why `min_size = 2` is not optional |
| `EC2NodeClass` status | 3 subnets, 1 security group, **5 AMIs across both architectures** — one alias does serve both |
| Controller image running | `public.ecr.aws/karpenter/controller:1.14.0` — the chart pin does determine the image |
| **x86 workload** | Node provisioned in **152s**, `c7i-flex.large`, spot → **`uname -m` = `x86_64`** |
| **ARM64 workload** | Node provisioned in **39s**, `c6g.large`, spot → **`uname -m` = `aarch64`** |
| Spot, confirmed against AWS | `InstanceLifecycle: spot` on both, from `describe-instances` — not just the node label |
| Consolidation | Empty node cordoned, drained and deleted **132s** after the workload went away |
| Live provisioning test | Deleted the x86 workload → Karpenter removed the now-idle node after **191s**. Re-applied it → node provisioned and pod `Running` in **36s**, on a *different* instance type |
| Instance-type diversity, observed | The x86 node came up as `c7i-flex.large`, `c8i-flex.large` and `c6a.large` across the three runs. Requirements are expressed as categories, so Karpenter picks what is cheap and available at that moment rather than waiting for a named type |
| Teardown, run 3 | `Destroy complete! Resources: 81 destroyed` in one pass. Verified after: 0 Terraform resources, 0 clusters, 0 instances, 0 VPCs, 0 NAT gateways, **0 orphaned ENIs**, 0 volumes, 0 Elastic IPs, **0 instance profiles**, 0 log groups |

ARM64 provisioned faster than x86 only because Karpenter's instance-type cache was already warm by
then; it is not an architecture difference.

### Six failures, and what they were

None of these are findable by `terraform validate`, and every one of them is environment-dependent.
That is the argument for running the thing rather than reading it — and for not trusting a default
region, a default profile or a default account to be representative.

**1. Karpenter's IAM policy does not fit — and whether it fits depends on the region's name.**

```text
LimitExceeded: Cannot exceed quota for PolicySize: 6144
```

Measured from state: the rendered policy is **6218 characters, over the managed-policy limit by 74**.
The region name appears in it **32 times**, so:

| Region | Policy size | |
| --- | --- | --- |
| `us-east-1` | 6122 | fits, by 22 characters |
| `eu-west-1` | 6122 | fits |
| **`eu-central-1`** | **6218** | **fails by 74** |
| `ap-southeast-1` | 6282 | fails by 138 |

The same configuration works in `us-east-1` and fails in `eu-central-1` because the region's name is
three characters longer. Fixed with `enable_inline_policy = true` — an inline role policy is capped
at 10240 instead of 6144. **A `us-east-1` default would have hidden this until someone deployed to
Europe.**

**2. The exec plugin depends on the operator's AWS CLI output format.**

```text
Kubernetes cluster unreachable: getting credentials: decoding stdout:
couldn't get version/kind; json parse error
```

The message points at the cluster. The cause is that the profile had `output = table`, so
`aws eks get-token` printed an ASCII table instead of an `ExecCredential` object. Fixed by adding
`--output json` to the exec args, so the configuration no longer depends on a setting in someone
else's `~/.aws/config`.

**3. A brand-new AWS account cannot launch Spot at all.**

```text
AuthFailure.ServiceLinkedRoleCreationNotPermitted: The provided credentials do not have
permission to create the service-linked role for EC2 Spot Instances.
```

wrapped inside an `UnfulfillableCapacity` from `CreateFleet`, and followed by repeated
`nodepool requirements filtered out all instance types` — which is what you see *after* a failed
launch, because Karpenter caches the types as temporarily unavailable. Read only the top line and
you go and rewrite the NodePool. The requirements were fine: Karpenter had matched **42 instance
types**.

The account was missing `AWSServiceRoleForEC2Spot`. One command, once per account:

```bash
aws iam create-service-linked-role --aws-service-name spot.amazonaws.com
```

See [Prerequisites](#one-account-level-prerequisite).

**4. `terraform destroy` tore the cluster down while Helm was still uninstalling.**

```text
Error: Error uninstalling release
```

The Helm provider reaches the cluster through values read from `module.eks` — but a **provider-level
dependency is not an edge in Terraform's resource graph.** With default parallelism, destroy started
removing EKS resources concurrently with the Helm uninstall, and the uninstall failed once the API
server was unreachable. Re-running finished the job, which is the worst kind of bug: it looks
transient.

Fixed with an explicit `depends_on = [module.eks]` on both releases, which creates the edge; destroy
reverses it and uninstalls Helm first.

**This is empirical evidence for the boundary this POC deliberately relaxed.** In production the
chart and the NodePools would belong to a GitOps controller, and "destroy the cluster" and "remove
what is inside the cluster" would not be two halves of one dependency graph. The cost of relaxing it
was documented here as a plan-time inconvenience; it is actually a destroy-time correctness problem.

**5. A VPC CNI ENI outlived its instance and blocked the whole VPC.**

```text
Error: deleting Security Group (sg-…): DependencyViolation: resource has a dependent object
eni-0f40584c111aad9f3   available   aws-K8S-i-04a43fa47de55c436
```

The ordered teardown did its job — both NodeClaims drained and `kubectl get nodeclaims` returned
`No resources found` before Terraform ran. But a **secondary ENI created by the VPC CNI** survived
the instance it belonged to, still referencing the node security group: ENI blocks security group,
which blocks subnet, which blocks VPC.

The ordered teardown addresses instances *Karpenter* owns and Terraform does not. This interface
belongs to a different lifecycle. **Necessary, and not sufficient** — the README said the former and
implied the latter, and that has been corrected in [Cleanup](#cleanup).

Deleting the orphan and re-running finished cleanly. What caught it was the post-destroy
verification, not the destroy output.

**6. Karpenter creates an instance profile that Terraform does not own.**

When the finalizer above could not run, `opsfleet-poc_2517060924259259760` was left behind — an IAM
instance profile **created by Karpenter, not by Terraform**. It is not in state, so `terraform
destroy` does not know about it, and none of the usual post-teardown checks — instances, VPCs,
volumes, addresses — would ever show it.

Removed manually. The zero-check list now includes instance profiles, because a resource nobody
looks for is a resource that stays.

### Graviton on Spot is not 20% cheaper

Prices for the two instance types this run actually launched, `eu-central-1`, at the time of the run:

| | x86 `c7i-flex.large` | ARM `c6g.large` | Graviton |
| --- | --- | --- | --- |
| **On-demand** | $0.0968/h | $0.0776/h | **19.8% cheaper** |
| Spot, `eu-central-1a` | $0.0432 | $0.0362 | 16.2% cheaper |
| Spot, `eu-central-1b` | $0.0427 | $0.0424 | 0.7% cheaper |
| Spot, `eu-central-1c` | $0.0407 | $0.0414 | **1.7% more expensive** |
| **Spot, average** | $0.0422 | $0.0400 | **5.2% cheaper** |

The familiar "Graviton is about 20% cheaper" is an **on-demand** number, and it holds. On **Spot**
the market largely competes it away: Spot price tracks supply and demand in that specific pool, not
the list discount — and in one Availability Zone Graviton was the more expensive option.

The case for Graviton on Spot is therefore capacity diversification and price/performance, not a
headline discount. Anyone forecasting savings from the on-demand figure while running on Spot will
miss.

### Not verified

**Spot interruption handling.** The queue, the EventBridge rules and `settings.interruptionQueue`
are all in place, but proving the path requires triggering a real interruption with AWS Fault
Injection Service. Deleting a node or terminating an instance tests node-failure recovery, which is
a different mechanism. Until that test runs, the claim is "configured", not "verified".

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
the error — see [Run log, failure 3](#three-failures-and-what-they-were).

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
| `endpoint_public_access_cidrs` | **none — required** | Who may reach the Kubernetes API server. See [Cluster access](#cluster-access) |
| `name` | `opsfleet-poc` | Resource prefix **and** the `karpenter.sh/discovery` tag value |
| `kubernetes_version` | `1.36` | `1.35` is a supported fallback |
| `karpenter_version` | `1.14.0` | Chart and controller are released together. 1.36 requires >= 1.13 |
| `ami_alias` | `al2023@v20260810` | One alias serves both architectures. Use `al2023@latest` if this release is unavailable in your region |
| `nodepool_cpu_limit` | `4` | Per-NodePool ceiling |
| `consolidate_after` | `1m` | Short so consolidation is observable; production sets it above workload warm-up |
| `vpc_cidr` | `10.0.0.0/16` | Must be /20 or larger. A /20 works but yields /24 private subnets, which limits pod density |
| `az_count` | `3` | Clamped to the zones the region actually has |
| `endpoint_public_access` | `true` | See [Cluster access](#cluster-access) |
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
the hard way — see [Run log](#run-log).

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
boundary is relaxed here on purpose — see [Deliberately out of scope](#deliberately-out-of-scope).

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
| GitOps controller (Argo CD / Flux) | In production, in-cluster objects — the Karpenter chart and the NodePools — belong to a GitOps controller rather than to Terraform. Terraform would still create the IAM role, the Pod Identity association and the SQS queue, because those are AWS resources. Here, a single `terraform apply` producing a schedulable cluster is worth more than that boundary, and the cost is the plan-time limitation described above |
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
