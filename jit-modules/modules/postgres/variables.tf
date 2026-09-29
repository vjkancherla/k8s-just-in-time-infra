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
  description = "Name of the database created by POSTGRES_DB at initdb. It is left unmanaged (ADR 0016) and is the initial database for `service_url`."
  type        = string
  default     = "voting"
}

variable "databases" {
  description = "Databases to manage against the running server. Declared in S24 so the frozen S24 checkpoint's create can succeed; S27 wires it to postgresql_database resources (additions only — the initial database is initdb-owned, ADR 0016)."
  type        = list(string)
  default     = []
}

variable "settings" {
  description = "Postgres server settings (e.g. max_connections) passed as `-c key=value` in the container command. The controller's contract owns the allowlist; the module passes whatever it is given."
  type        = map(string)
  default     = {}
}

variable "service_name" {
  description = "The Service name the controller creates for this module (jit-<module>). Used to build service_url/service_urls so a pod resolves the Service and its EndpointSlice rather than a container IP."
  type        = string
  default     = "jit-postgres"
}
