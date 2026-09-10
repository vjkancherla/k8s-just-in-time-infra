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
  description = "Password for the postgres superuser. Supplied by the controller, which owns and persists it — see the note in main.tf before changing how this is populated."
  type        = string
  sensitive   = true
}

variable "postgres_db" {
  description = "Name of the database to create on initialization."
  type        = string
  default     = "voting"
}