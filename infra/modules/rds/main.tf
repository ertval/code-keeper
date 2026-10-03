terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Customer managed key for RDS Performance Insights.
data "aws_iam_policy_document" "performance_insights" {
  statement {
    sid    = "AllowRdsServiceAccount"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["rds.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey*",
      "kms:Encrypt",
      "kms:CreateGrant",
      "kms:DescribeKey"
    ]
    resources = ["*"]
  }
}

resource "aws_kms_key" "performance_insights" {
  description             = "code-keeper ${var.environment} RDS performance insights key"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.performance_insights.json

  tags = {
    Name        = "code-keeper-${var.environment}-rds-pi-key"
    Environment = var.environment
  }
}

resource "aws_kms_alias" "performance_insights" {
  name          = "alias/code-keeper-${var.environment}-rds-pi"
  target_key_id = aws_kms_key.performance_insights.key_id
}

resource "aws_db_subnet_group" "db_subnet" {
  name        = "code-keeper-${var.environment}-db-subnet-group"
  subnet_ids  = var.database_subnet_ids
  description = "Database subnet group for code-keeper ${var.environment}"

  tags = {
    Name        = "code-keeper-${var.environment}-db-subnet-group"
    Environment = var.environment
  }
}

# Inventory Database (movies)
resource "aws_db_instance" "inventory_db" {
  identifier              = "code-keeper-${var.environment}-inventory-db"
  allocated_storage       = var.allocated_storage
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = var.instance_class
  db_name                 = var.inventory_db_name
  username                = var.inventory_db_username
  password                = var.inventory_db_password
  db_subnet_group_name    = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids  = [var.security_group_id]
  skip_final_snapshot     = true
  multi_az                = var.multi_az
  storage_encrypted       = true
  backup_retention_period = var.backup_retention_period
  publicly_accessible     = false

  auto_minor_version_upgrade      = true
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.performance_insights.arn

  tags = {
    Name        = "code-keeper-${var.environment}-inventory-db"
    Environment = var.environment
  }
}

# Billing Database (orders)
resource "aws_db_instance" "billing_db" {
  identifier              = "code-keeper-${var.environment}-billing-db"
  allocated_storage       = var.allocated_storage
  engine                  = "postgres"
  engine_version          = "15.4"
  instance_class          = var.instance_class
  db_name                 = var.billing_db_name
  username                = var.billing_db_username
  password                = var.billing_db_password
  db_subnet_group_name    = aws_db_subnet_group.db_subnet.name
  vpc_security_group_ids  = [var.security_group_id]
  skip_final_snapshot     = true
  multi_az                = var.multi_az
  storage_encrypted       = true
  backup_retention_period = var.backup_retention_period
  publicly_accessible     = false

  auto_minor_version_upgrade      = true
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.performance_insights.arn

  tags = {
    Name        = "code-keeper-${var.environment}-billing-db"
    Environment = var.environment
  }
}
