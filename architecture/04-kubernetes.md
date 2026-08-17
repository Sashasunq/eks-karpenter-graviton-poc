# Managed Kubernetes, nodes, autoscaling and resources

## Why EKS — and the honest counter-argument

The brief states managed Kubernetes is preferred, so this is a requirement rather than a choice to
re-litigate. The reasons hold: a managed control plane removes the operational burden that is the
usual argument against Kubernetes at small scale, IAM integration is native, and Graviton plus Spot
economics are available immediately.

**The counter-argument, stated because leaving it out would be dishonest:** at a few hundred users a
day, **ECS Fargate or App Runner would run this application with materially less operational
surface.** No node management, no cluster upgrades, no CNI. Kubernetes is chosen because the
customer asked for it and because the path to millions of users is real — not because it is the
right tool for current scale.

A design that cannot name the case against its own central choice has not made a choice.

**What tips it back:** the workload is not just a web API. Background workers, scheduled jobs and
eventual event processing all live naturally in one Kubernetes scheduling model, and moving them
into ECS task definitions one at a time is the migration nobody schedules.

---

## Cluster design

| Decision | Choice | Reasoning |
| --- | --- | --- |
| Clusters | **One per environment**, not one per service | A cluster is a failure domain and an upgrade unit. Three is already three upgrade cycles a year |
| Version policy | Current or N-1, upgraded on a schedule | 14 months of standard support; extended support costs 6× per cluster-hour, which is the concrete price of drifting |
| Upgrades | Control plane in place; **data plane replaced, never upgraded** | Blue/green node pools. In-place node upgrades are how a cluster ends up with three kubelet versions |
| API endpoint | **Private only** | Access via SSM or VPN |
| Access | **EKS Access Entries**, SSO groups → namespace-scoped roles | `aws-auth` is a ConfigMap whose malformed edit locks everyone out with no undo |
| Add-ons | VPC CNI, CoreDNS, kube-proxy, EBS CSI, Pod Identity Agent — as **managed add-ons, version-pinned** | Lifecycle owned by AWS; pins bumped through a reviewed change |
| Namespaces | Per environment and per domain, with `ResourceQuota`, `LimitRange` and default-deny `NetworkPolicy` | |

> **Namespaces are environment isolation, not tenant isolation.** If a customer ever requires
> provable isolation, the honest answer is a separate cluster or a separate account. Saying this
> plainly is worth more than a diagram that implies otherwise.

---

## Node strategy

Three pools, provisioned by **Karpenter**:

| Pool | Capacity | Runs |
| --- | --- | --- |
| **system** | On-demand, 2 nodes minimum | Controllers: Karpenter, load balancer controller, External Secrets, observability agents |
| **Graviton Spot** | ARM64, Spot, diversified | The default — Flask API, background workers |
| **on-demand** | x86 or ARM, on-demand | Only workloads that genuinely cannot tolerate interruption |

**The system pool is on-demand and has at least two nodes.** The controller that manages Spot
capacity must not itself depend on Spot: if its node is reclaimed and nothing remains to provision a
replacement, the cluster cannot recover on its own. Two nodes because one makes the control loop a
single-node failure domain.

**Graviton is the default, not the exception.** Better price/performance for most workloads — with
the caveat that it depends on the workload actually running well on ARM, which is a claim to measure
rather than quote. The work in adopting it is upstream: the container image must be built for
`linux/arm64`. Once it is, the cluster-level change is a scheduling constraint, nothing more.

**Karpenter over Cluster Autoscaler**, because it provisions from pod requirements directly and
chooses instance types itself, rather than scaling fixed-shape node groups. The fixed-shape model is
what produces dozens of near-identical node groups that nobody dares consolidate.

### Spot is a workload property before it is a fleet setting

Spot is safe when losing an instance loses no work. For a stateless API behind a load balancer with
graceful shutdown and a `PodDisruptionBudget`, that holds. For anything holding in-flight state, it
has to be **made** true first — a claim/release model, a shutdown handler that returns unfinished
work to the queue, idempotent processing.

