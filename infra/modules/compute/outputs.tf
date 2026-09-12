output "alb_dns_name" {
  description = "Public DNS name of the Application Load Balancer"
  value       = aws_lb.alb.dns_name
}

output "ecs_cluster_name" {
  description = "Name of the ECS cluster"
  value       = aws_ecs_cluster.main.name
}

output "api_gateway_service_name" {
  description = "Name of API Gateway ECS service"
  value       = aws_ecs_service.api_gateway.name
}

output "inventory_app_service_name" {
  description = "Name of Inventory App ECS service"
  value       = aws_ecs_service.inventory_app.name
}

output "billing_app_service_name" {
  description = "Name of Billing App ECS service"
  value       = aws_ecs_service.billing_app.name
}
