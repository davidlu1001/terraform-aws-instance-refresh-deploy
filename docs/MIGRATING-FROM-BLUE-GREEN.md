# Migrating from blue/green to the release-pointer model

This guide is for teams running dual-ASG blue/green on plain EC2 — two Auto
Scaling Groups per tier, ALB weighted target groups, and a driver script that
flips listener weights. If that is you, you can adopt this module incrementally,
one environment at a time, without a big-bang cutover.

The short version: you are not migrating a deployment tool. You are deleting
state. Blue/green's reachable states (which color is live, which target group
holds weight, is the idle color really empty, did a partial flip leave split
routing) are each a configuration your automation must recognize and correctly
leave. The pointer model replaces all of it with one parameter and one
convergence primitive.

## Prerequisites

Before any of this, two things must already be true — they are prerequisites,
not migration steps:

1. **Immutable artifact.** Instances boot from an AMI that already contains the
   release (or reach ready state from boot-time automation you trust). If your
   deploy still assembles the release on the instance at boot, fix that first;
   instance refresh will happily roll your fleet onto half-configured boxes.
2. **Application-level health checks.** Your ALB health check must fail until
   the application is genuinely ready to serve — not "nginx is up". Instance
   refresh trusts your health checks the same way your weight-flip script does;
   if a check can pass before the app is ready, both models break, but refresh
   breaks with less human supervision watching.

## Migration path

### Step 1 — collapse to one ASG per tier

Pick the color currently serving, keep its ASG, and retire the idle color's
ASG and its target group weights. Point the listener at the surviving target
group at 100%. Nothing about your deploy changes yet — you are removing the
standby machinery, not the deploy process.

This step is reversible and independently valuable: half your ASGs, half the
scaling policies, half the state.

### Step 2 — adopt the pointer (BYO-ASG mode)

Instantiate this module with `create_asg = false` so it manages only the SSM
release pointer, and change one line in your existing launch template:

```hcl
module "pointer" {
  source         = "davidlu1001/instance-refresh-deploy/aws"
  name           = "my-app"
  initial_ami_id = var.current_ami_id # what the fleet runs today
  create_asg     = false
}

# in your existing launch template:
image_id = "resolve:ssm:${module.pointer.ssm_parameter_name}"
```

Your ASG, scaling policies, target groups, and Terraform state stay where they
are. No instance is replaced by this step; new instances simply start resolving
the pointer.

### Step 3 — first refresh deploy, in your lowest environment

Run a deploy through the driver instead of your weight-flip script:

```console
scripts/deploy.sh --asg my-app-test --param /deploy/my-app/ami-id \
  --alarms "my-app-5xx,my-app-latency" deploy ami-0abc...
```

Watch the batch behavior, the health gating, and the timing. Then — before you
touch stage or prod — run a rollback drill:

```console
scripts/deploy.sh --asg my-app-test --param /deploy/my-app/ami-id rollback --previous
```

A rollback you have not drilled is a hope, not a capability. This is also where
you will notice the operational differences from blue/green, so read the honest
tradeoffs below *before* this step, not after.

### Step 4 — promote environment by environment

Repeat steps 1–3 for stage, soak, then prod. Keep your blue/green driver
script in the repo, unused, until prod has been through at least one real
deploy and one drill on the new path. Then delete it. (Deleting it matters:
as long as the old path exists, an incident at 2am will tempt someone onto
the code path nobody has exercised in months.)

## Honest tradeoffs

- **The warm standby fleet is gone.** Blue/green's instant flip to a warm idle
  color is real — if you actually keep the idle color warm and actually drill
  the flip. Refresh-based rollback means relaunching instances (minutes, not
  seconds). If your org genuinely staffs and drills warm-standby flips, weigh
  this honestly.
- **Mixed-version windows exist during a refresh.** Batches mean old and new
  code serve simultaneously for minutes. Blue/green has the same window during
  a weight ramp, but if you were doing all-at-once flips, this is new; your
  releases must be forward/backward compatible across one version (they should
  have been already — expand/contract migrations).
- **Deploys get slower, rollbacks get simpler.** A refresh takes as long as a
  batch-by-batch fleet replacement takes. What you get back is that rollback no
  longer needs your CI system, your driver script's failure paths, or a human
  reasoning about which color is safe at 2am.

## What you get to delete

At the end of the migration, per environment: one ASG per tier (instead of
two), the listener weight rules, the color-decision logic, the "is the idle
side really empty" checks, the partial-flip recovery paths, and the driver
script that held it all together. Every deleted state is a class of incident
that is no longer expressible.
