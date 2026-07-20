#!/usr/bin/env bash
#
# deploy.sh — release-pointer deploy driver for terraform-aws-instance-refresh-deploy.
#
# The deploy model is "pointer + convergence": a fully-baked AMI per release, an
# SSM parameter as the release pointer, and an ASG instance refresh as the
# convergence mechanism. A deploy writes the new AMI ID to the pointer and starts
# an instance refresh; new instances resolve the pointer at launch (resolve:ssm).
# The launch template never changes, so this driver never uses SkipMatching.
#
# Usage:
#   deploy.sh --asg NAME --param NAME [--region R] [global flags] <command> [args]
#
# Commands:
#   deploy <ami-id>            Move the pointer to <ami-id> and roll the fleet.
#   rollback [--previous]      Roll back to the previous distinct pointer value.
#   rollback --to <ami-id>     Roll back to a specific AMI.
#   status                     Show in-flight refresh, pointer value, and the AMIs
#                              running instances actually use (pointer/reality drift).
#   history [-n N]             Show the pointer history as a deploy log.
#   current                    Print the current pointer value only (script-friendly).
#   cancel                     Cancel an in-progress instance refresh.
#   check                      Status plus anomaly detection for unattended use
#                              (cron/CI watchdogs): exits 6 when the fleet will
#                              not converge on the pointer by itself.
#
# Global flags:
#   --yes                      Skip the confirmation prompt.
#   --incident                 Skip the pre-deploy alarm gate; disable auto-rollback.
#                              Use only when rolling back during a live incident.
#   --alarms "n1,n2"           Deploy-gate alarms; also attached to the refresh with
#                              auto-rollback so it reverts if an alarm fires mid-roll.
#                              With check: alarms that must be OK, else an anomaly.
#   --auto-rollback            Force auto-rollback on (requires --alarms).
#   --min-healthy N            Override MinHealthyPercentage.
#   --max-healthy N            Override MaxHealthyPercentage.
#   --checkpoints "50,100"     Override checkpoint percentages.
#   --checkpoint-delay S       Override checkpoint delay (seconds).
#   --warmup S                 Override instance warmup (default: ASG grace period).
#   --no-wait                  Return after starting the refresh; do not poll.
#   --json                     Machine-readable output for status/current/history.
#   --max-refresh-minutes N    check: treat an in-progress refresh older than N
#                              minutes as an anomaly (off by default).
#
# Exit codes:
#   0  success
#   1  runtime error (failed aws CLI calls pass through their own exit codes)
#   2  usage error
#   3  missing dependency (aws, jq, or bash < 4)
#   4  preflight gate failed
#   5  instance refresh finished in a non-successful state
#   6  check: anomalies found
#
set -euo pipefail

# --- constants ---------------------------------------------------------------
readonly DEFAULT_CHECKPOINT_DELAY=300
readonly POLL_INTERVAL=15
readonly EXIT_USAGE=2
readonly EXIT_DEP=3
readonly EXIT_PREFLIGHT=4
readonly EXIT_REFRESH=5
readonly EXIT_CHECK=6

# --- global state (set by argument parsing) ----------------------------------
ASG_NAME=""
PARAM_NAME=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
COMMAND=""
POSITIONAL=()

OPT_YES=false
OPT_INCIDENT=false
OPT_ALARMS=""
OPT_AUTO_ROLLBACK=false
OPT_MIN_HEALTHY=""
OPT_MAX_HEALTHY=""
OPT_CHECKPOINTS=""
OPT_CHECKPOINT_DELAY=""
OPT_WARMUP=""
OPT_NO_WAIT=false
OPT_JSON=false
OPT_MAX_REFRESH_MIN=""
OPT_ROLLBACK_TO=""
OPT_HISTORY_N=10

