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
  # "amqps://host:5671" splits on "/" into exactly three elements
  # ["amqps:", "", "host:5671"], so the authority is index 2 -- index 3 wraps
  # around to 0 and yields the literal "amqps:". The port is then split off, so
  # RABBITMQ_HOST is a bare hostname and RABBITMQ_PORT carries 5671, which is
  # what makes the client's own rule derive TLS.
  value = split(":", element(split("/", aws_mq_broker.rabbitmq.instances[0].endpoints[0]), 2))[0]
}

output "broker_port" {
  description = "AMQPS port for the broker."
  value       = 5671
}
