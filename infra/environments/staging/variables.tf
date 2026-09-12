variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "staging"
}

variable "cidr_block" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.10.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.1.0/24", "10.10.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.10.0/24", "10.10.11.0/24"]
}

variable "database_subnet_cidrs" {
  type    = list(string)
  default = ["10.10.20.0/24", "10.10.21.0/24"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "inventory_db_password" {
  description = "Inventory DB Password"
  type        = string
  sensitive   = true
  default     = "StagingDBPass2026!"
}

variable "billing_db_password" {
  description = "Billing DB Password"
  type        = string
  sensitive   = true
  default     = "StagingDBPass2026!"
}

variable "rabbitmq_password" {
  description = "RabbitMQ Admin Password"
  type        = string
  sensitive   = true
  default     = "StagingRabbitPass2026!"
}

variable "api_gateway_image" {
  type    = string
  default = "code-keeper/api-gateway:staging-latest"
}

variable "inventory_app_image" {
  type    = string
  default = "code-keeper/inventory-app:staging-latest"
}

variable "billing_app_image" {
  type    = string
  default = "code-keeper/billing-app:staging-latest"
}
