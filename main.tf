locals {
  ssm_parameter_name = coalesce(var.ssm_parameter_name, "/deploy/${var.name}/ami-id")
  asg_count          = var.create_asg ? 1 : 0

  module_tags = merge(
    { Module = "terraform-aws-instance-refresh-deploy" },
    var.tags,
  )

  instance_tags = merge(local.module_tags, { Name = var.name })
}

# Release pointer. Terraform seeds it once with initial_ami_id, then hands
# ownership to the deploy driver. Every deploy writes a new AMI ID here and the
# parameter history becomes the audit log that powers `rollback --previous`.
resource "aws_ssm_parameter" "ami_pointer" {
  name        = local.ssm_parameter_name
  description = "Release pointer (AMI ID) for ASG ${var.name}. Managed by scripts/deploy.sh after creation."
  type        = "String"
  value       = var.initial_ami_id
  tier        = "Standard"

  tags = local.module_tags

  lifecycle {
    ignore_changes = [value]
  }
}

# The launch template resolves the pointer at instance launch via resolve:ssm.
# It intentionally never changes on a code deploy: moving the pointer plus an
# instance refresh is the entire deploy. Because the template does not change,
# the driver must NOT use SkipMatching (see docs/DESIGN.md, D1).
resource "aws_launch_template" "this" {
  count = local.asg_count

  name_prefix   = "${var.name}-"
  image_id      = "resolve:ssm:${aws_ssm_parameter.ami_pointer.name}"
  instance_type = var.instance_type
  key_name      = var.key_name
  user_data     = var.user_data_base64

  update_default_version = true

  vpc_security_group_ids = length(var.security_group_ids) > 0 ? var.security_group_ids : null

  dynamic "iam_instance_profile" {
    for_each = var.iam_instance_profile_name == null ? [] : [var.iam_instance_profile_name]
    content {
      name = iam_instance_profile.value
    }
  }

  dynamic "block_device_mappings" {
    for_each = var.block_device_mappings
    content {
      device_name = block_device_mappings.value.device_name
      ebs {
        volume_size           = block_device_mappings.value.ebs.volume_size
        volume_type           = block_device_mappings.value.ebs.volume_type
        iops                  = block_device_mappings.value.ebs.iops
        throughput            = block_device_mappings.value.ebs.throughput
        encrypted             = block_device_mappings.value.ebs.encrypted
        kms_key_id            = block_device_mappings.value.ebs.kms_key_id
        delete_on_termination = block_device_mappings.value.ebs.delete_on_termination
      }
    }
  }

  metadata_options {
    http_endpoint               = var.metadata_options.http_endpoint
    http_tokens                 = var.metadata_options.http_tokens
    http_put_response_hop_limit = var.metadata_options.http_put_response_hop_limit
    instance_metadata_tags      = var.metadata_options.instance_metadata_tags
  }

  tag_specifications {
    resource_type = "instance"
    tags          = local.instance_tags
  }

  tag_specifications {
    resource_type = "volume"
    tags          = local.instance_tags
  }

  tags = local.module_tags

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.instance_type != null
      error_message = "instance_type is required when create_asg = true."
    }
  }
}

resource "aws_autoscaling_group" "this" {
  count = local.asg_count

  name_prefix         = "${var.name}-"
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = coalesce(var.desired_capacity, var.min_size)
  vpc_zone_identifier = var.subnet_ids

  health_check_type         = var.health_check_type
  health_check_grace_period = var.health_check_grace_period
  target_group_arns         = var.target_group_arns

  # Deploys are driven out-of-band by scripts/deploy.sh, not by apply. Surface
  # failed scaling activities instead of silently tolerating them.
  ignore_failed_scaling_activities = false

  launch_template {
    id      = aws_launch_template.this[0].id
    version = aws_launch_template.this[0].latest_version
  }

  enabled_metrics = var.enabled_metrics

  # Optional: let Terraform-driven launch template changes (e.g. instance_type)
  # roll the fleet on apply. Off by default so code deploys stay in the driver.
  dynamic "instance_refresh" {
    for_each = var.enable_tf_driven_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences {
        min_healthy_percentage = var.tf_refresh_min_healthy_percentage
        instance_warmup        = var.health_check_grace_period
      }
    }
  }

  dynamic "tag" {
    for_each = local.instance_tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = length(var.subnet_ids) > 0
      error_message = "subnet_ids must contain at least one subnet when create_asg = true."
    }

    precondition {
      condition     = var.max_size >= var.min_size
      error_message = "max_size (${var.max_size}) must be greater than or equal to min_size (${var.min_size})."
    }

    precondition {
      condition     = var.desired_capacity == null || (var.desired_capacity >= var.min_size && var.desired_capacity <= var.max_size)
      error_message = "desired_capacity must fall within [min_size, max_size]."
    }

    precondition {
      condition     = var.health_check_type != "ELB" || length(var.target_group_arns) > 0
      error_message = "health_check_type = \"ELB\" requires at least one entry in target_group_arns."
    }
  }
}
