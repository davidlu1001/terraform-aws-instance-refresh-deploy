output "asg_name" {
  description = "Name of the Auto Scaling Group, or null when create_asg = false. Pass to the driver as --asg."
  value       = one(aws_autoscaling_group.this[*].name)
}

output "asg_arn" {
  description = "ARN of the Auto Scaling Group, or null when create_asg = false."
  value       = one(aws_autoscaling_group.this[*].arn)
}

output "launch_template_id" {
  description = "ID of the launch template, or null when create_asg = false. It resolves the AMI pointer via resolve:ssm and does not change on deploy."
  value       = one(aws_launch_template.this[*].id)
}

output "ssm_parameter_name" {
  description = "Name of the SSM release pointer. Pass to the driver as --param, and reference it from a BYO launch template as resolve:ssm:<name>."
  value       = aws_ssm_parameter.ami_pointer.name
}

output "ssm_parameter_arn" {
  description = "ARN of the SSM release pointer. Grant the deploy role ssm:PutParameter and ssm:GetParameterHistory on this."
  value       = aws_ssm_parameter.ami_pointer.arn
}

output "deploy_command" {
  description = "Ready-to-run example invocation of the deploy driver for this pointer."
  value       = "scripts/deploy.sh --asg ${coalesce(one(aws_autoscaling_group.this[*].name), "<your-asg-name>")} --param ${aws_ssm_parameter.ami_pointer.name} deploy ami-XXXXXXXXXXXXXXXXX"
}
