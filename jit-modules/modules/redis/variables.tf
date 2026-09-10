variable "name" {
  description = "Name prefix for the Redis container."
  type        = string
}

variable "ip" {
  description = "Static IP address for the Redis container on the Docker network."
  type        = string
}

variable "network" {
  description = "Docker network name to attach the Redis container to."
  type        = string
}

variable "maxmemory" {
  description = "Maximum memory for Redis in bytes (e.g. 256mb)."
  type        = string
  default     = "256mb"
}
