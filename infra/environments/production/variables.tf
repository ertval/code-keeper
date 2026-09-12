variable "aws_region" {
  description = "AWS deployment region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "production"
}

variable "cidr_block" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.20.0.0/16"
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.10.0/24", "10.20.11.0/24"]
}

variable "database_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.20.0/24", "10.20.21.0/24"]
}

variable "availability_zones" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "inventory_db_password" {
  description = "Inventory DB Password"
  type        = string
  sensitive   = true
  default     = "ProdSecurePassDB2026!"
}

variable "billing_db_password" {
  description = "Billing DB Password"
  type        = string
  sensitive   = true
  default     = "ProdSecurePassDB2026!"
}

variable "rabbitmq_password" {
  description = "RabbitMQ Admin Password"
  type        = string
  sensitive   = true
  default     = "ProdSecurePassMQ2026!"
}

variable "api_gateway_image" {
  type    = string
  default = "code-keeper/api-gateway:production-latest"
}

variable "inventory_app_image" {
  type    = string
  default = "code-keeper/inventory-app:production-latest"
}

variable "billing_app_image" {
  type    = string
  default = "code-keeper/billing-app:production-latest"
}
