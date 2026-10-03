terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Every security group declares explicit ingress AND egress. Without an egress
# block AWS attaches a default allow-all egress rule, which turns a compromised
# task into an unrestricted pivot, so outbound traffic is enumerated per port.
# Ingress is restricted by security group reference; egress is restricted by
# port plus the VPC CIDR. Referencing a peer security group from egress while
# that peer references this one from ingress would build a dependency cycle.
locals {
  # AmazonProvidedDNS resolver address of the VPC (network address + 2).
  vpc_resolver = cidrhost(var.vpc_cidr, 2)

  # Instance metadata service, required by the RabbitMQ broker nodes.
  imds_address = "169.254.169.254/32"

  gateway_port       = 3000
  app_port           = 8080
  amqp_port          = 5672
  rabbitmq_mgmt_port = 15672
  postgres_port      = 5432
  https_port         = 443
}

# ALB Public Security Group
resource "aws_security_group" "alb" {
  name        = "code-keeper-${var.environment}-alb-sg"
  description = "Public ALB security group allowing inbound HTTP/HTTPS traffic"
  vpc_id      = var.vpc_id

  ingress {
    description = "Allow inbound HTTP from internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Allow inbound HTTPS from internet"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow target traffic to API Gateway inside the VPC"
    from_port   = local.gateway_port
    to_port     = local.gateway_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-alb-sg"
    Environment = var.environment
  }
}

# API Gateway Security Group (Restricted to ALB traffic)
resource "aws_security_group" "api_gateway" {
  name        = "code-keeper-${var.environment}-api-gateway-sg"
  description = "Security group for API Gateway microservice"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow port 3000 from ALB only"
    from_port       = local.gateway_port
    to_port         = local.gateway_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow container image pulls and log delivery through NAT"
    from_port   = local.https_port
    to_port     = local.https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow inventory app calls on port 8080 inside the VPC"
    from_port   = local.app_port
    to_port     = local.app_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow AMQP publishing to RabbitMQ on port 5672 inside the VPC"
    from_port   = local.amqp_port
    to_port     = local.amqp_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow PostgreSQL access on port 5432 inside the VPC"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-api-gateway-sg"
    Environment = var.environment
  }
}

# Inventory App Security Group (Restricted to API Gateway)
resource "aws_security_group" "inventory_app" {
  name        = "code-keeper-${var.environment}-inventory-app-sg"
  description = "Security group for Inventory microservice"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow port 8080 from API Gateway only"
    from_port       = local.app_port
    to_port         = local.app_port
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow container image pulls and log delivery through NAT"
    from_port   = local.https_port
    to_port     = local.https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow PostgreSQL access on port 5432 inside the VPC"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-inventory-app-sg"
    Environment = var.environment
  }
}

# Billing App Security Group (Worker microservice)
# No ingress rule on purpose: the worker consumes the queue and is never
# reachable from another network entity.
resource "aws_security_group" "billing_app" {
  name        = "code-keeper-${var.environment}-billing-app-sg"
  description = "Security group for Billing worker microservice"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow container image pulls and log delivery through NAT"
    from_port   = local.https_port
    to_port     = local.https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow PostgreSQL access on port 5432 inside the VPC"
    from_port   = local.postgres_port
    to_port     = local.postgres_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow AMQP consumption from RabbitMQ on port 5672 inside the VPC"
    from_port   = local.amqp_port
    to_port     = local.amqp_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-billing-app-sg"
    Environment = var.environment
  }
}

# RabbitMQ Security Group
resource "aws_security_group" "rabbitmq" {
  name        = "code-keeper-${var.environment}-rabbitmq-sg"
  description = "Security group for RabbitMQ broker"
  vpc_id      = var.vpc_id

  ingress {
    description     = "AMQP port 5672 from API Gateway and Billing App"
    from_port       = local.amqp_port
    to_port         = local.amqp_port
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id, aws_security_group.billing_app.id]
  }

  ingress {
    description     = "Management UI port 15672 from API Gateway and Billing App"
    from_port       = local.rabbitmq_mgmt_port
    to_port         = local.rabbitmq_mgmt_port
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id, aws_security_group.billing_app.id]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow CloudWatch Logs delivery"
    from_port   = local.https_port
    to_port     = local.https_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Allow instance metadata access from broker nodes"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [local.imds_address]
  }

  egress {
    description = "Allow broker node replication inside the cluster"
    from_port   = local.amqp_port
    to_port     = local.amqp_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow management access between broker nodes"
    from_port   = local.rabbitmq_mgmt_port
    to_port     = local.rabbitmq_mgmt_port
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-rabbitmq-sg"
    Environment = var.environment
  }
}

# PostgreSQL Database Security Group
# PostgreSQL only answers inbound queries, so its egress is limited to DNS.
resource "aws_security_group" "database" {
  name        = "code-keeper-${var.environment}-database-sg"
  description = "Security group for Inventory and Billing RDS PostgreSQL databases"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL port 5432 from Inventory and Billing services"
    from_port       = local.postgres_port
    to_port         = local.postgres_port
    protocol        = "tcp"
    security_groups = [aws_security_group.inventory_app.id, aws_security_group.billing_app.id]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [local.vpc_resolver]
  }

  egress {
    description = "Allow DNS resolution via VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [local.vpc_resolver]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-database-sg"
    Environment = var.environment
  }
}