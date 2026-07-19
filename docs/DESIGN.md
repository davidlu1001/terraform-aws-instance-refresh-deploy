# Design: pointer + convergence

This module implements one deployment model for plain EC2 Auto Scaling Groups:
a fully-baked AMI per release, an SSM parameter that names the current release,
and an ASG instance refresh that converges the fleet onto it. No blue/green, no
CodeDeploy, no Kubernetes.

## The model

A deploy is three moves:

1. **Bake** a new AMI containing the release (out of scope for this module — use
   Packer or EC2 Image Builder).
2. **Point** the SSM parameter at the new AMI ID.
3. **Converge** by starting an instance refresh. New instances resolve the
   pointer at launch time (`resolve:ssm:` in the launch template), so the refresh
   replaces old instances with ones running the new AMI.

The launch template never changes across a code deploy. The pointer is the
release; the refresh is the mechanism.

### The state-space argument

The reason to prefer this over blue/green or a second fleet is that it keeps the
number of live states small. At any moment the system is described by two
values: the pointer, and the set of AMIs currently running. A deploy is a
transition from `(old, {old})` to `(new, {new})`, passing briefly through
`(new, {old, new})` during the refresh. There is one ASG, one launch template,
one parameter. Rollback is the same transition run backwards.

Blue/green doubles this: two ASGs, two target group attachments, a traffic-shift
resource, and a matrix of "which color is live / which is warm / which is being
built" states that has to be reasoned about and kept consistent. Every extra
long-lived resource is another axis the on-call engineer holds in their head at
3am. The pointer model spends that complexity budget on nothing.

The cost of the small state space is honest and worth naming: a release is
identified only by an AMI ID, and a failed deploy leaves the pointer advanced
(see D1). You detect and repair that with `status` and `rollback`, not with a
second fleet standing by.

## Decisions

### D1 — Pointer via `resolve:ssm` in the launch template

**Decision.** The launch template sets
`image_id = "resolve:ssm:<parameter-name>"`. The template is immutable across
deploys. Terraform seeds the parameter once with `initial_ami_id` and then
`ignore_changes = [value]` hands ownership to the driver.

**Alternatives considered.**

- *Pointer as the launch template version.* Bake the AMI ID into a new launch
  template version on each deploy and move the ASG to it. Rejected: the driver
  must now mutate the launch template, which reintroduces the state it was
  supposed to remove — every deploy creates a versioned resource, version
  cleanup becomes a chore, and Terraform and the driver fight over who owns the
  template's `image_id`. `resolve:ssm` keeps the template constant and puts the
  only moving value in one parameter whose history is a free audit log.

**Why it matters — three consequences to internalize.**

1. **Never use SkipMatching.** Instance refresh's SkipMatching optimization
   skips instances whose launch template version and configuration already
   match the desired one. Because the template version does not change on a
   deploy, *everything* matches, so SkipMatching would skip the entire fleet and
   the new AMI would never roll out. The driver hard-codes `SkipMatching: false`.
2. **Scale-out launches the new release.** Once the pointer moves, any unrelated
   scale-out — an ASG policy reacting to load, an instance replaced after a
   health-check failure — launches the *new* AMI, because a fresh instance
   resolves the current pointer. This is intended: a fresh instance is a fresh
   release. It also means a failed deploy that left the pointer advanced will
   serve the failed release to any instance launched before you roll back. Use
   `status` to see pointer/reality drift and `rollback` to repair it.
3. **Rollback needs no CI/CD.** Rollback is "write the old AMI ID, refresh."
   The parameter's history (`get-parameter-history`) records every value with a
   timestamp, which is both the deploy log and the source for
   `rollback --previous`.

### D2 — Scope: the ASG and the pointer, nothing else

**Decision.** The module manages the SSM parameter, the launch template, the
ASG, and (behind a flag) a Terraform-driven instance-refresh block. It *accepts*
VPC/subnet IDs, security group IDs, an IAM instance profile name, target group
ARNs, alarm names, and user data as inputs. It creates none of them.

**Alternatives considered.**

- *Batteries-included module that also creates the VPC, IAM, and ALB.* Rejected:
  every organization already has opinions and existing modules for networking,
  IAM, and load balancing. Owning those would force our choices on adopters and
  balloon the API. Accepting IDs keeps the module composable and small.

**Why.** The module's one job is the release mechanism. Everything else is a
dependency the caller wires in.

### D3 — Deploys run in the driver, not in `terraform apply`

**Decision.** `terraform apply` never performs a code deploy. The driver
(`scripts/deploy.sh`) calls `start-instance-refresh` directly. The ASG sets
`ignore_failed_scaling_activities = false` and, by default, has no
`instance_refresh {}` block. The optional `enable_tf_driven_refresh` variable
adds that block for teams who want Terraform-side changes (like `instance_type`)
to roll the fleet on apply.

