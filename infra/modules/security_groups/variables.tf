variable "environment" {
  description = "Environment name (staging or production)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where security groups will be created"
  type        = string
}
