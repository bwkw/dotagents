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

### 1. Destructive resource change and replacement ★highest irreversibility

- Does a changed or moved **logical ID or address** cause a **replace or delete**?
- Replacement, deletion, or rename of **stateful** resources (RDS/Aurora, S3, DynamoDB, EBS,
  ElastiCache, SQS/SNS, EFS, Cognito) causing **data loss**.
- Changes to immutable properties (database engine, encryption, availability zone, subnet, bucket
  name) forcing replacement; resources that vanished or were renamed in the snapshot tests.
- Destructive DNS and certificate changes (deleting or switching a Route53 record, TTL, ACM, custom
  domains) causing unreachability or expiry. This is a distinct category of irreversible risk from
  replacement and state loss.

### 2. State loss, protection, backup and DR ★highest irreversibility

- `RemovalPolicy`, `deletionProtection`, `prevent_destroy`, `lifecycle`: is a stateful resource set
  to DESTROY or otherwise deletable, and has RETAIN been removed unintentionally?
- Backups, snapshots, PITR, snapshot-on-delete, and **whether a restore procedure actually exists
  and can be exercised** (DR).
- Effects on Terraform state or CDK context; drift.

### 3. IAM, permissions, exposure, networking ★security focus

- Least privilege: `*` actions or resources, `iam:PassRole`, widening `AssumeRole` trust.
- Widened exposure: security groups, NACLs, bucket policies, public settings (`0.0.0.0/0`,
  public-read, placement in a public subnet); network boundaries (VPC, subnets, endpoints, egress).
- Secrets: any in plaintext, or properly via Secrets Manager / SSM / KMS? Exposure through logs or
  stack outputs. Encryption at rest and in transit; KMS key policy; **the irreversibility of key
  deletion**.
- CDN and caching: cache keys, caching of authenticated responses, header forwarding, signed URLs
  and OAI — could this cause cross-tenant leakage or cache poisoning?

### 4. Availability, deploy safety, rollback

One-way deletions and irreversible migrations are filed with `irreversible=true`.

- Zero-downtime: replacement ordering, connection draining, health checks, rolling / blue-green /
  canary.
- Rollback: is a one-way deletion or an irreversible migration wedged in the middle?
- Multi-AZ and redundancy; creation ordering and circular dependencies; the effect of schedule and
  concurrency changes.

### 5. Cost, scale, runaway prevention

- Timeouts, memory, concurrency; unbounded retries and runaway pagination; autoscaling ceilings;
  unintended expense (NAT gateways, large instances, provisioned capacity); log and data retention.

### 6. Idempotency and consistency in pipelines and jobs

- Re-runs, partial failures, and duplicate delivery must not double-process or corrupt data
  (chunking, checkpoints); dead-letter handling; failure handling.

### 7. Observability, alerting, operability

- Do new resources and paths get **monitoring, alarms, and dashboards**? Log aggregation. On-call
  runbook and recovery procedure. Tagging, naming, governance. Data residency and compliance.
