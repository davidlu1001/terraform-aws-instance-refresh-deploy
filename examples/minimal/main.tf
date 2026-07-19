# Smallest possible usage: a single-instance ASG behind a release pointer.
# After apply, deploy a new AMI with:
#   scripts/deploy.sh --asg <asg_name> --param <ssm_parameter_name> deploy ami-...
module "app" {
  source = "../../"

  name           = "web-minimal"
  subnet_ids     = var.subnet_ids
  initial_ami_id = var.ami_id
  instance_type  = var.instance_type
}
