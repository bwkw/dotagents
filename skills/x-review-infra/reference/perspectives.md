# Infrastructure / IaC layer — what to trace, and the perspective clusters

The two layer-specific parts of the review: **Step 2** (what to trace) and **Step 5** (the perspective
clusters to fan out across). Posture, the seven steps, and the finding discipline come from the skill
that sent you here.

If you arrived here without having read `finding-discipline.md` and `review-process.md`, **read those
first** — this file assumes both. `silent-failure-patterns.md` applies on top of whichever cluster you
are assigned; pattern 4 is native to this layer.

**Read-only. Never modify anything.**

> **Never run `apply`, `deploy`, `destroy`, or `import`.** Read-only synthesis (`cdk synth`,
> `terraform plan`, `cdk diff`) is acceptable *only* where the environment permits it and it consumes
> no credentials you were not given. When you cannot run it, say so and infer the logical change
> from the code and snapshot diffs instead.

---

## Step 2 — what to trace in this layer

1. **Changed units**: constructs, modules, stacks, resources, IAM, networking, config added,
   changed, or removed.
2. **Track logical IDs and resource addresses.** Pin down each resource's **logical ID, physical
   name, and dependencies**. This matters most: a changed or moved logical ID silently becomes a
   **replace or delete**.
3. **Enumerate the blast radius**:
   - A change to a shared construct or module requires **naming every stack and every environment
     (dev / staging / prod) that uses it**.
   - Follow dependent resources: referenced VPCs, security groups, IAM, KMS, buckets, cross-stack
     exports and imports.
   - Understand the per-environment differences (environment-specific config and parameters).
4. **Check the synthesised diff** — read-only operations only:
   ```bash
   # e.g. cdk diff / terraform plan -- never apply or deploy
   ```
   If you cannot run it, infer the logical change from the code plus the snapshot (`*.snap`) diff.

---

## Perspective clusters

### 0. Design soundness and the question one level up ★system-wide

Required even for a small diff. When collapsing the fan-out, this must still land in one subagent.

- Is this topology, this design, **correct at all** — resource choice, boundaries, environment
  separation, and is there a simpler or safer alternative?
- **Verify the foundation.** Open at least once the shared construct or module, the state, the
  naming convention, and the existing pattern this depends on, and confirm through the synthesised
  diff or `file:line` that the premises around replacement, deletion, and permission scope actually
  hold. Do not skip it because "it has always been this way". Cannot confirm → 👤. Suspicious → 🧭.
- **Propagation risk**: is this adding the Nth instance of a dangerous pattern — RETAIN removed, a
  broad IAM or trust policy, a changed logical ID, a naming collision — to another stack or
  environment? → 🧭
- Naming, tagging, governance; over- and under-engineering.

### 1. Intent and semantic correctness ★always covered

**The largest category of bugs that survive review, by a wide margin.** In this layer it is usually
configuration that is syntactically valid and semantically wrong — and it applies cleanly.

- **Against the stated intent.** Does the resource definition express what was asked for? **If there is
  no stated intent, that is the finding** → 👤.
- **Values that are wrong rather than absent.** A timeout in seconds where the API takes milliseconds, a
  retention of 1 where 1 day was meant, a CIDR one bit wider than intended, a memory limit below what
  the process needs. **A plan that shows no error says nothing about whether the value is right.**
- **Wrong operator or condition in a policy or rule.** `Allow` where `Deny` was meant, a condition key
  that never matches so the guard never applies, `NotAction` semantics, a wildcard that widens more than
  the author read it as.
- **Missing mechanism.** The parameter is set but nothing reads it; the alarm exists but has no action;
  the rule is defined but not attached; the schedule exists but the target does not.
- **Incomplete change.** One environment updated and the others not; a resource renamed in one module
  and referenced by the old name elsewhere.

### 2. Destructive resource change and replacement ★highest irreversibility

- Does a changed or moved **logical ID or address** cause a **replace or delete**?
- Replacement, deletion, or rename of **stateful** resources (RDS/Aurora, S3, DynamoDB, EBS,
  ElastiCache, SQS/SNS, EFS, Cognito) causing **data loss**.
