output "broker_id" {
  description = "The ID of the RabbitMQ broker"
  value       = aws_mq_broker.rabbitmq.id
}

output "broker_endpoints" {
  description = "Connection endpoints for RabbitMQ"
  value       = aws_mq_broker.rabbitmq.instances[*].endpoints
}
