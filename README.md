# terraform-aws-instance-refresh-deploy

[![CI](https://github.com/davidlu1001/terraform-aws-instance-refresh-deploy/actions/workflows/ci.yml/badge.svg)](https://github.com/davidlu1001/terraform-aws-instance-refresh-deploy/actions/workflows/ci.yml)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](./LICENSE)

Deployment for the un-containerized majority. If you run a plain EC2 Auto Scaling
Group and ship a fully-baked AMI per release, this module gives you a deploy
model built from three primitives you already trust: an **SSM parameter as the
release pointer**, a launch template that resolves it at boot
(`resolve:ssm:`), and an **ASG instance refresh** as the convergence mechanism.
No CodeDeploy agent, no Kubernetes, no second fleet duplicated for blue/green — a
deploy is "move the pointer, roll the fleet," and rollback is the same move
backwards.

## Architecture

```
                    scripts/deploy.sh
              deploy ▲              ▲ rollback / status / history
                     │              │
             put-parameter    get-parameter-history
                     │              │
                     ▼              │
        ┌──────────────────────────┴─┐
        │  SSM parameter (pointer)    │   value = ami-0new...   ← audit log
        │  /deploy/<name>/ami-id      │   history = deploy log
        └──────────────┬──────────────┘
                       │ resolve:ssm: at launch
                       ▼
        ┌─────────────────────────────┐
        │  Launch template            │   image_id = resolve:ssm:<param>
        │  (never changes on deploy)  │   IMDSv2, gp3 root, tags
        └──────────────┬──────────────┘
                       │
                       ▼
        ┌─────────────────────────────┐     start-instance-refresh
        │  Auto Scaling Group         │◀───  (Rolling, SkipMatching=false,
        │  capacity-adaptive refresh  │       capacity-adaptive prefs)
        └─────────────────────────────┘
```

## Quickstart

```hcl
module "app" {
  source  = "davidlu1001/instance-refresh-deploy/aws"
  version = "~> 0.1"

  name           = "web"
  subnet_ids     = ["subnet-aaa", "subnet-bbb"]
  initial_ami_id = "ami-0123456789abcdef0"
  instance_type  = "m6i.large"
}
```

```sh
# Ship a new release (baked into ami-0newrelease...):
scripts/deploy.sh \
  --asg   "$(terraform output -raw asg_name)" \
  --param "$(terraform output -raw ssm_parameter_name)" \
  deploy ami-0newrelease00000000

# Something's wrong — go back to the previous release:
scripts/deploy.sh --asg <asg> --param <param> rollback --previous
```

Baking the AMI (Packer, EC2 Image Builder, or your CI) is deliberately out of
scope. This module owns the pointer and the fleet; you own the image.

## How it works

The launch template's `image_id` is `resolve:ssm:<parameter-name>`, so instances
resolve the current AMI at launch. Terraform seeds the parameter once and then
ignores its value — the driver owns it from then on. A deploy writes the new AMI
ID and starts an instance refresh; new instances come up on the new AMI, old
ones drain away. The launch template itself never changes.

Read [`docs/DESIGN.md`](./docs/DESIGN.md) for the state-space argument and the
full rationale behind each decision (D1–D7).

## Capacity-adaptive refresh defaults

The driver reads the ASG's live desired capacity and sizes the refresh to fit.
Every value is overridable per invocation.

| Desired capacity | MinHealthy % | MaxHealthy % | Checkpoints | Rationale |
|------------------|-------------|-------------|-------------|-----------|
| ≤ 1              | 100         | 200         | none        | Launch-before-terminate; nothing to hold back. |
| 2–3              | 100         | 150         | 50, 100     | Keep the fleet up while a canary batch proves out. |
| ≥ 4              | 90          | 150         | 50, 100     | Allow one instance down to bound the surge. |

Override with `--min-healthy`, `--max-healthy`, `--checkpoints "50,100"`,
`--checkpoint-delay`, and `--warmup`. Instance warmup defaults to the ASG's
health check grace period.

## Adopting with an existing ASG — zero migration

Already running your own ASG, or the community
[`terraform-aws-modules/autoscaling`](https://registry.terraform.io/modules/terraform-aws-modules/autoscaling/aws)
module? Set `create_asg = false` so this module manages only the release
pointer, and point your launch template at it with one line:

```hcl
module "pointer" {
  source         = "davidlu1001/instance-refresh-deploy/aws"
  version        = "~> 0.1"
  name           = "web"
  initial_ami_id = "ami-0123456789abcdef0"
  create_asg     = false
}

# in your existing launch template:
image_id = "resolve:ssm:${module.pointer.ssm_parameter_name}"
```

Then drive deploys against your ASG's name exactly as above. See
[`examples/with-external-asg`](./examples/with-external-asg).

Coming from dual-ASG blue/green with ALB weighted target groups? There is a
step-by-step migration path — including what you get to delete at the end —
in [docs/MIGRATING-FROM-BLUE-GREEN.md](./docs/MIGRATING-FROM-BLUE-GREEN.md).

## FAQ

**Why not CodeDeploy?** CodeDeploy adds an on-host agent, an `appspec.yml`
lifecycle, and a deployment-group abstraction, and its in-place ASG story still
leans on instance refresh under the hood. For baked-AMI releases the refresh *is*
the deploy; the agent and appspec are moving parts with no payoff here.

**Why not blue/green with two ASGs?** A second fleet doubles the live state —
two ASGs, two target-group attachments, a traffic shifter, and a matrix of
which-color-is-live states to keep consistent. The pointer model keeps one ASG
and spends that complexity budget on nothing. See the state-space argument in
`docs/DESIGN.md`.

**Why not build on `terraform-aws-modules/autoscaling`?** Composition over
wrapping (D7). Wrapping it would couple this module's public API to that module's
breaking-change cadence and force either passthrough-variable bloat or a leaky
escape hatch. Instead, `create_asg = false` lets you compose the two along a
single stable seam — the SSM parameter — and keep whatever ASG tooling you
already run. See [`examples/with-external-asg`](./examples/with-external-asg).

**What about config-at-boot?** The AMI should be fully baked; keep `user_data`
minimal and idempotent (fetch secrets, register with discovery). If a config
change needs to reach running instances without a new AMI, that's a separate
mechanism (SSM, a config service) — this module ships images, not config.

**A warning on SkipMatching.** Do not enable instance refresh's SkipMatching
optimization with this model. The launch template version never changes on a
deploy, so SkipMatching would consider every instance already up-to-date and skip
the whole roll-out. The driver sets `SkipMatching=false` and you should never
override that.

**What happens on scale-out mid-release?** Any instance launched after the
pointer moves — from a scaling policy, or an ASG health replacement — comes up on
the *new* AMI, because it resolves the current pointer. A fresh instance is a
fresh release. The flip side: a *failed* deploy leaves the pointer advanced, so
until you roll back, new instances serve the failed release. `deploy.sh status`
shows the drift between the pointer and what instances actually run.

**Migrations?** The pointer moves *code*, not *schema*. It has no idea your
release needs a new column. Backward/forward-compatible schema changes
(expand/contract) are on you — during a refresh both the old and new AMI serve
traffic simultaneously, so every release must tolerate the schema of the one
before and after it.

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.5 |
| aws | >= 5.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| name | Name prefix for all resources. Lowercase letters, digits, hyphens only. | `string` | n/a | yes |
| initial_ami_id | AMI ID written to the SSM pointer at creation; driver-owned thereafter. | `string` | n/a | yes |
| subnet_ids | Subnet IDs the ASG launches into. Required when `create_asg` is true. | `list(string)` | `[]` | when managed |
| instance_type | EC2 instance type. Required when `create_asg` is true. | `string` | `null` | when managed |
| create_asg | Manage the launch template and ASG. Set false for BYO-ASG (pointer only). | `bool` | `true` | no |
| ssm_parameter_name | Release pointer name. Defaults to `/deploy/<name>/ami-id`. | `string` | `null` | no |
| security_group_ids | Security group IDs attached to instances. | `list(string)` | `[]` | no |
| iam_instance_profile_name | Existing IAM instance profile name to attach. | `string` | `null` | no |
| key_name | EC2 key pair name. Prefer SSM Session Manager and leave null. | `string` | `null` | no |
| user_data_base64 | Base64-encoded user data for minimal boot-time config. | `string` | `null` | no |
| min_size | Minimum ASG size. | `number` | `1` | no |
| max_size | Maximum ASG size. Must cover the refresh surge. | `number` | `2` | no |
| desired_capacity | Desired capacity. Defaults to `min_size` when null. | `number` | `null` | no |
| target_group_arns | Target group ARNs to register instances with. | `list(string)` | `[]` | no |
| health_check_type | `EC2` or `ELB`. Use `ELB` when target groups are attached. | `string` | `"EC2"` | no |
| health_check_grace_period | Health check grace period (s); also default warmup. | `number` | `300` | no |
| enable_tf_driven_refresh | Add an `instance_refresh` block so TF-driven LT changes roll the fleet. | `bool` | `false` | no |
| tf_refresh_min_healthy_percentage | MinHealthy % for the TF-driven refresh block. | `number` | `90` | no |
| block_device_mappings | Block device mappings. Defaults to an encrypted gp3 root volume. | `list(object)` | gp3 root | no |
| metadata_options | Instance metadata options. Defaults enforce IMDSv2. | `object` | IMDSv2 | no |
| enabled_metrics | ASG group metrics to enable. | `list(string)` | `[]` | no |
| tags | Tags applied to all resources and propagated to instances. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| asg_name | ASG name (null when `create_asg = false`). Pass to the driver as `--asg`. |
| asg_arn | ASG ARN (null when `create_asg = false`). |
| launch_template_id | Launch template ID (null when `create_asg = false`). |
| ssm_parameter_name | Release pointer name. Pass to the driver as `--param`. |
| ssm_parameter_arn | Release pointer ARN. Grant the deploy role SSM write/history here. |
| deploy_command | Ready-to-run example driver invocation for this pointer. |
<!-- END_TF_DOCS -->

## The deploy driver

`scripts/deploy.sh` is a self-contained Bash driver (AWS CLI v2 + jq).

| Command | What it does |
|---------|--------------|
| `deploy <ami-id>` | Preflight, confirm, move the pointer, roll the fleet, wait for success. |
| `rollback [--previous \| --to <ami>]` | Roll back to the previous distinct pointer value (or a specific AMI). |
| `status` | In-flight refresh, current pointer, and the AMIs instances actually run — surfaces drift. |
| `history [-n N]` | The pointer history rendered as a deploy log. |
| `current` | Print the pointer value only (script-friendly). |
| `cancel` | Cancel an in-progress instance refresh. |
| `check` | `status` plus anomaly detection; exits `6` on drift (cron/CI watchdog contract). |

Notable flags: `--yes` (skip confirmation), `--incident` (skip the alarm gate
during a live incident), `--alarms "n1,n2"` (deploy gate + auto-rollback),
`--no-wait`, `--json`. Run `scripts/deploy.sh --help` for the full list and the
documented exit codes.

### Unattended drift detection

`check` evaluates the conditions under which the fleet will not converge on
the pointer by itself — a deregistered pointer AMI (breaks every future
scale-out), instances running an AMI other than the pointer with no refresh
in progress, a mixed-AMI fleet, a refresh that ended `Failed`/rolled back,
and (with `--alarms`) any alarm not in `OK`. Wire it to a schedule and alert
on the exit code:

```bash
# cron / CI schedule: exit 6 means anomalies; the JSON already carries them,
# so one invocation drives both the alert condition and the alert body.
if ! out="$(scripts/deploy.sh --asg my-asg --param /my/pointer \
    --region us-east-1 --json check)"; then
  notify "drift detected: $(jq -c .anomalies <<<"$out")"
fi
```

A check that lands in the few seconds between a deploy's pointer write and
its refresh starting will flag drift once; if that matters for your paging
policy, alert on two consecutive failures.

An in-progress refresh suppresses the drift checks (convergence is underway),
which means a refresh that never finishes would hide drift indefinitely. Pass
`--max-refresh-minutes N` to opt in to stuck-refresh detection: an in-progress
refresh older than `N` minutes becomes an anomaly. Size `N` from your fleet —
roughly `instances × (warmup + checkpoint delays)` plus slack.

If the bad deploy's refresh is still running when you need to roll back, cancel
it first — preflight refuses to start a refresh while one is in progress:

```console
deploy.sh --asg my-app --param /deploy/my-app/ami-id cancel --yes
deploy.sh --asg my-app --param /deploy/my-app/ami-id rollback --incident --yes
```

## Blog series

This module accompanies a series on ten years of deployment evolution — how a
team that never adopted containers or blue/green still ships safely, and why the
pointer-and-convergence model earns its keep. Placeholder links, to be filled in
as the posts land:

- Part 1 — Why the un-containerized majority still exists — <https://davidlu1001.me>
- Part 2 — Pointer + convergence: a deploy in three moves — <https://davidlu1001.me>
- Part 3 — Rolling back during an incident, and the alarm paradox — <https://davidlu1001.me>

## License

[Apache 2.0](./LICENSE) © 2026 David Lu.