# --- logging helpers ---------------------------------------------------------
log()  { printf '%s\n' "$*" >&2; }
info() { printf '\033[1;34m::\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }

die() {
  local code="$1"
  shift
  printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2
  exit "$code"
}

# Echo a mutating AWS call, then run it. Every state change is visible.
run() {
  printf '\033[1;32m+\033[0m %s\n' "$*" >&2
  "$@"
}

# --- AWS wrapper (always region-scoped) --------------------------------------
aws_cli() {
  aws --region "$REGION" --output json "$@"
}

# --- preconditions -----------------------------------------------------------
check_dependencies() {
  if ((BASH_VERSINFO[0] < 4)); then
    die "$EXIT_DEP" "bash >= 4 is required (found ${BASH_VERSION})."
  fi
  command -v aws >/dev/null 2>&1 || die "$EXIT_DEP" "aws CLI (v2) not found on PATH."
  command -v jq >/dev/null 2>&1 || die "$EXIT_DEP" "jq not found on PATH."
}

require_context() {
  [[ -n "$ASG_NAME" ]] || die "$EXIT_USAGE" "--asg is required."
  [[ -n "$PARAM_NAME" ]] || die "$EXIT_USAGE" "--param is required."
  [[ -n "$REGION" ]] || die "$EXIT_USAGE" \
    "no region set; pass --region or export AWS_REGION."
}

# --- SSM pointer operations --------------------------------------------------
pointer_current() {
  aws_cli ssm get-parameter --name "$PARAM_NAME" \
    --query 'Parameter.Value' --output text
}

pointer_history_json() {
  # Newest first, so [0] is the current value.
  aws_cli ssm get-parameter-history --name "$PARAM_NAME" --with-decryption \
    --query 'reverse(sort_by(Parameters, &Version))'
}

pointer_previous() {
  # First value in history that differs from the current one.
  pointer_history_json | jq -r '
    (.[0].Value) as $cur
    | map(select(.Value != $cur))
    | if length == 0 then "" else .[0].Value end'
}

pointer_write() {
  local ami="$1"
  run aws_cli ssm put-parameter --name "$PARAM_NAME" --type String \
    --value "$ami" --overwrite >/dev/null
}

# --- ASG / refresh helpers ---------------------------------------------------
asg_describe() {
  aws_cli autoscaling describe-auto-scaling-groups \
    --auto-scaling-group-names "$ASG_NAME" \
    --query 'AutoScalingGroups[0]'
}

asg_desired_capacity() {
  asg_describe | jq -r '.DesiredCapacity'
}

asg_grace_period() {
  asg_describe | jq -r '.HealthCheckGracePeriod // 300'
}

# Most recent instance refresh object, or empty when none exist.
refresh_latest_json() {
  # The API returns refreshes newest-first (documented); do NOT re-sort on
  # StartTime — a refresh cancelled before it started has StartTime null,
  # which crashes JMESPath sort_by.
  aws_cli autoscaling describe-instance-refreshes \
    --auto-scaling-group-name "$ASG_NAME" \
    --max-records 1 \
    --query 'InstanceRefreshes[0]'
}

refresh_in_progress() {
  # Accepts a pre-fetched refresh JSON to avoid a second API call (and a
  # second, possibly different, snapshot) when the caller already has one.
  local json="${1:-$(refresh_latest_json)}"
  printf '%s' "$json" | jq -r '
    if . == null then "false"
    elif (.Status | IN("Pending","InProgress","Cancelling","RollbackInProgress","Baking"))
    then "true" else "false" end'
}

image_architecture() {
  aws_cli ec2 describe-images --image-ids "$1" \
    --query 'Images[0].Architecture' --output text 2>/dev/null || echo "None"
}

# --- confirmation ------------------------------------------------------------
confirm() {
  local action="$1" from="$2" to="$3"
  info "${action}: ${from} -> ${to}  (ASG ${ASG_NAME}, region ${REGION})"
  if [[ "$OPT_YES" == true ]]; then
    return 0
  fi
  local reply
  read -r -p "Proceed with ${action}? [y/N] " reply
  [[ "$reply" =~ ^[Yy]$ ]] || die "$EXIT_USAGE" "Aborted by operator."
}

# --- preflight gate ----------------------------------------------------------
preflight() {
  local target="$1"
  info "Preflight checks"

  local state
  state="$(aws_cli ec2 describe-images --image-ids "$target" \
    --query 'Images[0].State' --output text 2>/dev/null || echo "missing")"
  if [[ "$state" != "available" ]]; then
    die "$EXIT_PREFLIGHT" "AMI ${target} is not available (state: ${state})."
  fi

  # Best-effort architecture check: the new AMI should match what is running now.
  local current target_arch current_arch
  current="$(pointer_current)"
  target_arch="$(image_architecture "$target")"
  current_arch="$(image_architecture "$current")"
  if [[ "$target_arch" != "None" && "$current_arch" != "None" \
        && "$target_arch" != "$current_arch" ]]; then
    die "$EXIT_PREFLIGHT" \
      "architecture mismatch: ${target} is ${target_arch}, current ${current} is ${current_arch}."
  fi

  if [[ "$(refresh_in_progress)" == "true" ]]; then
    die "$EXIT_PREFLIGHT" \
      "an instance refresh is already in progress; wait or run 'cancel' first."
  fi

  alarm_gate
}

# Emit one "name<TAB>state" line per --alarms entry not in OK state.
# Shared by the deploy-time alarm gate and check's alarm evaluation.
alarms_not_ok() {
  local names name alarm_state
  IFS=',' read -r -a names <<<"$OPT_ALARMS"
  for name in "${names[@]}"; do
    [[ -n "$name" ]] || continue
    alarm_state="$(aws_cli cloudwatch describe-alarms --alarm-names "$name" \
      --query 'MetricAlarms[0].StateValue' --output text 2>/dev/null || echo "MISSING")"
    [[ "$alarm_state" == "OK" ]] || printf '%s\t%s\n' "$name" "$alarm_state"
  done
}

alarm_gate() {
  [[ -n "$OPT_ALARMS" ]] || return 0
  if [[ "$OPT_INCIDENT" == true ]]; then
    warn "incident mode: skipping pre-deploy alarm gate for [${OPT_ALARMS}]."
    return 0
  fi

  local name alarm_state bad=()
  while IFS=$'\t' read -r name alarm_state; do
    bad+=("${name}=${alarm_state}")
  done < <(alarms_not_ok)
  if ((${#bad[@]} > 0)); then
    die "$EXIT_PREFLIGHT" \
      "deploy-gate alarms not OK: ${bad[*]}. Fix, or pass --incident to override."
  fi
  info "Deploy-gate alarms OK: ${OPT_ALARMS}"
}

# --- capacity-adaptive refresh preferences -----------------------------------
# Populates MIN_HEALTHY MAX_HEALTHY CHECKPOINTS_JSON CHECKPOINT_DELAY WARMUP
# from live desired capacity (D4), then applies any operator overrides.
resolve_preferences() {
  local desired="$1"
  local min max checkpoints delay

  if ((desired <= 1)); then
    min=100
    max=200
    checkpoints="[]"
    delay=0
  elif ((desired <= 3)); then
    min=100
    max=150
    checkpoints="[50,100]"
    delay="$DEFAULT_CHECKPOINT_DELAY"
  else
    min=90
    max=150
    checkpoints="[50,100]"
    delay="$DEFAULT_CHECKPOINT_DELAY"
  fi

  [[ -n "$OPT_MIN_HEALTHY" ]] && min="$OPT_MIN_HEALTHY"
  [[ -n "$OPT_MAX_HEALTHY" ]] && max="$OPT_MAX_HEALTHY"
  [[ -n "$OPT_CHECKPOINT_DELAY" ]] && delay="$OPT_CHECKPOINT_DELAY"
  if [[ -n "$OPT_CHECKPOINTS" ]]; then
    checkpoints="$(jq -cn --arg c "$OPT_CHECKPOINTS" \
      '$c | split(",") | map(select(length > 0) | tonumber)')"
  fi

  MIN_HEALTHY="$min"
  MAX_HEALTHY="$max"
  CHECKPOINTS_JSON="$checkpoints"
  CHECKPOINT_DELAY="$delay"

  if [[ -n "$OPT_WARMUP" ]]; then
    WARMUP="$OPT_WARMUP"
  else
    WARMUP="$(asg_grace_period)"
  fi
}

build_preferences() {
  local alarms_json auto_rollback

  if [[ -n "$OPT_ALARMS" ]]; then
    alarms_json="$(jq -cn --arg a "$OPT_ALARMS" \
      '$a | split(",") | map(select(length > 0))')"
  else
    alarms_json="[]"
  fi

  # Auto-rollback needs alarms to roll back against; never in incident mode.
  auto_rollback=false
  if [[ "$OPT_INCIDENT" != true ]]; then
    if [[ "$alarms_json" != "[]" ]]; then
      auto_rollback=true
    elif [[ "$OPT_AUTO_ROLLBACK" == true ]]; then
      warn "--auto-rollback ignored: it requires --alarms."
    fi
  fi

  jq -cn \
    --argjson min "$MIN_HEALTHY" \
    --argjson max "$MAX_HEALTHY" \
    --argjson warmup "$WARMUP" \
    --argjson checkpoints "$CHECKPOINTS_JSON" \
    --argjson delay "$CHECKPOINT_DELAY" \
    --argjson alarms "$alarms_json" \
    --argjson autoroll "$auto_rollback" \
    '{
       MinHealthyPercentage: $min,
       MaxHealthyPercentage: $max,
       InstanceWarmup: $warmup,
       SkipMatching: false,
       AutoRollback: $autoroll
     }
     + (if ($checkpoints | length) > 0
        then { CheckpointPercentages: $checkpoints, CheckpointDelay: $delay }
        else {} end)
     + (if ($alarms | length) > 0
        then { AlarmSpecification: { Alarms: $alarms } }
        else {} end)'
}

start_refresh() {
  local desired preferences refresh_id
  desired="$(asg_desired_capacity)"
  resolve_preferences "$desired"
  preferences="$(build_preferences)"

  info "Desired capacity ${desired} -> Min ${MIN_HEALTHY} / Max ${MAX_HEALTHY} / warmup ${WARMUP}s"
  refresh_id="$(run aws_cli autoscaling start-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" \
    --strategy Rolling \
    --preferences "$preferences" \
    --query 'InstanceRefreshId' --output text)"
  info "Started instance refresh ${refresh_id}"

  if [[ "$OPT_NO_WAIT" == true ]]; then
    log "--no-wait set; not polling. Track with: deploy.sh ... status"
    printf '%s\n' "$refresh_id"
    return 0
  fi
  wait_for_refresh "$refresh_id"
}

wait_for_refresh() {
  local refresh_id="$1" status pct row
  info "Waiting for refresh ${refresh_id} (poll ${POLL_INTERVAL}s)"
  while true; do
    row="$(aws_cli autoscaling describe-instance-refreshes \
      --auto-scaling-group-name "$ASG_NAME" \
      --instance-refresh-ids "$refresh_id" \
      --query 'InstanceRefreshes[0].[Status,PercentageComplete]' --output text)"
    status="$(printf '%s' "$row" | awk '{print $1}')"
    pct="$(printf '%s' "$row" | awk '{print $2}')"
    [[ "$pct" == "None" || -z "$pct" ]] && pct=0
    printf '\033[1;34m::\033[0m %-20s %3s%%\n' "$status" "$pct" >&2

    case "$status" in
      Successful)
        info "Refresh completed successfully."
        return 0
        ;;
      Failed | Cancelled | RollbackFailed)
        die "$EXIT_REFRESH" "refresh ${refresh_id} ended in state: ${status}."
        ;;
      RollbackSuccessful)
        die "$EXIT_REFRESH" \
          "refresh ${refresh_id} was auto-rolled-back (alarm fired mid-roll)."
        ;;
    esac
    sleep "$POLL_INTERVAL"
  done
}