- Changes to immutable properties (database engine, encryption, availability zone, subnet, bucket
  name) forcing replacement; resources that vanished or were renamed in the snapshot tests.
- Destructive DNS and certificate changes (deleting or switching a Route53 record, TTL, ACM, custom
  domains) causing unreachability or expiry. This is a distinct category of irreversible risk from
  replacement and state loss.

### 3. State loss, protection, backup and DR ★highest irreversibility

- `RemovalPolicy`, `deletionProtection`, `prevent_destroy`, `lifecycle`: is a stateful resource set
  to DESTROY or otherwise deletable, and has RETAIN been removed unintentionally?
- Backups, snapshots, PITR, snapshot-on-delete, and **whether a restore procedure actually exists
  and can be exercised** (DR). A backup nobody has restored from is a hypothesis. Ask when it was last
  exercised, and mark 👤 if the answer is not in the repository.
- **The state file is itself sensitive infrastructure**, and reviews routinely skip it:
  - **Terraform state stores resource attributes in plaintext, including secrets** — generated
    passwords, keys, connection strings. So read access to state is equivalent to read access to those
    secrets. Who can read the bucket?
  - Remote backend **encrypted at rest**, **versioned** so a corrupted state can be rolled back, and
    **locked** (DynamoDB or the backend's native locking) so two applies cannot interleave. A missing
    lock is a corruption risk that only shows up under concurrency, which is to say during an incident.
  - Changes that move state — `moved` blocks, `terraform state mv`, refactoring a module path — are as
    dangerous as changing a resource, because getting them wrong destroys and recreates.
- **Drift**: does this change assume a state that matches reality? If the last apply was manual or
  partial, the plan is computed against a lie.
- **Provider and module versions pinned**, and the pin actually intended. An unpinned provider means the
  next apply is a different apply, run by whoever happens to go next.

> **Run the scanners rather than reading for these.** `checkov` and `trivy config` (formerly `tfsec`)
> cover the mechanical CIS-style checks — public buckets, unencrypted volumes, open security groups,
> missing logging — faster and more completely than a human pass. Report what they found, and spend your
> own attention on blast radius, intent, and ordering, which they cannot see. If you cannot run them,
> say so; do not silently substitute eyeballing for a scan.

### 4. IAM, permissions, exposure, networking ★security focus

- Least privilege: `*` actions or resources, `iam:PassRole`, widening `AssumeRole` trust.
- Widened exposure: security groups, NACLs, bucket policies, public settings (`0.0.0.0/0`,
  public-read, placement in a public subnet); network boundaries (VPC, subnets, endpoints, egress).
- Secrets: any in plaintext, or properly via Secrets Manager / SSM / KMS? Exposure through logs or
  stack outputs. Encryption at rest and in transit; KMS key policy; **the irreversibility of key
  deletion**.
- CDN and caching: cache keys, caching of authenticated responses, header forwarding, signed URLs
  and OAI — could this cause cross-tenant leakage or cache poisoning?

### 5. Availability, deploy safety, rollback

One-way deletions and irreversible migrations are filed with `irreversible=true`.

- Zero-downtime: replacement ordering, connection draining, health checks, rolling / blue-green /
  canary.
- Rollback: is a one-way deletion or an irreversible migration wedged in the middle?
- Multi-AZ and redundancy; creation ordering and circular dependencies; the effect of schedule and
  concurrency changes.

### 6. Cost, scale, runaway prevention

- Timeouts, memory, concurrency; unbounded retries and runaway pagination; autoscaling ceilings;
  unintended expense (NAT gateways, large instances, provisioned capacity); log and data retention.

### 7. Idempotency and consistency in pipelines and jobs

- Re-runs, partial failures, and duplicate delivery must not double-process or corrupt data
  (chunking, checkpoints); dead-letter handling; failure handling.

### 8. Observability, alerting, operability

- Do new resources and paths get **monitoring, alarms, and dashboards**? Log aggregation. On-call
  runbook and recovery procedure. Tagging, naming, governance. Data residency and compliance.
