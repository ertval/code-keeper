variable "environment" {
  description = "Environment name (staging or production)"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs for RabbitMQ broker"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for RabbitMQ broker"
  type        = string
}

variable "host_instance_type" {
  description = "Instance type for RabbitMQ broker"
  type        = string
  default     = "mq.t3.micro"
}

variable "deployment_mode" {
  description = "Deployment mode: SINGLE_INSTANCE or CLUSTER_MULTI_AZ"
  type        = string
  default     = "SINGLE_INSTANCE"
}

variable "admin_username" {
  description = "RabbitMQ administrative username"
  type        = string
  default     = "rabbit_user"
}

variable "admin_password" {
  description = "RabbitMQ administrative password (injected via CI/CD secret)"
  type        = string
  sensitive   = true
}
