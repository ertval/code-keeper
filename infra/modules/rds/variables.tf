variable "environment" {
  description = "Environment name (staging or production)"
  type        = string
}

variable "database_subnet_ids" {
  description = "Subnet IDs for RDS subnet group"
  type        = list(string)
}

variable "security_group_id" {
  description = "Security group ID for RDS instances"
  type        = string
}

variable "instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GB"
  type        = number
  default     = 20
}

variable "multi_az" {
  description = "Enable Multi-AZ deployment"
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Backup retention period in days (the AWS Free plan allows at most 1)"
  type        = number
  default     = 1
}

variable "inventory_db_name" {
  description = "Name of inventory database"
  type        = string
  default     = "movies"
}

variable "inventory_db_username" {
  description = "Username for inventory database"
  type        = string
  default     = "inventory_user"
}

variable "inventory_db_password" {
  description = "Password for inventory database (injected via secret/variable)"
  type        = string
  sensitive   = true
}

variable "billing_db_name" {
  description = "Name of billing database"
  type        = string
  default     = "orders"
}

variable "billing_db_username" {
  description = "Username for billing database"
  type        = string
  default     = "billing_user"
}

variable "billing_db_password" {
  description = "Password for billing database (injected via secret/variable)"
  type        = string
  sensitive   = true
}
