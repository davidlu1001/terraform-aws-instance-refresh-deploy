variable "name" {
  description = "Name prefix for all resources (SSM parameter, launch template, ASG). Lowercase letters, digits, and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.name))
    error_message = "name must contain only lowercase letters, digits, and hyphens ([a-z0-9-])."
  }
}

variable "subnet_ids" {
  description = "Subnet IDs the ASG launches instances into. Must span the availability zones you want to run in. Required when create_asg is true; ignored otherwise."
  type        = list(string)
  default     = []
}

variable "initial_ami_id" {
  description = "AMI ID written to the SSM release pointer at creation time. After apply, the pointer is owned by the deploy driver; Terraform ignores changes to its value."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]+$", var.initial_ami_id))
    error_message = "initial_ami_id must be a valid AMI ID (ami-...)."
  }
}

variable "instance_type" {
  description = "EC2 instance type for the launch template (e.g. m6i.large). Required when create_asg is true; ignored otherwise."
  type        = string
  default     = null

  validation {
    condition     = var.instance_type == null || can(regex("^[a-z0-9]+\\.[a-z0-9]+$", coalesce(var.instance_type, "x.x")))
    error_message = "instance_type must be a valid instance type such as 'm6i.large'."
  }
}

variable "create_asg" {
  description = "When true (default), the module manages the launch template and ASG. When false, only the SSM release pointer is created for BYO-ASG adoption: point an existing launch template's image_id at the pointer via resolve:ssm and drive deploys with scripts/deploy.sh --asg <your-asg>."
  type        = bool
  default     = true
}

variable "ssm_parameter_name" {
  description = "Name of the SSM parameter used as the release pointer. Defaults to /deploy/<name>/ami-id when null."
  type        = string
  default     = null

  validation {
    condition     = var.ssm_parameter_name == null || can(regex("^/[a-zA-Z0-9_.\\-/]+$", coalesce(var.ssm_parameter_name, "/x")))
    error_message = "ssm_parameter_name must be a valid SSM parameter path beginning with '/'."
  }
}

variable "security_group_ids" {
  description = "Security group IDs attached to launched instances. The module does not create security groups."
  type        = list(string)
  default     = []
}

variable "iam_instance_profile_name" {
  description = "Name of an existing IAM instance profile to attach. The module does not create IAM resources."
  type        = string
  default     = null
}

variable "key_name" {
  description = "EC2 key pair name for SSH access. Prefer SSM Session Manager and leave this null in most cases."
  type        = string
  default     = null
}

variable "user_data_base64" {
  description = "Base64-encoded user data for boot-time configuration. The AMI should already be fully baked; keep boot work minimal and idempotent."
  type        = string
  default     = null
}

variable "min_size" {
  description = "Minimum ASG size."
  type        = number
  default     = 1

  validation {
    condition     = var.min_size >= 0
    error_message = "min_size must be zero or greater."
  }
}

variable "max_size" {
  description = "Maximum ASG size. Must be at least min_size and large enough for the refresh surge (MaxHealthyPercentage above 100)."
  type        = number
  default     = 2

  validation {
    condition     = var.max_size >= 1
    error_message = "max_size must be at least 1."
  }
}

variable "desired_capacity" {
  description = "Desired ASG capacity. Defaults to min_size when null. The deploy driver reads live desired capacity to pick refresh parameters, so keep this honest."
  type        = number
  default     = null
}

variable "target_group_arns" {
  description = "Target group ARNs to register instances with. Attaching target groups implies health_check_type should be ELB."
  type        = list(string)
  default     = []
}

variable "health_check_type" {
  description = "ASG health check type: EC2 or ELB. Use ELB when target groups are attached so unhealthy-in-the-load-balancer instances are replaced."
  type        = string
  default     = "EC2"

  validation {
    condition     = contains(["EC2", "ELB"], var.health_check_type)
    error_message = "health_check_type must be either 'EC2' or 'ELB'."
  }
}

variable "health_check_grace_period" {
  description = "Seconds the ASG waits before checking instance health after launch. Also the default instance warmup for refreshes."
  type        = number
  default     = 300

  validation {
    condition     = var.health_check_grace_period >= 0
    error_message = "health_check_grace_period must be zero or greater."
  }
}

variable "enable_tf_driven_refresh" {
  description = "When true, add an instance_refresh block to the ASG so Terraform-driven launch template changes (e.g. instance_type) trigger a rolling refresh on apply. Leave false to keep code deploys entirely in the driver's hands (the default model)."
  type        = bool
  default     = false
}

variable "tf_refresh_min_healthy_percentage" {
  description = "MinHealthyPercentage for the Terraform-driven instance_refresh block. Only used when enable_tf_driven_refresh is true."
  type        = number
  default     = 90

  validation {
    condition     = var.tf_refresh_min_healthy_percentage >= 0 && var.tf_refresh_min_healthy_percentage <= 100
    error_message = "tf_refresh_min_healthy_percentage must be between 0 and 100."
  }
}

variable "block_device_mappings" {
  description = "Block device mappings for the launch template. Defaults to a single encrypted gp3 root volume."
  type = list(object({
    device_name = string
    ebs = object({
      volume_size           = optional(number, 20)
      volume_type           = optional(string, "gp3")
      iops                  = optional(number)
      throughput            = optional(number)
      encrypted             = optional(bool, true)
      kms_key_id            = optional(string)
      delete_on_termination = optional(bool, true)
    })
  }))
  default = [
    {
      device_name = "/dev/xvda"
      ebs = {
        volume_size = 20
        volume_type = "gp3"
        encrypted   = true
      }
    }
  ]
}

variable "metadata_options" {
  description = "Instance metadata options. Defaults enforce IMDSv2 (http_tokens = required)."
  type = object({
    http_endpoint               = optional(string, "enabled")
    http_tokens                 = optional(string, "required")
    http_put_response_hop_limit = optional(number, 1)
    instance_metadata_tags      = optional(string, "disabled")
  })
  default = {}

  validation {
    condition     = contains(["required", "optional"], coalesce(var.metadata_options.http_tokens, "required"))
    error_message = "metadata_options.http_tokens must be 'required' (IMDSv2) or 'optional'."
  }
}

variable "enabled_metrics" {
  description = "ASG group metrics to enable (e.g. GroupInServiceInstances, GroupPendingInstances). Empty disables group metrics collection."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags applied to all resources and propagated to ASG instances."
  type        = map(string)
  default     = {}
}
