output "broker_id" {
  description = "The ID of the RabbitMQ broker"
  value       = aws_mq_broker.rabbitmq.id
}

output "broker_endpoints" {
  description = "Connection endpoints for RabbitMQ"
  value       = aws_mq_broker.rabbitmq.instances[*].endpoints
}

output "broker_host" {
  description = <<-EOT
    Bare broker hostname, for RABBITMQ_HOST. The raw endpoint is an
    `amqps://host:5671` URL, which is not a hostname and will not resolve if
    passed as one. Strip the scheme and path; the port travels separately in
    RABBITMQ_PORT, and the client's own derivation turns 5671 into TLS.
  EOT
  value = replace(
    element(split("/", aws_mq_broker.rabbitmq.instances[*].endpoints[0]), 3),
    "^amqps://", "",
  )
}

output "broker_port" {
  description = "AMQPS port for the broker."
  value       = 5671
}
