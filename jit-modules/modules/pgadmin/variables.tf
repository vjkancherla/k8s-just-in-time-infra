variable "name" {
  description = "Name prefix for the pgAdmin container."
  type        = string
}

variable "ip" {
  description = "Static IP address for the pgAdmin container on the Docker network."
  type        = string
}

variable "network" {
  description = "Docker network name to attach the pgAdmin container to."
  type        = string
}

variable "http_port" {
  description = "Host port to publish pgAdmin's web UI on."
  type        = number
  default     = 5050
}

variable "share_dir" {
  description = <<-EOT
    Directory used to hand pgAdmin its servers.json, which must be visible to
    BOTH the process running tofu and the Docker daemon (the container bind-mounts
    the file). The two are not the same filesystem here: tofu runs inside the
    jit-runner container while the daemon is the host, so the /tmp default only
    works when tofu runs directly on the daemon's host. The runner supplies its
    own shared directory through TF_VAR_share_dir (deploy/runner.sh), which is why
    no caller has to pass this.
  EOT
  type        = string
  default     = "/tmp"
}

variable "postgres_url" {
  description = "PostgreSQL connection URL (host:port/db) for pgAdmin to register."
  type        = string
}

variable "postgres_port" {
  description = "PostgreSQL port."
  type        = number
  default     = 5432
}

variable "postgres_user" {
  description = "PostgreSQL username for pgAdmin connection."
  type        = string
  default     = "postgres"
}

variable "postgres_password" {
  description = "PostgreSQL password for pgAdmin connection."
  type        = string
  sensitive   = true
}

variable "pgadmin_email" {
  description = "Email for the pgAdmin default user."
  type        = string
  default     = "admin@example.com"
}

variable "pgadmin_password" {
  description = "Password for the pgAdmin default user."
  type        = string
  sensitive   = true
  default     = "admin"
}
