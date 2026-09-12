output "inventory_db_endpoint" {
  description = "Connection endpoint for the inventory database"
  value       = aws_db_instance.inventory_db.endpoint
}

output "inventory_db_address" {
  description = "Address host of the inventory database"
  value       = aws_db_instance.inventory_db.address
}

output "billing_db_endpoint" {
  description = "Connection endpoint for the billing database"
  value       = aws_db_instance.billing_db.endpoint
}

output "billing_db_address" {
  description = "Address host of the billing database"
  value       = aws_db_instance.billing_db.address
}
