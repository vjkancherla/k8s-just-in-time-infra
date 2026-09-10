output "address" {
  description = "The IP address of the pgAdmin container."
  value       = var.ip
}

output "http_port" {
  description = "The host port pgAdmin's web UI is reachable on."
  value       = var.http_port
}

output "url" {
  description = "The URL to access pgAdmin's web UI."
  value       = "http://${var.ip}:${var.http_port}"
}

output "postgres_url" {
  description = "The PostgreSQL connection URL registered in pgAdmin."
  value       = var.postgres_url
}
