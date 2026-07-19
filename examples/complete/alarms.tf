# Deploy-gate / auto-rollback alarm: fires when the target group reports
# unhealthy hosts. Pass its name to the driver:
#   scripts/deploy.sh --asg <name> --param <param> \
#     --alarms "${var.name}-unhealthy-hosts" deploy ami-...
# The driver blocks the deploy if it is already firing and attaches it to the
# instance refresh so a bad release auto-rolls-back.
resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name}-unhealthy-hosts"
  alarm_description   = "Unhealthy hosts in the ${var.name} target group"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "UnHealthyHostCount"
  statistic           = "Maximum"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  period              = 60
  evaluation_periods  = 2
  treat_missing_data  = "notBreaching"

  dimensions = {
    TargetGroup  = aws_lb_target_group.this.arn_suffix
    LoadBalancer = aws_lb.this.arn_suffix
  }
}
