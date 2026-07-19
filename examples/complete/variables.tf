variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Name prefix for all resources."
  type        = string
  default     = "web-complete"
}

variable "ami_id" {
  description = "Initial baked AMI ID to seed the release pointer with."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.small"
}

variable "vpc_id" {
  description = "VPC ID for the ALB and instances. Defaults to the account's default VPC when null."
  type        = string
  default     = null
}