# --- commands ----------------------------------------------------------------
cmd_deploy() {
  local target="${POSITIONAL[0]:-}"
  [[ -n "$target" ]] || die "$EXIT_USAGE" "deploy requires an AMI ID."
  [[ "$target" =~ ^ami-[0-9a-f]+$ ]] || die "$EXIT_USAGE" "invalid AMI ID: ${target}"

  preflight "$target"
  confirm "deploy" "$(pointer_current)" "$target"
  pointer_write "$target"
  start_refresh
}

cmd_rollback() {
  local target
  if [[ -n "$OPT_ROLLBACK_TO" ]]; then
    target="$OPT_ROLLBACK_TO"
    [[ "$target" =~ ^ami-[0-9a-f]+$ ]] || die "$EXIT_USAGE" "invalid AMI ID: ${target}"
  else
    target="$(pointer_previous)"
    [[ -n "$target" ]] || die "$EXIT_USAGE" \
      "no previous distinct pointer value in history; pass --to <ami-id>."
  fi

  if [[ "$OPT_INCIDENT" == true ]]; then
    warn "INCIDENT ROLLBACK: alarm gate skipped, auto-rollback disabled."
  fi
  preflight "$target"
  confirm "rollback" "$(pointer_current)" "$target"
  pointer_write "$target"
  start_refresh
}

