variable "environment" {
  description = "Environment name (staging or production)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnet IDs for ALB"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for microservices"
  type        = list(string)
}

variable "alb_security_group_id" {
  description = "Security group ID for ALB"
  type        = string
}

variable "api_gateway_security_group_id" {
  description = "Security group ID for API Gateway"
  type        = string
}

variable "inventory_app_security_group_id" {
  description = "Security group ID for Inventory App"
  type        = string
}

variable "billing_app_security_group_id" {
  description = "Security group ID for Billing App"
  type        = string
}

variable "api_gateway_image" {
  description = "Docker image for API Gateway"
  type        = string
  default     = "code-keeper/api-gateway:latest"
}

variable "inventory_app_image" {
  description = "Docker image for Inventory App"
  type        = string
  default     = "code-keeper/inventory-app:latest"
}

variable "billing_app_image" {
  description = "Docker image for Billing App"
  type        = string
  default     = "code-keeper/billing-app:latest"
}

variable "gateway_replicas" {
  description = "Desired number of API Gateway tasks"
  type        = number
  default     = 2
}

variable "inventory_replicas" {
  description = "Desired number of Inventory App tasks"
  type        = number
  default     = 2
}

variable "billing_replicas" {
  description = "Desired number of Billing App tasks"
  type        = number
  default     = 2
}

variable "cpu" {
  description = "CPU units per task"
  type        = string
  default     = "256"
}

variable "memory" {
  description = "Memory in MB per task"
  type        = string
  default     = "512"
}

variable "inventory_db_host" {
  description = "Inventory database host"
  type        = string
}

variable "billing_db_host" {
  description = "Billing database host"
  type        = string
}

variable "inventory_db_username" {
  description = "Username the inventory app must present to PostgreSQL."
  type        = string
}

variable "inventory_db_password" {
  description = "Password for INVENTORY_DB_USER. Never defaulted; must come from a sensitive TF_VAR."
  type        = string
  sensitive   = true
}

variable "inventory_db_name" {
  description = "Inventory database name."
  type        = string
  default     = "movies"
}

variable "billing_db_username" {
  description = "Username the billing app must present to PostgreSQL."
  type        = string
}

variable "billing_db_password" {
  description = "Password for BILLING_DB_USER. Never defaulted; must come from a sensitive TF_VAR."
  type        = string
  sensitive   = true
}

variable "billing_db_name" {
  description = "Billing database name."
  type        = string
  default     = "orders"
}

variable "rabbitmq_username" {
  description = "RabbitMQ username the gateway and billing consumer authenticate with."
  type        = string
}

variable "rabbitmq_password" {
  description = "Password for RABBITMQ_USER. Never defaulted; must come from a sensitive TF_VAR."
  type        = string
  sensitive   = true
}

variable "rabbitmq_port" {
  description = "Broker port. 5671 for AWS MQ (AMQPS), 5672 for plaintext."
  type        = number
  default     = 5671
}

variable "rabbitmq_host" {
  description = "RabbitMQ broker host"
  type        = string
}
