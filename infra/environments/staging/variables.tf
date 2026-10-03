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
  description = "Inventory DB password. Set via TF_VAR_inventory_db_password / CI masked var TF_VAR_inventory_db_password."
  type        = string
  sensitive   = true
}

variable "billing_db_password" {
  description = "Billing DB password. Set via TF_VAR_billing_db_password / CI masked var TF_VAR_billing_db_password."
  type        = string
  sensitive   = true
}

variable "rabbitmq_username" {
  description = "RabbitMQ username presented by the gateway and the billing consumer. Must match the broker's admin_username."
  type        = string
  default     = "rabbit_user"
}

variable "rabbitmq_password" {
  description = "RabbitMQ admin password. Set via TF_VAR_rabbitmq_password / CI masked var TF_VAR_rabbitmq_password."
  type        = string
  sensitive   = true
}

variable "api_gateway_image" {
  description = "Full image reference for the API Gateway task; when null it is derived from image_repository_prefix and release_tag."
  type        = string
  default     = null
  nullable    = true
}

variable "inventory_app_image" {
  description = "Full image reference for the Inventory App task; when null it is derived from image_repository_prefix and release_tag."
  type        = string
  default     = null
  nullable    = true
}

variable "billing_app_image" {
  description = "Full image reference for the Billing App task; when null it is derived from image_repository_prefix and release_tag."
  type        = string
  default     = null
  nullable    = true
}

variable "image_repository_prefix" {
  description = <<-EOT
    Registry namespace holding the service images, without a trailing slash.
    No default on purpose: the CI pipelines push to $${CI_REGISTRY_IMAGE}/<service>
    and export TF_VAR_image_repository_prefix=$${CI_REGISTRY_IMAGE}, so a value
    is always supplied on the path that matters. The previous default,
    "code-keeper", was a bare name that resolved to a Docker Hub *user* which
    does not exist -- a manual `terraform apply` silently produced task
    definitions pointing at images that were never pushed, and the first
    revision is seeded once and then guarded by
    `lifecycle { ignore_changes = [task_definition] }`, so nothing ever
    corrected it afterwards.
  EOT
  type        = string

  validation {
    # One or more path segments, so this accepts both registry.example.com/ns
    # and registry.example.com/group/subgroup/project -- which is what GitLab's
    # CI_REGISTRY_IMAGE actually is for a group project. A single segment with
    # no slash (the old "code-keeper" default, a nonexistent Docker Hub user)
    # is rejected.
    condition     = can(regex("^[^\\s/]+(?:/[^\\s/]+)+$", var.image_repository_prefix))
    error_message = "image_repository_prefix must be <registry-host>/<path...> (e.g. registry.example.com/group/project). It must contain at least one slash: a bare name is ambiguous and previously resolved to a nonexistent Docker Hub user."
  }
}

variable "release_tag" {
  description = "Tag of the service images. Terraform only seeds the first task definition revision; the CD pipeline promotes the immutable commit SHA and owns the running revision, so this value is overridden with TF_VAR_release_tag when the pipeline applies."
  type        = string
  default     = "staging-latest"
}

