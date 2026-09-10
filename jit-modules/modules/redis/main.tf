terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

data "docker_network" "this" {
  name = var.network
}

resource "docker_container" "redis" {
  image = "redis:7-alpine"
  name  = "${var.name}-redis"

  networks_advanced {
    name         = data.docker_network.this.name
    ipv4_address = var.ip
  }

  command = ["redis-server", "--maxmemory", var.maxmemory, "--maxmemory-policy", "noeviction"]

  ports {
    internal = 6379
    external = 0
  }
}
