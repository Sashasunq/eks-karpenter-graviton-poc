# EKS + Karpenter proof of concept — Terraform

> **Build status: incomplete.** This directory currently creates **networking only**.
> The EKS cluster, Karpenter, the NodePools and the example workloads are **not implemented yet**.
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
| EKS cluster and managed add-ons | not implemented |
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
| Terraform | **>= 1.5.7** | Required by `terraform-aws-modules/eks` v21, adopted in the next phase |
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

```bash
cd terraform/

terraform init
terraform validate
terraform plan  -var="region=<your-region>"
terraform apply -var="region=<your-region>"
```

Or set it once: `export TF_VAR_region=<your-region>`.

Useful variables:

| Variable | Default | Notes |
| --- | --- | --- |
| `region` | **none — required** | See above |
| `name` | `opsfleet-poc` | Resource prefix **and** the `karpenter.sh/discovery` tag value |
| `vpc_cidr` | `10.0.0.0/16` | Must be /20 or larger |
| `az_count` | `3` | Clamped to the zones the region actually has |
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

A VPC across up to three Availability Zones:

```
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

Today, the billable resources are the **NAT Gateway** (hourly, plus per-GB) and its **Elastic IP**.
Once the cluster lands, the **EKS control plane at $0.10 per hour** (standard-support Kubernetes
versions; $0.60 on extended support) and the small always-on node group join them.

Levers already taken:

| Lever | Effect |
| --- | --- |
| **One NAT Gateway**, not one per AZ | Roughly a third of the NAT hourly cost. Accepts an AZ-level single point of failure for egress — correct for a short-lived proof of concept, wrong for production, which is why it is `var.single_nat_gateway` |
| No public IPs on nodes | IPv4 addresses are billed hourly. Here the cheap choice and the safe choice agree |
| No load balancers | Nothing in the demo needs ingress |
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

---

## Repository layout

```
terraform/
├── README.md
├── versions.tf     required_version and provider constraints
├── providers.tf    AWS provider; standard credential chain; default tags
├── variables.tf    region (no default), name, vpc_cidr, az_count, single_nat_gateway, tags
├── vpc.tf          AZ discovery, subnet CIDR maths, the VPC module and its tags
├── outputs.tf      values later phases and the verification steps consume
├── .gitignore
└── .terraform.lock.hcl   provider checksums for darwin/linux on amd64 and arm64
```

The configuration is a single flat root module. There are no wrapper modules: abstraction earns its
place when there is a second caller, and there is one.
