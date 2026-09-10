variable "name" {
  description = "Name prefix for the Postgres container."
  type        = string
}

variable "ip" {
  description = "Static IP address for the Postgres container on the Docker network."
  type        = string
}

variable "network" {
  description = "Docker network name to attach the Postgres container to."
  type        = string
}

variable "postgres_password" {
  description = "Password for the postgres superuser."
  type        = string
  sensitive   = true
}

variable "postgres_db" {
  description = "Name of the database to create on initialization."
  type        = string
  default     = "voting"
}