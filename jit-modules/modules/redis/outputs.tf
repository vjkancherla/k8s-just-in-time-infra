output "address" {
  description = "The IP address of the Redis container."
  value       = [for n in docker_container.redis.networks_advanced : n.ipv4_address if n.ipv4_address == var.ip][0]
}

output "port" {
  description = "The internal port Redis is listening on."
  value       = 6379
}

output "url" {
  description = "The full Redis connection URL."
  value       = "redis://${[for n in docker_container.redis.networks_advanced : n.ipv4_address if n.ipv4_address == var.ip][0]}:6379"
}
