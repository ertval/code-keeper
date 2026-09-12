resource "aws_mq_broker" "rabbitmq" {
  broker_name         = "code-keeper-${var.environment}-rabbitmq"
  engine_type         = "RabbitMQ"
  engine_version      = "3.11.20"
  host_instance_type  = var.host_instance_type
  deployment_mode     = var.deployment_mode
  publicly_accessible = false
  subnet_ids          = var.deployment_mode == "CLUSTER_MULTI_AZ" ? var.subnet_ids : [var.subnet_ids[0]]
  security_groups     = [var.security_group_id]

  user {
    username = var.admin_username
    password = var.admin_password
  }

  tags = {
    Name        = "code-keeper-${var.environment}-rabbitmq"
    Environment = var.environment
  }
}
