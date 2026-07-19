output "ssm_parameter_name" {
  description = "Release pointer parameter name (managed by this module)."
  value       = module.pointer.ssm_parameter_name
}

output "asg_name" {
  description = "Name of the externally-managed ASG."
  value       = module.asg.autoscaling_group_name
}

output "deploy_command" {
  description = "Deploy invocation targeting the external ASG and our pointer."
  value       = "scripts/deploy.sh --asg ${module.asg.autoscaling_group_name} --param ${module.pointer.ssm_parameter_name} deploy ami-XXXXXXXXXXXXXXXXX"
}
