variable "environment" {
  description = "Environment name (staging or production)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where security groups will be created"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC, used to scope egress to the AmazonProvidedDNS resolver"
  type        = string
}
