# PostgreSQL, high availability, backups and disaster recovery

## The decision

**Amazon RDS for PostgreSQL, Multi-AZ, at launch.** Aurora PostgreSQL is the documented migration
target, with a named trigger — not a default.

---

## Why RDS rather than Aurora on day one

Aurora is the reflexive answer and it is a good product. At a few hundred users a day it is a larger
bill for capability nobody is using: the storage architecture that makes Aurora valuable pays off
under read-heavy load, many replicas, or a failover requirement Multi-AZ cannot meet. None of those
is true yet.

**The trigger to move:**

- Read replica lag becomes a product problem, or read traffic needs more than one or two replicas
- An RTO requirement that RDS Multi-AZ failover (typically a minute or two) cannot meet
- Storage growth or IOPS patterns that make Aurora's model cheaper rather than costlier

The migration path is well-trodden — snapshot restore, or logical replication for near-zero
downtime. **It is deliberately not a one-way door**, which is what makes starting simple safe.

## Why not PostgreSQL in the cluster

Managed data services stay outside Kubernetes. Operators have improved considerably, and this is
still the wrong trade for a five-engineer team holding sensitive user data: you inherit backup
correctness, failover correctness, version upgrades and storage management, in exchange for saving a
managed-service margin.

**Running a database on autoscaled Spot capacity is the fastest way to lose data.** The whole node
strategy in [04-kubernetes.md](04-kubernetes.md) — Spot by default, consolidation, node expiry — is
correct for stateless workloads and actively hostile to a database.

---

## Configuration

| Setting | Value | Why |
| --- | --- | --- |
| Deployment | **Multi-AZ** | Automatic failover; the standby is not a read replica and that is fine |
| Subnets | **private-data**, no route to NAT | The database cannot initiate outbound internet connections. See [02-network.md](02-network.md) |
| Access | Security group allowing 5432 **only from the EKS node security group** | Not a CIDR. Security-group-to-security-group references survive subnet changes |
| Encryption at rest | **KMS customer-managed key** | Key ownership, key policy, CloudTrail record of use |
| Encryption in transit | `rds.force_ssl = 1` | Enforced, not optional. Internal is where TLS is usually missing |
| Credentials | Secrets Manager with rotation, or **IAM database authentication** | IAM auth is better where the driver supports it — no password to rotate |
| **Deletion protection** | **On** | The one control whose absence is unrecoverable |
| Backup retention | Set by the compliance requirement, not the default | |
| Monitoring | Performance Insights, Enhanced Monitoring | Slow-query visibility before it is an incident |
| Upgrades | Minor auto in a maintenance window; major deliberately, tested on a restored snapshot first | |

**Connection pooling matters earlier than people expect.** PostgreSQL connections are expensive, and
a Flask application with several replicas each holding a pool exhausts `max_connections` at
surprisingly low traffic. PgBouncer as a sidecar or a deployment, or RDS Proxy — which also holds
connections open across failover, shortening the outage the application actually sees.

---

## High availability

| Layer | Mechanism | Failure absorbed |
| --- | --- | --- |
| SPA | CloudFront, global | Region-level edge failure |
| API | ALB across 3 AZs; pods spread by topology constraints | Node, AZ |
| Database | RDS Multi-AZ standby | AZ, instance failure |

**Single region until a stated availability requirement exists.** Multi-region buys resilience, not
savings, and it is paid for daily in complexity — data replication, failover orchestration, and a
consistency model the application has to understand. It is a business decision about the cost of
downtime, and it should be made with a number attached rather than by default.

---

## Backups

| Layer | Mechanism | Protects against |
| --- | --- | --- |
| Automated snapshots + **PITR** | RDS, retention per compliance | Corruption, accidental deletion, bad migration |
| **AWS Backup vault in the security account** | Cross-account, MFA-delete | **An attacker with production access deleting the backups.** This is the ransomware argument and the single strongest reason for that account |
| Cross-region backup copy | AWS Backup | Region loss |
| S3 versioning | User uploads | Object-level accident |

**Cross-account is the point.** Backups reachable from the account they protect are not protecting
you from the scenario that actually ends companies.

---

## Disaster recovery

| Failure | Mechanism | RTO | RPO |
| --- | --- | --- | --- |
| Pod or node | Kubernetes reschedules | seconds | 0 |
| Availability Zone | Multi-AZ, automatic | ~1–2 min | ~0 |
| Data corruption or deletion | PITR restore | ~1 hour | to the second, within the PITR window |
| Backup vault restore | AWS Backup, cross-account | hours | to last copy |
| **Region loss** | Restore from cross-region copy into a Terraform-rebuilt environment | **hours — an explicit business decision** | bounded by copy frequency |

**These numbers are proposals until a restore has been timed.** An RTO in a table that nobody has
measured is a wish.

### A backup that has never been restored is not a backup

The single most important line in this document.

**Quarterly restore drills**, and the drill result is the evidence: restore the latest snapshot into
a scratch environment, run migrations, point a test suite at it, record the wall-clock time. That
recorded time is the RTO. Anything else is an estimate of an estimate.

The drill also tests the parts people forget — that the KMS key is accessible from the restoring
account, that the security group allows the restored instance, that someone knows the runbook.

---

## What breaks

| Failure | Consequence | Response |
| --- | --- | --- |
| KMS key disabled or deleted | Database unrecoverable | Least-privilege key policy, CloudWatch alarm on key state. This is why key administration is not a side task |
| Connection exhaustion | API returns errors while the database is healthy | Pooling, and an alarm on connection count as a fraction of `max_connections` |
| Failover during a long transaction | Transaction lost, application must retry | Retry logic and idempotent writes. Failover is not transparent, whatever the marketing says |
| Bad migration in production | Potentially data loss | Expand/contract migrations, PITR as the floor. See [05-delivery.md](05-delivery.md) |
| Storage full | Writes fail | Storage autoscaling on, with an alarm well before the ceiling |

---

## At scale

- **Read replicas** when reads outgrow the writer — usually the first scaling step, and often enough
- **Aurora** at the trigger above
- **Caching** — ElastiCache — in front of the expensive queries. Frequently a better answer than a
  bigger database, and almost always a cheaper one
- **Partitioning or sharding** last. It changes the application, and by the time it is genuinely
  necessary the team is different from the one reading this document
