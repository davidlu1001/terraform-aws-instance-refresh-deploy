# Composition, not wrapping (DESIGN.md, D7). This module owns only the release
# pointer (create_asg = false); an external ASG module owns the fleet and points
# its launch template's image_id at our pointer via resolve:ssm. Deploys still
# run through scripts/deploy.sh against the external ASG's name.
module "pointer" {
  source = "../../"

  name           = var.name
  initial_ami_id = var.ami_id
  create_asg     = false
}

module "asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 8.0"

  name = var.name

  min_size         = 2
  max_size         = 4
  desired_capacity = 2

  vpc_zone_identifier = var.subnet_ids

  # The single line that adopts the pointer model: resolve the AMI at launch.
  image_id      = "resolve:ssm:${module.pointer.ssm_parameter_name}"
  instance_type = var.instance_type

  # This example keeps IAM/security groups out of scope for brevity.
  create_iam_instance_profile = false
  security_groups             = []

  tags = {
    Environment = "example"
  }
}
