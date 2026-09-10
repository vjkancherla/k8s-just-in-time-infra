output "address" {
  description = "The IP address of the Postgres container."
  value       = var.ip
}

output "port" {
  description = "The internal port Postgres is listening on."
  value       = 5432
}

output "url" {
  description = "The full Postgres connection URL."
  # Carries the password, so the value must be marked sensitive — otherwise
  # `tofu apply` fails with "Output refers to sensitive values".
  sensitive   = true
  value       = "postgresql://${var.postgres_password}@${var.ip}:5432/${var.postgres_db}"
}

output "volume_name" {
  description = "The name of the named volume backing Postgres data."
  value       = docker_volume.postgres_data.name
}