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

# The apps authenticate to PostgreSQL with these, so the task definitions must
# be given the same values the instances were created with. They used to be
# injected as POSTGRES_*, which no application reads.
output "inventory_db_username" {
  description = "Username the inventory app must present"
  value       = aws_db_instance.inventory_db.username
}

output "inventory_db_name" {
  description = "Name of the inventory database"
  value       = aws_db_instance.inventory_db.db_name
}

output "billing_db_username" {
  description = "Username the billing app must present"
  value       = aws_db_instance.billing_db.username
}

output "billing_db_name" {
  description = "Name of the billing database"
  value       = aws_db_instance.billing_db.db_name
}
