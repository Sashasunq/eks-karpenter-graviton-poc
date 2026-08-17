# Container build, registry and continuous delivery

## The pipeline

```
git push
   │
   ├─ test ─ lint ─ unit
   │
   ├─ docker buildx  ── linux/amd64 + linux/arm64 ──┐
   │                                                 │
   ├─ Trivy scan ─ syft SBOM ─ cosign sign ──────────┤
   │                                                 ▼
   │                                    ECR  (immutable tags,
   │                                          scan-on-push)
   │                                                 │
   └─ open PR bumping the image DIGEST in the env overlay
                          │
                    review + merge
                          │
                     Argo CD syncs ──► cluster
                     auto in staging
                     manual gate in production
```

Two halves, deliberately separated: **CI produces an artefact, CD decides where it runs.** The
pipeline never holds cluster credentials, because it never talks to the cluster.

---

## Build

- **Multi-stage Dockerfile**, slim or distroless base, running as a non-root user
- **`docker buildx --platform linux/amd64,linux/arm64`**, producing a manifest list

That second line is what makes Graviton available to the application. The cluster side of ARM
adoption is a scheduling constraint; **this is where the actual work is** — every dependency,
including native extensions and vendored binaries, has to exist for ARM. For a Flask application
that usually means checking the wheels.

Get it wrong and the symptom is `exec format error` at container start, which reads as a broken
image rather than a missing architecture.

---

## Registry

**Amazon ECR**, one repository per service.

| Setting | Why |
| --- | --- |
| **Immutable tags** | A tag that can move means the thing you tested is not necessarily the thing that shipped. This is the single most important registry setting |
| **Scan on push** (Inspector) | Findings arrive before deployment rather than during an audit |
| **Lifecycle policies** | Untagged images expire; storage does not grow without bound |
| **Cross-account pull policy** | Once a shared-services account exists |

**Deployments reference the image by digest, never by tag.** A tag is a pointer; a digest is the
artefact. Referencing by digest means the manifest in git names exactly the bytes that will run.

---

## Promotion

**Promotion is a retag of the tested digest, never a rebuild.**

Rebuilding for production produces a different artefact from the one that passed staging — different
base-image layers, different transitive dependencies, a different build host. Everything that was
verified was verified about something else. This is a small discipline that removes an entire class
of "it worked in staging".

---

## Deployment — GitOps

**Argo CD**, app-of-apps, with sync waves ordering platform → CRDs → workloads.

| Environment | Sync policy |
| --- | --- |
| Development | Automated, prune, self-heal |
| Staging | Automated, prune, self-heal |
| **Production** | **Manual sync gate** |

Why GitOps rather than the pipeline calling `kubectl apply`:

- **The cluster's desired state is a git repository**, so "what is running" and "what should be
  running" are the same question with a diff between them
- **CI never holds cluster credentials.** It writes to git; the controller pulls. The blast radius of
  a compromised pipeline is a pull request
- **Self-heal reverts manual changes**, so drift is corrected rather than reported
- **Rollback is `git revert`** — the same mechanism as deployment, exercised constantly, rather than
  a separate procedure practised only during incidents

**Deployment strategy:** rolling updates with readiness probes are sufficient at current traffic.
Argo Rollouts for canary or blue/green when there is enough traffic for a canary to mean something
statistically — below that, a 5% canary is noise, and the complexity buys a false sense of safety.

---

## Database migrations — where CD usually goes wrong

Schema changes are the part of continuous delivery that breaks, and it is worth being explicit:

- **Migrations run as a Kubernetes Job before the rollout**, not on application startup. Startup
  migrations race between replicas.
- **Expand/contract, always.** Add a nullable column, deploy code that writes both, backfill, deploy
  code that reads the new one, then drop the old. Never a change that requires code and schema to
  land simultaneously.
- **Every migration must be backwards compatible with the previous release**, because that is what
  makes rollback possible. A migration that is not means the application cannot be rolled back, and
  that fact is discovered during the incident.

This matters more than the choice of deployment tool, and gets a fraction of the attention.

---

## What CI is allowed to do

| CI has | CI does not have |
| --- | --- |
| OIDC federation to a scoped AWS role | Long-lived AWS keys |
| Push to one ECR repository | Cluster credentials |
| Write access to a git repository | `kubectl` access of any kind |
| Read secrets required to build | Production database access |

The role's trust policy is conditioned on `sub` = `repo:org/repo:ref:refs/heads/main`. Without that
condition **any GitHub repository in the world can assume the role** — the OIDC issuer is shared, and
this is the single most common mistake in OIDC setups.

---

## What breaks

| Failure | Consequence | Mitigation |
| --- | --- | --- |
| Argo CD unavailable | Running workloads unaffected; deployments stop | It is not in the request path. Restore from git |
| Bad image reaches production | Blast radius of one service | Manual gate, canary when traffic justifies, rollback is a revert |
| Registry unavailable | Running pods fine; new pods cannot pull | Image pull policy, ECR replication if it becomes a real risk |
| Migration fails mid-deploy | Potentially unrecoverable | Expand/contract; migrations as a Job with a failure gate before rollout |
| Signing key compromised | Malicious images pass admission | Short-lived keys via keyless signing, transparency log |

---

## At scale

Preview environments per pull request; progressive delivery with automated rollback on SLO breach;
policy-as-code admission so "please don't deploy that" stops being a Slack message. **All of them
are answers to problems that appear with team size, not user count** — which is why none is on day
one.
