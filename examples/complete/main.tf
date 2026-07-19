# Complete example: an ALB-fronted ASG with ELB health checks, a deploy-gate
# alarm, and instance metrics enabled. Deploys are driven out-of-band by
# scripts/deploy.sh; terraform apply only manages the fleet's shape.
module "app" {
  source = "../../"

  name           = var.name
  subnet_ids     = data.aws_subnets.selected.ids
  initial_ami_id = var.ami_id
  instance_type  = var.instance_type

  security_group_ids = [aws_security_group.instances.id]

  target_group_arns         = [aws_lb_target_group.this.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 180

  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  enabled_metrics = [
    "GroupInServiceInstances",
    "GroupDesiredCapacity",
    "GroupPendingInstances",
    "GroupTerminatingInstances",
  ]

  tags = {
    Environment = "example"
    Team        = "platform"
  }
}