# Map running instances to the AMI they actually booted from.
fleet_images_json() {
  local instances
  instances="$(asg_describe \
    | jq -r '[.Instances[].InstanceId] | join(" ")')"
  if [[ -z "$instances" ]]; then
    printf '[]'
    return 0
  fi
  # shellcheck disable=SC2086
  aws_cli ec2 describe-instances --instance-ids $instances \
    --query 'Reservations[].Instances[].[InstanceId,ImageId]' \
    | jq '[.[] | {InstanceId: .[0], ImageId: .[1]}]'
}

cmd_status() {
  local pointer refresh running_json
  pointer="$(pointer_current)"
  refresh="$(refresh_latest_json)"
  running_json="$(fleet_images_json)"

  if [[ "$OPT_JSON" == true ]]; then
    jq -n \
      --arg pointer "$pointer" \
      --argjson refresh "${refresh:-null}" \
      --argjson instances "$running_json" \
      '{pointer: $pointer, refresh: $refresh, instances: $instances}'
    return 0
  fi

  printf 'Pointer (%s): %s\n' "$PARAM_NAME" "$pointer"
  local rstatus
  rstatus="$(printf '%s' "$refresh" | jq -r '
    if . == null then "none"
    else "\(.Status) \(.PercentageComplete // 0)%  (id \(.InstanceRefreshId))" end')"
  printf 'Latest refresh: %s\n' "$rstatus"
  printf 'Running instances vs pointer:\n'
  printf '%s' "$running_json" | jq -r --arg p "$pointer" '
    if length == 0 then "  (no running instances)"
    else group_by(.ImageId)[]
      | "  \(.[0].ImageId)  x\(length)" + (if .[0].ImageId == $p then "  <- pointer" else "  (drift)" end)
    end'
}

