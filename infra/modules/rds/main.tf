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

  tags = {
    Name        = "code-keeper-${var.environment}-billing-db"
    Environment = var.environment
  }
}
