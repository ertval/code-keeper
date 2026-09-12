output "alb_security_group_id" {
  description = "Security group ID of the ALB"
  value       = aws_security_group.alb.id
}

output "api_gateway_security_group_id" {
  description = "Security group ID of the API Gateway"
  value       = aws_security_group.api_gateway.id
}

output "inventory_app_security_group_id" {
  description = "Security group ID of the Inventory App"
  value       = aws_security_group.inventory_app.id
}

output "billing_app_security_group_id" {
  description = "Security group ID of the Billing App"
  value       = aws_security_group.billing_app.id
}

output "rabbitmq_security_group_id" {
  description = "Security group ID of RabbitMQ"
  value       = aws_security_group.rabbitmq.id
}

output "database_security_group_id" {
  description = "Security group ID of PostgreSQL databases"
  value       = aws_security_group.database.id
}
