# Network architecture

## The decision

One VPC per environment, three Availability Zones, **four subnet tiers**. The SPA is served from a
CDN and never enters the VPC.

```
                          Route 53
                    ┌─────────┴─────────┐
              CloudFront              ALB + WAF
              (SPA, OAC)              (api.innovate.inc)
                    │                     │
                   S3                     │
              private bucket              │
                                          ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ VPC 10.x.0.0/16 — one per environment, non-overlapping        │
  │                                                               │
  │  public/a       public/b       public/c      ← ALB, NAT       │
  │      │              │              │                          │
  │  ┌───▼──────────────▼──────────────▼───┐                      │
  │  │ private-app /20 × 3   EKS nodes      │  ← no public IPs    │
  │  └───┬──────────────────────────────────┘                     │
  │      │                                                        │
  │  ┌───▼──────────────────────────────────┐                     │
  │  │ private-data /24 × 3   RDS           │  ← no route to NAT  │
  │  └──────────────────────────────────────┘                     │
  │                                                               │
  │  VPC endpoints: S3 (gateway), ECR api+dkr, Secrets Manager,   │
  │                 STS, CloudWatch Logs, eks-auth                │
  └───────────────────────────────────────────────────────────────┘
```

---

## Why four tiers rather than two

The tier that earns its place is **private-data**, and it earns it with one property: **it has no
route to the NAT Gateway.**

A database in a private subnet with a default route to NAT can still initiate outbound connections
to the internet. That is the path data leaves by. Removing the route means an application-layer
compromise cannot exfiltrate directly from the database tier — it has to come back through the
application, where there is logging and rate limiting.

This costs a route table and is the single highest-value line in this document for a system holding
sensitive data.

---

## Subnet sizing

Private-app subnets are **/20**. This is not arbitrary: the VPC CNI assigns pod IP addresses from
the subnet, so **subnet size is what bounds pod density per Availability Zone**. IP exhaustion is
the classic EKS wall, it appears as unschedulable pods with a confusing message, and it is
enormously cheaper to avoid at design time than to fix in a running cluster.

Private-data subnets are /24 — RDS needs a handful of addresses, not four thousand.

**VPC CIDRs must not overlap between environments.** Peering, Transit Gateway and VPN all become
impossible later if they do, and "we will never need to connect dev to prod" is a promise that gets
broken by the first data-migration task.

---

## The SPA is not on Kubernetes

React build output is static files. Serving them from S3 behind CloudFront with Origin Access
Control means:

- The bucket is private; only CloudFront can read it
- No pods, no scaling, no deployment risk for the front end
- Global edge caching, which no cluster-based approach matches
- The front end cannot take the API down and vice versa

**This is the cheapest correct decision in the whole design**, and the most commonly got wrong —
putting nginx in a Deployment to serve static assets adds a scaling dimension, an ingress path and a
failure mode in exchange for nothing.

---

## Ingress

**ALB via the AWS Load Balancer Controller**, TLS terminated at the ALB with an ACM certificate,
**AWS WAF attached** to both the ALB and the CloudFront distribution.

WAF is on from day one rather than added later, because the managed rule groups cost little, cover
the common automated traffic, and the alternative is discovering the need for them during the
incident that justifies them.

Kubernetes `Ingress` today; the **Gateway API** is the direction of travel, and its role separation —
infrastructure owns the Gateway, application teams own routes — matters once more than one team
deploys. Not yet, at five engineers.

---

## Egress

**NAT Gateway per Availability Zone.** Not one shared: a single NAT makes egress for the entire
cluster depend on one AZ staying healthy, and it adds cross-AZ data charges on every byte. In a
short-lived proof of concept the trade goes the other way; in production it does not.

**VPC endpoints** for S3 (gateway, free), ECR api and dkr, Secrets Manager, STS, CloudWatch Logs and
`eks-auth`. These are added because at production egress volume the per-GB NAT charge dominates,
image pulls are the largest single contributor, and traffic that never leaves the AWS network is
both cheaper and easier to reason about.

**The crossover is worth knowing rather than assuming:** interface endpoints bill hourly per AZ, so
below a few tens of GB a month a NAT Gateway is cheaper. The right time to add each endpoint is when
its traffic justifies it, which is a number you can read from VPC Flow Logs rather than guess.

**Public container registries need internet egress regardless** — no VPC endpoint reaches
`public.ecr.aws` or Docker Hub. A design that wants no internet path at all from the data plane has
to mirror base images into private ECR first, which is a real hardening step and a real amount of
work.

---

## Observability of the network

- **VPC Flow Logs** to the security account once it exists, to S3 before then
- **NAT Gateway `ErrorPortAllocation`** is the alarm that matters — port exhaustion presents as
  intermittent, unattributable application errors, and almost nobody has an alert for it until the
  first time
- **ALB 5xx and target-health** metrics with alerts on transitions, not on levels

---

## What breaks

| Failure | Consequence | Response |
| --- | --- | --- |
| One AZ lost | ALB and nodes in the other two absorb traffic; RDS fails over | Automatic. This is what three AZs are for |
| NAT in one AZ lost | Only that AZ's nodes lose egress | Per-AZ NAT contains it; a shared NAT would not |
| IP exhaustion in private-app | Pods stay `Pending`, message does not obviously say "IP" | Avoided by /20 sizing; if it happens, VPC CNI prefix delegation buys headroom without renumbering |
| CIDR collision discovered late | Peering and Transit Gateway impossible | Avoided by allocating non-overlapping ranges before the first VPC exists |

---

## At scale

- **Prefix delegation** on the VPC CNI when pod density per node becomes the constraint
- **Transit Gateway** when there are more than a handful of VPCs to connect — before that, peering
  is simpler and cheaper
- **PrivateLink** for exposing internal services to another account without traversing the internet
- **Multi-region** only against a stated availability or residency requirement. It is a
  fundamentally different design — the data layer decides, not the network — and adopting it for
  resilience alone buys less than most people expect for what it costs every day
