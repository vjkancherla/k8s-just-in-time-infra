output "address" {
  description = "The IP address of the Postgres container."
  value       = var.ip
}

output "port" {
  description = "The internal port Postgres is listening on."
  value       = 5432
}

output "url" {
  description = "The full Postgres connection URL, addressed by container IP."
  # Carries the password, so the value must be marked sensitive — otherwise
  # `tofu apply` fails with "Output refers to sensitive values".
  sensitive = true
  value     = "postgresql://${var.postgres_password}@${var.ip}:5432/${var.postgres_db}"
}

output "volume_name" {
  description = "The name of the named volume backing Postgres data."
  value       = docker_volume.postgres_data.name
}

# The app-facing URLs. They are deliberately NOT marked sensitive: the runner
# reads `tofu output -json` and the controller copies these into the jit-postgres
# Secret, which is where a pod reads them; a sensitive output would be redacted to
# "<sensitive>" and be unusable. They carry the password, exactly as
# POSTGRES_PASSWORD and the controller-built service_url in the same Secret do.
# `nonsensitive` is the explicit acknowledgement OpenTofu requires to export it.
# They address the Service (jit-<module>) so a pod resolves the EndpointSlice and
# survives an IP move — the same host the controller uses for its own service_url.
locals {
  pg_password = nonsensitive(var.postgres_password)
}

output "service_url" {
  description = "Service-addressed URL for the initial database. Existing key: its value must not change across applies."
  value       = "postgresql://postgres:${local.pg_password}@${var.service_name}:5432/${var.postgres_db}"
}

output "service_urls" {
  # Additions only, mirroring the postgresql_database resource's setsubtract: the
  # initial database's key is `service_url` (above), so emitting it here too would
  # add a redundant `service_url_<postgres_db>` the design does not name. The
  # runner flattens this map to the `service_url_<db>` Secret keys for the
  # databases added to `var.databases`.
  description = "Service-addressed URL for each added database, keyed by database name. The runner flattens this to the service_url_<db> Secret keys."
  value       = { for db in setsubtract(var.databases, [var.postgres_db]) : db => "postgresql://postgres:${local.pg_password}@${var.service_name}:5432/${db}" }
}
