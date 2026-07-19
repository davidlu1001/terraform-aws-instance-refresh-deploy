output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "asg_name" {
  description = "Name of the created ASG."
  value       = module.app.asg_name
}

output "ssm_parameter_name" {
  description = "Release pointer parameter name."
  value       = module.app.ssm_parameter_name
}

output "deploy_gate_alarm" {
  description = "Alarm name to pass to the driver via --alarms."
  value       = aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name
}

output "deploy_command" {
  description = "Example deploy invocation, alarm-gated with auto-rollback."
  value       = "scripts/deploy.sh --asg ${module.app.asg_name} --param ${module.app.ssm_parameter_name} --alarms ${aws_cloudwatch_metric_alarm.unhealthy_hosts.alarm_name} deploy ami-XXXXXXXXXXXXXXXXX"
}
