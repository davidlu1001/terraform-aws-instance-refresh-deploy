# Changelog

All notable changes to this module are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.2.0] - 2026-07-21

### Added

- **`check` command** — `status` plus anomaly detection for unattended use
  (cron/CI watchdogs). Exits `6` when the fleet will not converge on the
  pointer by itself: pointer AMI not launchable (breaks every future
  scale-out), fleet-vs-pointer drift or a mixed-AMI fleet with no refresh in
  progress, a refresh that ended `Failed`/rolled back, and (with `--alarms`)
  any alarm not `OK`. `--json` carries the anomaly list. Design: D8.
- **`--max-refresh-minutes N`** (check, opt-in) — flags an in-progress
  refresh older than `N` minutes as an anomaly, since an in-progress refresh
  suppresses the drift checks and a stuck one would otherwise hide drift
  indefinitely.

### Fixed

- `status`, `check`, and the deploy preflight crashed on ASGs whose refresh
  history contains a refresh cancelled before it started (`StartTime` null
  broke the JMESPath `sort_by`); the API's documented newest-first order is
  used instead.
- `check` took two refresh-state snapshots (which could disagree mid-deploy)
  and read them before the fleet, so a deploy racing the watchdog could
  raise a false drift alarm; it now takes one snapshot, after the fleet.

## [0.1.1] - 2026-07-20

### Added

- Blue/green section in the release-pointer migration guide.

## [0.1.0] - 2026-07-19

Initial release.

### Added

- **Release-pointer deploy model.** An SSM parameter as the release pointer, a
  launch template that resolves it at launch via `resolve:ssm:`, and an ASG
  instance refresh as the convergence mechanism. The launch template never
  changes on a code deploy.
- **Managed-ASG mode** (`create_asg = true`, default): the module creates the
  SSM parameter, launch template, and Auto Scaling Group, with an encrypted gp3
  root volume and IMDSv2-required metadata options by default.
- **BYO-ASG mode** (`create_asg = false`): the module manages only the release
  pointer, so an existing or externally-managed ASG can adopt the model by
  pointing its launch template's `image_id` at the parameter — zero migration.
- **`scripts/deploy.sh` driver** (AWS CLI v2 + jq): `deploy`, `rollback`
  (`--previous` / `--to`), `status`, `history`, `current`, and `cancel`.
  Capacity-adaptive refresh defaults derived from live desired capacity;
  preflight safety gates (AMI availability, architecture, in-progress refresh,
  deploy-gate alarms); alarm-backed auto-rollback; and an `--incident` bypass
  for rollback during a live incident.
- **Optional Terraform-driven refresh** (`enable_tf_driven_refresh`) so
  infrastructure changes such as `instance_type` can roll the fleet on apply.
- Three worked examples: `minimal`, `complete` (ALB + ELB health checks +
  deploy-gate alarm), and `with-external-asg` (composition with
  `terraform-aws-modules/autoscaling`).
- `docs/DESIGN.md` documenting the pointer + convergence model and decisions
  D1–D7, and a CI workflow running fmt, validate, tflint, and shellcheck.

[0.2.0]: https://github.com/davidlu1001/terraform-aws-instance-refresh-deploy/releases/tag/v0.2.0
[0.1.1]: https://github.com/davidlu1001/terraform-aws-instance-refresh-deploy/releases/tag/v0.1.1
[0.1.0]: https://github.com/davidlu1001/terraform-aws-instance-refresh-deploy/releases/tag/v0.1.0
