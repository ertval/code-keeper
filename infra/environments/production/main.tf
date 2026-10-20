terraform {
  required_version = ">= 1.5.0"

  # Partial backend configuration: the S3 parameters live in backend.hcl and are
  # supplied with -backend-config, so no state location or credential is committed.
  backend "s3" {}

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "code-keeper"
      Environment = var.environment
      ManagedBy   = "Terraform"
    }
  }
}

locals {
  # Derived so the CD pipeline stays the source of truth for the running revision:
  # it promotes the immutable commit SHA tag and drives release_tag from the
  # pipeline. An explicit *_image variable always takes precedence.
  api_gateway_image   = coalesce(var.api_gateway_image, "${var.image_repository_prefix}/api-gateway:${var.release_tag}")
  inventory_app_image = coalesce(var.inventory_app_image, "${var.image_repository_prefix}/inventory-app:${var.release_tag}")
  billing_app_image   = coalesce(var.billing_app_image, "${var.image_repository_prefix}/billing-app:${var.release_tag}")
}

module "vpc" {
  source                = "../../modules/vpc"
  environment           = var.environment
  cidr_block            = var.cidr_block
  availability_zones    = var.availability_zones
  public_subnet_cidrs   = var.public_subnet_cidrs
  private_subnet_cidrs  = var.private_subnet_cidrs
  database_subnet_cidrs = var.database_subnet_cidrs
}

module "security_groups" {
  source      = "../../modules/security_groups"
  environment = var.environment
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.cidr_block
}

# Production is sized like staging so both environments fit the AWS Free plan
# credits. The high-availability sizes were: RDS db.t3.small with 50 GB, Multi-AZ
# and 30-day backups; Amazon MQ mq.m5.large as CLUSTER_MULTI_AZ (on RabbitMQ 4.2
# that needs an mq.m7g type); 4 replicas per service with 512 CPU units and 1024 MB.
module "rds" {
  source                  = "../../modules/rds"
  environment             = var.environment
  database_subnet_ids     = module.vpc.database_subnet_ids
  security_group_id       = module.security_groups.database_security_group_id
  instance_class          = "db.t3.micro"
  allocated_storage       = 20
  multi_az                = false
  backup_retention_period = 7
  inventory_db_password   = var.inventory_db_password
  billing_db_password     = var.billing_db_password
}

module "rabbitmq" {
  source             = "../../modules/rabbitmq"
  environment        = var.environment
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_id  = module.security_groups.rabbitmq_security_group_id
  host_instance_type = "mq.m7g.medium"
  deployment_mode    = "SINGLE_INSTANCE"
  admin_password     = var.rabbitmq_password
}

module "compute" {
  source                          = "../../modules/compute"
  environment                     = var.environment
  vpc_id                          = module.vpc.vpc_id
  public_subnet_ids               = module.vpc.public_subnet_ids
  private_subnet_ids              = module.vpc.private_subnet_ids
  alb_security_group_id           = module.security_groups.alb_security_group_id
  api_gateway_security_group_id   = module.security_groups.api_gateway_security_group_id
  inventory_app_security_group_id = module.security_groups.inventory_app_security_group_id
  billing_app_security_group_id   = module.security_groups.billing_app_security_group_id
  api_gateway_image               = local.api_gateway_image
  inventory_app_image             = local.inventory_app_image
  billing_app_image               = local.billing_app_image
  gateway_replicas                = 2
  inventory_replicas              = 2
  billing_replicas                = 2
  inventory_db_host               = module.rds.inventory_db_address
  inventory_db_username           = module.rds.inventory_db_username
  inventory_db_password           = var.inventory_db_password
  inventory_db_name               = module.rds.inventory_db_name
  billing_db_host                 = module.rds.billing_db_address
  billing_db_username             = module.rds.billing_db_username
  billing_db_password             = var.billing_db_password
  billing_db_name                 = module.rds.billing_db_name
  # The broker's real hostname. It used to be the Terraform resource *name*,
  # which is not resolvable in DNS, so no client could ever connect.
  rabbitmq_host      = module.rabbitmq.broker_host
  rabbitmq_port      = module.rabbitmq.broker_port
  rabbitmq_username  = var.rabbitmq_username
  rabbitmq_password  = var.rabbitmq_password
  dockerhub_username = var.dockerhub_username
  dockerhub_token    = var.dockerhub_token
}
