# Security

"Sensitive user data" is the constraint that justifies spending early. Controls below are ordered by
**severity of the failure if the control is absent**, not by effort — because that ordering is what
survives a quarter where nobody has time.

---

## The structural problem, before the control list

Most security programmes do not fail at finding problems. **They fail at fixing them.** Audits
complete; remediation does not. An audit is self-contained and one person can finish it; almost no
remediation is single-owner — rotating a credential needs a coordinated redeploy, an identity change
needs an organisational decision, a code fix lives in someone else's repository.

And security has no external forcing function until there is an incident. Cost has a bill.
Reliability has an outage. Security has a document.

**The one intervention that changes the outcome: every finding becomes a ticket with an owner and a
severity on the day it is found.** It sounds bureaucratic. It is the difference between an audit and
a change, and it belongs in this document ahead of any control.

---

## Controls

| # | Control | What it prevents |
| --- | --- | --- |
| 1 | **No static credentials anywhere.** Humans via IAM Identity Center + MFA; workloads via EKS Pod Identity, one role per service; CI via GitHub OIDC federation | A baked-in key is unrevocable in practice once an image ships, has indefinite blast radius, and will be copied to a second place before long |
| 2 | **Deletion protection** on RDS, plus S3 versioning and MFA-delete on the backup vault | The only control here whose absence is *unrecoverable*. Everything else is a bad day; this is a company-ending one |
| 3 | **Private data tier with no route to NAT** | The path data leaves by |
| 4 | **KMS customer-managed keys** for RDS, EBS, S3 and Secrets Manager | Key ownership, key-policy control and a CloudTrail record of key use — which is the actual reason, and which compliance regimes ask for by name |
| 5 | **Secrets in Secrets Manager**, delivered by External Secrets Operator, with rotation schedules | "Where is that password?" having exactly one answer. Nothing in manifests, nothing in images, nothing in environment variables checked into git |
| 6 | **Private EKS API endpoint**, access via SSM Session Manager or VPN | No public control-plane surface. IAM still authenticates, but network position is defence in depth and it is the layer that remains if credentials leak |
| 7 | **Encryption in transit including internal paths** — TLS at the ALB, `rds.force_ssl`, TLS between services | Internal is where it is usually missing, because "it's inside the VPC" feels like an answer |
| 8 | **Default-deny NetworkPolicy**, explicit allows | Lateral movement. A compromised pod that can reach only what it needs is a contained incident |
| 9 | **Pod Security Standards `restricted`** — non-root, read-only root filesystem, no privilege escalation, seccomp `RuntimeDefault` | Container escape being trivial |
| 10 | **No inbound shell ports.** SSM Session Manager, audited | An entire key-distribution problem, and an audit gap |
| 11 | **Supply chain**: Trivy in CI, ECR scan-on-push with Inspector, images referenced by **digest**, cosign signing with an admission policy verifying signatures | Deploying something nobody looked at, and tag mutation between test and production |
| 12 | **GuardDuty** including EKS Protection, **Security Hub**, audit logs to the security account with retention ≥ the detection window | Finding out from a third party |

---

## Identity, end to end

| Layer | Mechanism | Why there is no credential to steal |
| --- | --- | --- |
| Human → AWS | IAM Identity Center, MFA, permission sets per account | Sessions expire |
| CI → AWS | GitHub OIDC → `sts:AssumeRoleWithWebIdentity`, trust policy conditioned on `sub` = `repo:org/repo:ref:refs/heads/main` | Token minted per run, scoped to one repository and branch |
| Human → Kubernetes | `aws eks get-token`, EKS **access entries** mapping SSO groups to namespace-scoped roles | No stored kubeconfig; a stored one goes stale the moment the cluster is recreated |
| Pod → AWS | EKS Pod Identity association per service account | Short-lived credentials from the agent; never on disk, never in an env var |
| Node → AWS | Instance role, IMDSv2 required, **hop limit 1** | Pods are one network hop too far to reach IMDS, so they cannot assume the node role |

**No standing cluster-admin for anyone, and none at all for CI.** CI needs permission to update a
digest in a git repository. Argo CD needs permission to apply manifests. Neither needs
cluster-admin, and giving it to a pipeline means every commit is a potential privilege escalation.

---

## What sensitive data specifically adds

Beyond the baseline, because "sensitive user data" is a stated requirement rather than a
nice-to-have:

- **Data classification written down.** Which fields are sensitive, who may read them, how long they
  are retained. Without this, every later question — encryption scope, log redaction, deletion
  requests — has no answer to check against.
- **Field-level encryption for the most sensitive attributes**, so a database compromise is not
  automatically a data breach.
- **Log redaction at the source.** Application logs are the most common place sensitive data escapes
  from, and once it is in a log aggregator it is in backups too.
- **Break-glass access to production data**, time-boxed and alerting on use — rather than standing
  read access for engineers.
- **Deletion path.** If users can request deletion, that has to work through backups too, and it is
  far easier to design in than to retrofit.

---

## What breaks

- **Pod Identity agent add-on missing** → workloads get `AccessDenied` with no mention of the agent
  in the error. Diagnosis path belongs in the runbook.
- **IMDS hop limit 1 with a workload that genuinely needs IMDS** → that workload fails. The fix is
  Pod Identity for it, not raising the hop limit for everything.
- **KMS key disabled or deleted** → for RDS, the database becomes unrecoverable. Key administration
  needs least-privilege policies and a CloudWatch alarm on key state; this is a real failure mode,
  not a theoretical one.
- **Default-deny NetworkPolicy applied without mapping flows first** → an outage that looks like a
  DNS problem. Roll out in audit mode first.

---

## At scale

Nothing above changes shape; the volume does. What gets added:

- **Delegated administration** of GuardDuty and Security Hub from the security account
- **Automated evidence collection** for SOC 2 rather than a person gathering screenshots
- **Policy as code** — Kyverno or Gatekeeper — once "please don't do that" stops scaling as a control
- **Formal incident response** with named roles, because at five engineers the incident commander is
  whoever noticed

The thing that does **not** change: converting findings into owned, dated tickets on the day they
are found. That is what makes the rest of the list real.
