terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Amazon MQ offers only RabbitMQ 3.13, 4.2 and 4.3 for new brokers (3.11 is gone),
# and only as major.minor with auto_minor_version_upgrade on. The apps use one
# durable queue and a per-consumer prefetch, which RabbitMQ 4 still supports.
resource "aws_mq_broker" "rabbitmq" {
  broker_name                = "code-keeper-${var.environment}-rabbitmq"
  engine_type                = "RabbitMQ"
  engine_version             = "4.2"
  host_instance_type         = var.host_instance_type
  deployment_mode            = var.deployment_mode
  publicly_accessible        = false
  auto_minor_version_upgrade = true

  logs {
    general = true
  }
  subnet_ids      = var.deployment_mode == "CLUSTER_MULTI_AZ" ? var.subnet_ids : [var.subnet_ids[0]]
  security_groups = [var.security_group_id]

  user {
    username = var.admin_username
    password = var.admin_password
  }

  tags = {
    Name        = "code-keeper-${var.environment}-rabbitmq"
    Environment = var.environment
  }
}
