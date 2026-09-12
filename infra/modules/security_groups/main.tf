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
    description = "Allow all egress to VPC resources"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Allow all outbound within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id]
  }

  egress {
    description = "Allow outbound to VPC services"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-inventory-app-sg"
    Environment = var.environment
  }
}

# Billing App Security Group (Worker microservice)
resource "aws_security_group" "billing_app" {
  name        = "code-keeper-${var.environment}-billing-app-sg"
  description = "Security group for Billing worker microservice"
  vpc_id      = var.vpc_id

  egress {
    description = "Allow outbound to database and RabbitMQ"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
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
    from_port       = 5672
    to_port         = 5672
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id, aws_security_group.billing_app.id]
  }

  ingress {
    description     = "Management UI port 15672 from API Gateway and Billing App"
    from_port       = 15672
    to_port         = 15672
    protocol        = "tcp"
    security_groups = [aws_security_group.api_gateway.id, aws_security_group.billing_app.id]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-rabbitmq-sg"
    Environment = var.environment
  }
}

# PostgreSQL Database Security Group
resource "aws_security_group" "database" {
  name        = "code-keeper-${var.environment}-database-sg"
  description = "Security group for Inventory and Billing RDS PostgreSQL databases"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL port 5432 from Inventory and Billing services"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.inventory_app.id, aws_security_group.billing_app.id]
  }

  tags = {
    Name        = "code-keeper-${var.environment}-database-sg"
    Environment = var.environment
  }
}
