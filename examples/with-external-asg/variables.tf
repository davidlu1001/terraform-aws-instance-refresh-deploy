variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for the pointer and the external ASG."
  type        = string
  default     = "web-byo"
}

variable "ami_id" {
  description = "Initial baked AMI ID to seed the release pointer with."
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for the externally-managed ASG."
  type        = list(string)
}

variable "instance_type" {
  description = "EC2 instance type for the externally-managed ASG."
  type        = string
  default     = "t3.small"
}
