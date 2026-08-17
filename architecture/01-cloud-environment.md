# Cloud environment structure

## The decision

**Three AWS accounts on day one**, under AWS Organizations. Additional accounts are added when a
named trigger fires, not on a schedule and not because a reference architecture has six boxes.

---

## Day one

| Account | Contains | Why it exists immediately |
| --- | --- | --- |
| **Management** | Organizations, IAM Identity Center, consolidated billing, SCPs | Retrofitting an Organization later means migrating every account into it. It is free and it is the one thing that is genuinely painful to add late |
| **Production** | Live workload: EKS, RDS, S3, CloudFront | |
| **Non-production** | Development and staging, separate VPCs, separate namespaces | |

### Why not two

**The AWS account is the only hard blast-radius boundary AWS offers.** IAM policies, security groups
and namespaces are all boundaries you can misconfigure. An account boundary is one you have to
deliberately cross.

With sensitive user data in production, a development mistake must not be able to reach it. That is
a **data-protection argument, and it holds at any scale** — it does not become true at some user
count. A shared account with "prod" and "dev" tags is one IAM policy away from an incident, and the
policy that protects you is written by the same people making the mistake.

### Why not five

A three-person startup running five accounts spends its scarcest resource — attention — on account
plumbing. Cross-account role chains, five sets of quotas, five places to check when something
breaks, and a bill nobody can attribute. The complexity is real on day one; the benefit arrives
later.

### Also on day one, because it is free and expensive to retrofit

- **AWS Organizations** with an organization-wide CloudTrail
- **IAM Identity Center** with MFA — no standing IAM users, no shared credentials
- **SCPs** denying root usage, denying the disabling of CloudTrail/GuardDuty, restricting regions
- **A billing alarm** — the cheapest incident detector there is

None of these require a fourth account. All of them are painful to introduce once habits have
formed around their absence.

---

## Growth structure, and what triggers each account

| Account | Trigger | What it buys |
| --- | --- | --- |
| **Security / log archive** | The first compliance conversation — SOC 2, a customer security questionnaire, an auditor — or the first person who can read production logs but should not be able to delete them | An immutable log destination that a compromise of the application account cannot reach. Delegated administration for GuardDuty and Security Hub. **A backup vault an attacker with production access cannot delete** — the ransomware argument, and the strongest single reason for this account |
| **Staging split out of non-production** | Staging becomes a release gate that developers must not be able to disturb. Usually the same week someone breaks staging during a demo | Independent quotas, independent blast radius, and a staging environment whose green light means something |
| **Shared services** | More than one environment pulls from the same ECR, or a platform team appears | One registry as the source of truth, cross-account pull policies, CI roles in one place |
| **Sandbox** | Engineers need to try things without a change-review conversation | Contains experiments. SCP-limited, budget-capped, auto-cleaned |
| **Second production account** | Data residency, or a customer contractually requiring provable isolation | The only honest answer to "prove my data is isolated". Namespaces are not it |

**The endpoint is the conventional five-to-six account structure.** The difference between this
design and a copied reference architecture is that the path is driven by triggers, and each trigger
is something that will visibly happen rather than a milestone someone has to remember.

---

## Environment separation inside an account

Non-production holds development and staging as **separate VPCs**, not separate namespaces in one
VPC. Namespaces separate workloads; they do not separate networks, and a shared VPC means a shared
CIDR, shared route tables and a shared failure domain.

Terraform state is separated by directory and by account, **not by workspace**. Workspaces share a
backend and a provider configuration, so the blast radius of an apply is not visible from the
directory you are standing in.

---

## What this costs

An empty AWS account costs nothing. The three-account structure adds no infrastructure spend — only
the discipline of assuming a role to cross a boundary.

The one real cost is **operational**: every deployment target needs its own pipeline permissions,
and every human needs a path to each account through SSO. That work is small at three accounts and
grows roughly linearly, which is the actual argument for adding accounts on triggers rather than in
advance.

---

## What breaks

**Account separation is not free of failure modes.** The common ones:

- **A role chain nobody can debug.** Mitigated by keeping the chain one hop deep: SSO → account role,
  never SSO → account → another account.
- **Quotas are per-account.** Each new account starts at default limits, including a low EC2 vCPU
  quota. Discovering that during an incident is expensive; it belongs in the account bootstrap
  checklist.
- **Drift between environments.** Three accounts means three chances for configuration to diverge.
  The answer is that the same Terraform builds all of them with different variables — if an
  environment needs different code, it is not an environment, it is a different system.

---

## At scale

Landing Zone / Control Tower becomes worth its complexity somewhere around the point where account
creation is routine rather than notable — call it a dozen accounts, or the first time someone asks
for an account and nobody is sure who should approve it. Before then it is a large amount of
machinery to manage three accounts that change twice a year.

**The trigger is the rate of account creation, not the count.**
