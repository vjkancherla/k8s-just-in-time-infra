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