**Alternatives considered.**

- *Trigger deploys through Terraform* (e.g. a `null_resource` that starts a
  refresh when a variable changes, or always configuring `instance_refresh`).
  Rejected: it couples releases to plan/apply cycles and state locking, makes
  rollback a Terraform operation, and blurs the line between "change the
  infrastructure" and "ship the app." Keeping deploys in a script means a
  release is a single idempotent command any operator or pipeline can run
  without touching state.

**Why.** Config changes and code deploys have different blast radii and
different cadences. Separating them keeps each one legible.

### D4 — Capacity-adaptive refresh defaults

**Decision.** The driver reads the ASG's live desired capacity at run time and
picks refresh parameters to fit:

| Desired | MinHealthy | MaxHealthy | Checkpoints | Notes |
|---------|-----------|-----------|-------------|-------|
| ≤ 1     | 100       | 200       | none        | Launch-before-terminate surge; no room to hold a fraction back. |
| 2–3     | 100       | 150       | 50, 100     | Keep the whole current fleet up while a canary batch proves out. |
| ≥ 4     | 90        | 150       | 50, 100     | Allow one instance down to bound the surge on larger fleets. |

`--min-healthy`, `--max-healthy`, `--checkpoints`, `--checkpoint-delay`, and
`--warmup` override any of it. Instance warmup defaults to the ASG's health
check grace period.

**Alternatives considered.**

- *One fixed preference set for all ASGs.* Rejected: a single instance can't hold
  50% back and still replace itself, while a 20-instance fleet shouldn't surge to
  200%. Fixed values are wrong at one end or the other.

**Why.** The right refresh shape is a function of fleet size, and the fleet size
is already known at deploy time. Deriving it removes a decision the operator
would otherwise get wrong under pressure.

### D5 — Safety gates in the driver

**Decision.** Before any mutation the driver runs a preflight: the target AMI
exists and is `available`; its architecture matches the currently-deployed AMI
(best effort); no refresh is already in progress; and, if `--alarms` was given,
every named alarm is in `OK`. Alarms passed with `--alarms` are both the
pre-deploy gate and attached to the refresh's `AlarmSpecification` with
auto-rollback, so a release that trips an alarm mid-roll reverts itself.

`--incident` skips the pre-deploy alarm gate and disables auto-rollback, with a
loud warning. This exists because of a paradox: during an incident the alarms
are *already firing*, so a gate that requires them green would block the very
rollback meant to fix the incident, and an auto-rollback armed against a
firing alarm would immediately undo the rollback. Incident mode is the escape
hatch, used deliberately.

A confirmation prompt shows current → target AMI before any deploy or rollback,
skippable with `--yes` for automation.

**Alternatives considered.**

- *No gates; trust the operator.* Rejected: the cheapest failures (typo'd AMI ID,
  wrong architecture, deploying onto an already-firing alarm) are exactly the
  ones a few API calls catch for free.
- *Always require alarms green, no incident bypass.* Rejected: it makes the tool
  useless in the one situation — a live incident — where fast rollback matters
  most.

### D6 — Repository layout

Root module (`main.tf`, `variables.tf`, `outputs.tf`, `versions.tf`), the driver
under `scripts/`, three worked examples under `examples/`, this document, CI, and
the usual metadata. Small files, one concern each.

### D7 — Compose, don't wrap

**Decision.** The module uses raw `aws_launch_template` and
`aws_autoscaling_group` resources. It does not wrap
`terraform-aws-modules/terraform-aws-autoscaling` internally. For teams that
already run that module (or any ASG), `create_asg = false` makes this module
manage only the pointer; the external ASG points its own launch template's
`image_id` at our parameter via `resolve:ssm`. See
[`examples/with-external-asg`](../examples/with-external-asg).

**Alternatives considered.**

- *Wrap the community ASG module internally* and expose its features through
  passthrough variables. Rejected on two counts. First, version coupling: our
  public API would inherit the upstream module's breaking-change cadence, so a
  major bump there becomes a forced major bump here regardless of whether our own
  contract changed. Second, API bloat: usefully exposing a large upstream module
  means either a wall of passthrough variables or a leaky `dynamic`-block
  escape hatch — either way the tight v0.1 surface is gone.

**Why.** Composition keeps the coupling to a single, stable seam — the SSM
parameter name — and lets adopters keep whatever ASG tooling they already trust.
The pointer model is a pattern, not a framework; `create_asg = false` lets teams
adopt the pattern with one line and zero migration.
