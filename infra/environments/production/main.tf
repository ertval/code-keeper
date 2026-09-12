terraform {
  required_version = ">= 1.5.0"
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
}

module "rds" {
  source                  = "../../modules/rds"
  environment             = var.environment
  database_subnet_ids     = module.vpc.database_subnet_ids
  security_group_id       = module.security_groups.database_security_group_id
  instance_class          = "db.t3.small"
  allocated_storage       = 50
  multi_az                = true
  backup_retention_period = 30
  inventory_db_password   = var.inventory_db_password
  billing_db_password     = var.billing_db_password
}

module "rabbitmq" {
  source             = "../../modules/rabbitmq"
  environment        = var.environment
  subnet_ids         = module.vpc.private_subnet_ids
  security_group_id  = module.security_groups.rabbitmq_security_group_id
  host_instance_type = "mq.m5.large"
  deployment_mode    = "CLUSTER_MULTI_AZ"
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
  api_gateway_image               = var.api_gateway_image
  inventory_app_image             = var.inventory_app_image
  billing_app_image               = var.billing_app_image
  gateway_replicas                = 4
  inventory_replicas              = 4
  billing_replicas                = 4
  cpu                             = "512"
  memory                          = "1024"
  inventory_db_host               = module.rds.inventory_db_address
  billing_db_host                 = module.rds.billing_db_address
  rabbitmq_host                   = "code-keeper-${var.environment}-rabbitmq"
}
