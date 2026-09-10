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

resource "docker_volume" "postgres_data" {
  name = "${var.name}-postgres-data"

  # Named volumes survive container removal by default — no destroy_opts needed
}

resource "docker_container" "postgres" {
  image = "postgres:16-alpine"
  name  = "${var.name}-postgres"

  # Keep named volumes when container is destroyed (data persistence)
  remove_volumes = false

  networks_advanced {
    name         = data.docker_network.this.name
    ipv4_address = var.ip
  }

  volumes {
    volume_name    = docker_volume.postgres_data.name
    container_path = "/var/lib/postgresql/data"
  }

  env = [
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
  ]

  ports {
    internal = 5432
    external = 0
  }
}