**If you cannot write that sentence about a workload, it does not go on Spot**, regardless of the
price difference.

Diversify across instance categories, generations and Availability Zones rather than naming
instance types. Each instance-type-per-AZ pair is an independent capacity pool and adding pools
costs nothing. Two error codes mean different things and need different responses:
`InsufficientInstanceCapacity` is transient — retry, try another AZ. `UnfulfillableCapacity` is
structural — the pools your configuration allows are exhausted, and it will recur at every peak
until the configuration widens.

---

## Autoscaling — two independent loops

| Loop | Mechanism | Signal |
| --- | --- | --- |
| **Pods** | HPA on requests-per-second or p95 latency | Application load |
| **Nodes** | Karpenter, reacting to unschedulable pods | Pending pods |

Deliberately independent. Pods scale on what users are doing; nodes scale on what the scheduler
cannot place. Coupling them produces a system where a capacity problem looks like a load problem.

**CPU utilisation is a poor HPA signal for a web API** — it lags, and it correlates badly with the
latency users actually experience. RPS or latency reflects the thing being protected.

**KEDA** when queue-driven work appears: scale on queue depth, and scale to zero between bursts.
Not before there is a queue.

**Consolidation** with `consolidateAfter` set **above the application's warm-up time**. Set it
shorter and the cluster thrashes — nodes are removed exactly as the pods on them become useful.

---

## Resource allocation

- **Requests from observed usage**, with VPA in recommendation mode to keep them honest. Requests
  set by guesswork are either wasted capacity or a throttled service, and both are invisible.
- **Memory limits: yes.** Memory is incompressible; a pod without a limit can take a node down.
- **CPU limits: generally no** for latency-sensitive services. CFS throttling produces tail latency
  that is genuinely hard to diagnose, and the request already guarantees a share. This is a
  deliberate, defensible position rather than an omission.
- **`ResourceQuota` and `LimitRange` per namespace** — the guardrail against one team's mistake
  consuming a cluster.
- **`PodDisruptionBudget` on every Deployment.** This is what makes consolidation, node upgrades and
  Spot reclamation safe rather than merely frequent.
- **Topology spread constraints** across zones, so a single AZ event does not take all replicas.

---

## Observability

| Signal | Path |
| --- | --- |
| Metrics | Prometheus → Amazon Managed Prometheus → Managed Grafana |
| Logs | Fluent Bit → CloudWatch → S3 archive, retention ≥ detection window |
| Traces | OpenTelemetry, **`trace_id` propagated end to end** — the gap that makes incident forensics guesswork when it is missing |
| Cost | OpenCost or Kubecost, per-namespace attribution |

**Alert on transitions, not on levels**, and alert on symptoms users feel — latency, error rate,
saturation — rather than on causes. An alert per cause produces a pager nobody reads.

Karpenter-specific: pending-pod count and age, provisioning latency, node count by capacity type,
Spot interruption rate. **A silent Karpenter looks exactly like a quiet cluster**, which is why
controller availability needs its own alert.

---

## What breaks

| Failure | Consequence |
| --- | --- |
| Karpenter controller down | Existing nodes keep running but are unmanaged — no provisioning, no consolidation, no interruption handling. Degraded, not dead |
| Spot reclaimed en masse | Diversification limits it; PDBs and graceful shutdown contain it; the on-demand pool is the fallback for work that cannot absorb it |
| Node IP exhaustion | Pods `Pending` with an unhelpful message. Prevented by subnet sizing, mitigated by prefix delegation |
| Cluster upgrade goes wrong | Blue/green node pools mean rolling back is shifting workloads to the previous pool, not repairing nodes in place |

---

## At scale

Karpenter NodePools are the natural unit for adding capacity classes — GPU, memory-optimised,
compliance-isolated — so growth is addition rather than restructuring. Beyond that: cluster per
region if multi-region arrives, and cluster-per-tenant only if a customer contract requires provable
isolation. **Neither is justified by user count alone.**
