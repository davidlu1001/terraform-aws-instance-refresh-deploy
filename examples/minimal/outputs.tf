output "asg_name" {
  description = "Name of the created ASG."
  value       = module.app.asg_name
}

output "ssm_parameter_name" {
  description = "Release pointer parameter name."
  value       = module.app.ssm_parameter_name
}

output "deploy_command" {
  description = "Example deploy invocation for this ASG."
  value       = module.app.deploy_command
}
