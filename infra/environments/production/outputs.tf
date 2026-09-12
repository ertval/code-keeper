output "alb_dns_name" {
  description = "Production Load balancer public DNS endpoint"
  value       = module.compute.alb_dns_name
}

output "ecs_cluster_name" {
  description = "Production ECS cluster identifier"
  value       = module.compute.ecs_cluster_name
}

output "inventory_db_endpoint" {
  description = "Production Inventory database endpoint"
  value       = module.rds.inventory_db_endpoint
}

output "billing_db_endpoint" {
  description = "Production Billing database endpoint"
  value       = module.rds.billing_db_endpoint
}
