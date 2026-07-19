variable "region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "subnet_ids" {
  description = "Subnet IDs for the ASG."
  type        = list(string)
}

variable "ami_id" {
  description = "Initial baked AMI ID to seed the release pointer with."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type."
  type        = string
  default     = "t3.micro"
}
