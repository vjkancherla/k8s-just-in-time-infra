output "address" {
  description = "The IP address of the pgAdmin container."
  value       = var.ip
}

output "port" {
  description = "The port pgAdmin's web UI listens on *inside* the container. The controller writes this into the jit-pgadmin Service, so a missing output made the Service advertise redis's default 6379 (found in S16, fixed in S17)."
  value       = 80
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