# check — status plus anomaly evaluation, built for unattended use (a cron
# entry or CI schedule pointing at this exit code is a drift watchdog).
# An anomaly is any condition under which the fleet will not, or can not,
# converge on the pointer by itself. Drift checks are suppressed while a
# refresh is in progress: convergence is literally underway.
cmd_check() {
  local pointer refresh fleet in_progress rstatus
  local anomalies=()
  if [[ -n "$OPT_MAX_REFRESH_MIN" && ! "$OPT_MAX_REFRESH_MIN" =~ ^[0-9]+$ ]]; then
    die "$EXIT_USAGE" "--max-refresh-minutes expects a whole number of minutes."
  fi
  pointer="$(pointer_current)"
  fleet="$(fleet_images_json)"
  # Refresh state is fetched AFTER the fleet on purpose: a deploy racing this
  # check has its refresh visible by now, which suppresses the drift checks
  # below instead of raising a false alarm on the not-yet-converged fleet.
  refresh="$(refresh_latest_json)"
  in_progress="$(refresh_in_progress "$refresh")"
  rstatus="$(printf '%s' "$refresh" | jq -r '
    if . == null then "none" else .Status end')"

  # Scale-outs resolve the pointer at launch: a deregistered or otherwise
  # non-launchable pointer AMI silently breaks every future scale-out.
  local ami_state
  ami_state="$(aws_cli ec2 describe-images --image-ids "$pointer" \
    --query 'Images[0].State' --output text 2>/dev/null || echo "missing")"
  if [[ "$ami_state" != "available" ]]; then
    anomalies+=("pointer AMI ${pointer} is not launchable (state: ${ami_state}); scale-outs will fail")
  fi

  if [[ "$in_progress" != "true" ]]; then
    local distinct drifted
    distinct="$(printf '%s' "$fleet" | jq '[.[].ImageId] | unique | length')"
    drifted="$(printf '%s' "$fleet" | jq --arg p "$pointer" \
      '[.[] | select(.ImageId != $p)] | length')"
    if ((distinct > 1)); then
      anomalies+=("fleet runs ${distinct} different AMIs with no refresh in progress")
    fi
    if ((drifted > 0)); then
      anomalies+=("${drifted} instance(s) run an AMI other than the pointer with no refresh in progress")
    fi
  fi

  # Opt-in stuck-refresh detection. An in-progress refresh suppresses the
  # drift checks above, so a refresh that never finishes (instances that
  # never pass health checks can hold one open for a very long time) would
  # hide drift indefinitely while check keeps reporting OK.
  if [[ "$in_progress" == "true" && -n "$OPT_MAX_REFRESH_MIN" ]]; then
    local age_min
    # -1 when StartTime is null (Pending) or unparseable: age unknown, skip.
    age_min="$(printf '%s' "$refresh" | jq -r '
      if .StartTime == null then -1
      else (try (((now - (.StartTime
                          | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z")
                          | fromdateiso8601)) / 60) | floor) catch -1)
      end')"
    if ((age_min > OPT_MAX_REFRESH_MIN)); then
      local refresh_id
      refresh_id="$(printf '%s' "$refresh" | jq -r '.InstanceRefreshId')"
      anomalies+=("refresh ${refresh_id} in progress for ${age_min}m, over --max-refresh-minutes ${OPT_MAX_REFRESH_MIN}; it may be stuck")
    fi
  fi

  # Cancelled is a deliberate operator action; any residue it left behind is
  # already caught by the drift checks above.
  case "$rstatus" in
    Failed | RollbackFailed | RollbackSuccessful)
      anomalies+=("latest refresh ended ${rstatus}; the fleet may not match the pointer")
      ;;
  esac

  if [[ -n "$OPT_ALARMS" ]]; then
    local name alarm_state
    while IFS=$'\t' read -r name alarm_state; do
      anomalies+=("alarm ${name} is ${alarm_state}")
    done < <(alarms_not_ok)
  fi

  if [[ "$OPT_JSON" == true ]]; then
    local anomalies_json
    anomalies_json="$(printf '%s\n' "${anomalies[@]:-}" \
      | jq -R . | jq -s 'map(select(length > 0))')"
    jq -n \
      --arg pointer "$pointer" \
      --argjson refresh "${refresh:-null}" \
      --argjson instances "$fleet" \
      --argjson anomalies "$anomalies_json" \
      '{pointer: $pointer, refresh: $refresh, instances: $instances,
        anomalies: $anomalies, ok: ($anomalies | length == 0)}'
  else
    printf 'Pointer (%s): %s\n' "$PARAM_NAME" "$pointer"
    printf 'Latest refresh: %s\n' "$(printf '%s' "$refresh" | jq -r '
      if . == null then "none"
      else "\(.Status) \(.PercentageComplete // 0)%" end')"
    if ((${#anomalies[@]} == 0)); then
      info "check: OK (no anomalies)"
    else
      local a
      for a in "${anomalies[@]}"; do
        warn "check: ${a}"
      done
    fi
  fi
  ((${#anomalies[@]} == 0)) || exit "$EXIT_CHECK"
}

cmd_history() {
  local hist
  hist="$(pointer_history_json)"
  if [[ "$OPT_JSON" == true ]]; then
    printf '%s' "$hist" | jq --argjson n "$OPT_HISTORY_N" '.[:$n]'
    return 0
  fi
  printf '%-8s %-24s %s\n' "VERSION" "DATE" "AMI"
  printf '%s' "$hist" | jq -r --argjson n "$OPT_HISTORY_N" '
    .[:$n][] | "\(.Version)\t\(.LastModifiedDate)\t\(.Value)"' \
    | while IFS=$'\t' read -r version date value; do
        printf '%-8s %-24s %s\n' "$version" "${date%%.*}" "$value"
      done
}

cmd_current() {
  local pointer
  pointer="$(pointer_current)"
  if [[ "$OPT_JSON" == true ]]; then
    jq -n --arg v "$pointer" '{pointer: $v}'
  else
    printf '%s\n' "$pointer"
  fi
}

cmd_cancel() {
  if [[ "$(refresh_in_progress)" != "true" ]]; then
    die 1 "no instance refresh is currently in progress."
  fi
  confirm "cancel-refresh" "$ASG_NAME" "cancelled"
  run aws_cli autoscaling cancel-instance-refresh \
    --auto-scaling-group-name "$ASG_NAME" >/dev/null
  info "Cancellation requested."
}

# --- argument parsing --------------------------------------------------------
parse_args() {
  while (($# > 0)); do
    case "$1" in
      --asg) ASG_NAME="$2"; shift 2 ;;
      --param) PARAM_NAME="$2"; shift 2 ;;
      --region) REGION="$2"; shift 2 ;;
      --yes | -y) OPT_YES=true; shift ;;
      --incident) OPT_INCIDENT=true; shift ;;
      --alarms) OPT_ALARMS="$2"; shift 2 ;;
      --auto-rollback) OPT_AUTO_ROLLBACK=true; shift ;;
      --min-healthy) OPT_MIN_HEALTHY="$2"; shift 2 ;;
      --max-healthy) OPT_MAX_HEALTHY="$2"; shift 2 ;;
      --checkpoints) OPT_CHECKPOINTS="$2"; shift 2 ;;
      --checkpoint-delay) OPT_CHECKPOINT_DELAY="$2"; shift 2 ;;
      --warmup) OPT_WARMUP="$2"; shift 2 ;;
      --no-wait) OPT_NO_WAIT=true; shift ;;
      --json) OPT_JSON=true; shift ;;
      --max-refresh-minutes) OPT_MAX_REFRESH_MIN="$2"; shift 2 ;;
      --to) OPT_ROLLBACK_TO="$2"; shift 2 ;;
      --previous) shift ;;
      -n) OPT_HISTORY_N="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      --) shift; POSITIONAL+=("$@"); break ;;
      -*) die "$EXIT_USAGE" "unknown flag: $1" ;;
      *)
        if [[ -z "$COMMAND" ]]; then
          COMMAND="$1"
        else
          POSITIONAL+=("$1")
        fi
        shift
        ;;
    esac
  done
}

usage() {
  # Print the header comment block (from line 3 to the first non-comment
  # line) so the help text never drifts from a hardcoded line range.
  awk 'NR < 3 { next } !/^#/ { exit } { sub(/^# ?/, ""); print }' "$0"
}

main() {
  check_dependencies
  parse_args "$@"

  [[ -n "$COMMAND" ]] || { usage; die "$EXIT_USAGE" "no command given."; }
  require_context

  case "$COMMAND" in
    deploy) cmd_deploy ;;
    rollback) cmd_rollback ;;
    status) cmd_status ;;
    history) cmd_history ;;
    current) cmd_current ;;
    cancel) cmd_cancel ;;
    check) cmd_check ;;
    *) die "$EXIT_USAGE" "unknown command: ${COMMAND}" ;;
  esac
}

main "$@"
