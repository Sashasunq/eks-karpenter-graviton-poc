# Run log

What happened when this was applied to a real AWS account — three full apply/verify/destroy cycles
in `eu-central-1` on 2026-08-17, and the six failure modes they surfaced.

Everything here is measured. Nothing is projected.

[← back to README](README.md)

---

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
| Cold `terraform plan`, empty account | **82 resources, one pass.** No `-target` bootstrap needed — see [Planning before the cluster exists](DECISIONS.md#planning-before-the-cluster-exists) |
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

### What will go wrong, and what it actually is

Building this against a real AWS account surfaces a set of failures that no amount of
`terraform validate` will show you, because **not one of them is a configuration error**. Every one
depends on the environment instead: which region you are in, how your AWS CLI happens to be
configured, how old the account is, and how the platform behaves on the way down.

Each was met during three full apply/destroy cycles. They are written as *what to expect* rather
than as a diary, because that is the form in which they are useful — anyone repeating this exercise
will meet the same list.

---

**1. The Karpenter IAM policy may not fit, and whether it fits depends on how long your region's name is.**

| | |
| --- | --- |
| You see | `LimitExceeded: Cannot exceed quota for PolicySize: 6144` |
| It actually is | The rendered policy is 6218 characters. The region name appears in it **32 times** |
| Why it is not obvious | It works in `us-east-1` — by 22 characters. `eu-central-1` is three characters longer per occurrence and fails by 74. `ap-southeast-1` fails by 138 |
| Fix | `enable_inline_policy = true`. Inline role policies are capped at 10240 rather than 6144 |

The module ships a variable whose description names this exact error, so it is well known — and it is
off by default. **Anyone who develops in `us-east-1` and deploys elsewhere meets this in the other
environment, not in theirs.**

**2. The Helm provider cannot log in, because of a setting in your AWS CLI profile.**

| | |
| --- | --- |
| You see | `Kubernetes cluster unreachable: getting credentials: decoding stdout: couldn't get version/kind; json parse error` |
| It actually is | Your profile has `output = table`, so `aws eks get-token` printed an ASCII table where an `ExecCredential` object was expected |
| Why it is not obvious | The message names the cluster. The cluster is fine |
| Fix | `--output json` in the exec args, so the configuration stops depending on someone else's `~/.aws/config` |

**3. A new AWS account cannot launch Spot at all.**

| | |
| --- | --- |
| You see | `UnfulfillableCapacity` from `CreateFleet`, then `nodepool requirements filtered out all instance types`, repeatedly |
| It actually is | `AuthFailure.ServiceLinkedRoleCreationNotPermitted`, nested *inside* the first error. `AWSServiceRoleForEC2Spot` does not exist and Karpenter cannot create it |
| Why it is not obvious | The follow-on message is what appears *after* a failed launch, because Karpenter caches those instance types as unavailable. Read the top line only and you will go and rewrite your NodePool. The requirements were fine — 42 instance types matched |
| Fix | `aws iam create-service-linked-role --aws-service-name spot.amazonaws.com`, once per account. See [Prerequisites](README.md#one-account-level-prerequisite) |

**4. `terraform destroy` will tear the cluster down while Helm is still uninstalling.**

| | |
| --- | --- |
| You see | `Error: Error uninstalling release`. Running destroy again appears to fix it |
| It actually is | The Helm provider reaches the cluster through values read from `module.eks`, but **a provider-level dependency is not an edge in Terraform's resource graph**, so destroy is free to run both concurrently |
| Why it is not obvious | It looks transient, because a retry gets further |
| Fix | Explicit `depends_on` from the releases to the cluster |

**And the fix has to be wider than that, which is the part worth knowing.** Uninstalling the release
is not a Kubernetes-only operation: the `EC2NodeClass` finalizer calls IAM to clean up the instance
profile Karpenter created, and the controller sits in a private subnet. Remove the NAT gateway first
and that call times out, the finalizer never releases, the object hangs in `Terminating`, and the
uninstall fails — with an error that says nothing about networking.

So the dependency is not *"the cluster must outlive Helm"*. It is **"everything the controller needs
in order to shut down cleanly must outlive Helm"**, and that includes the egress path.

**5. A VPC CNI network interface will outlive its instance and block the entire VPC.**

| | |
| --- | --- |
| You see | `DependencyViolation: resource sg-… has a dependent object`, and destroy stops with the VPC still alive |
| It actually is | A secondary ENI created by the VPC CNI, `available` but still referencing the node security group. ENI blocks security group, which blocks subnet, which blocks VPC |
| Why it is not obvious | The ordered teardown *worked* — every NodeClaim drained before Terraform ran. But that addresses instances **Karpenter** owns and Terraform does not; this interface belongs to a different lifecycle |
| Fix | Delete the orphan, re-run destroy. The check is in [Cleanup](README.md#cleanup) |

**6. Karpenter creates an IAM instance profile that Terraform does not own.**

| | |
| --- | --- |
| You see | Nothing. That is the problem |
| It actually is | Karpenter creates its own instance profile. It is not in state, so `terraform destroy` cannot remove it, and the usual post-teardown checks — instances, VPCs, volumes, addresses — will never show it |
| Why it is not obvious | Every other resource is accounted for, so the teardown looks clean |
| Fix | Include instance profiles in the verification list. A resource nobody looks for is a resource that stays |

---

**The pattern across all six:** the loudest error was rarely the cause. In three of them the real
message was nested inside another one, or pointed at a component that was healthy. That is worth
more as a habit than any individual fix — **read past the first line, and check what the failing
component was actually trying to do.**

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
