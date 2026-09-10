terraform {
  # Remote state in MinIO: the runner supplies bucket/key/endpoint/credentials via
  # -backend-config at init time, so the block itself stays empty. Without it those
  # arguments are ignored and tofu falls back to local state in a throwaway work
  # directory, which a later cold destroy cannot see — it then reports success
  # having destroyed nothing.
  backend "s3" {}

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

locals {
  servers_json = jsonencode({
    "Nameservers" : {
      "servers" : [
        {
          "Name" : var.name,
          "Host" : var.postgres_url,
          "Port" : var.postgres_port,
          "Username" : var.postgres_user,
          "Password" : var.postgres_password,
          "Save" : true
        }
      ]
    }
  })
}

resource "local_file" "pgadmin_servers" {
  content  = local.servers_json
  filename = "/tmp/pgadmin-servers-${var.name}.json"
}

resource "docker_container" "pgadmin" {
  image = "dpage/pgadmin4:8.12"
  name  = "${var.name}-pgadmin"

  networks_advanced {
    name         = data.docker_network.this.name
    ipv4_address = var.ip
  }

  ports {
    internal = 80
    external = var.http_port
  }

  env = [
    "PGADMIN_DEFAULT_EMAIL=${var.pgadmin_email}",
    "PGADMIN_DEFAULT_PASSWORD=${var.pgadmin_password}",
  ]

  volumes {
    host_path      = abspath(local_file.pgadmin_servers.filename)
    container_path = "/pgadmin4/servers.json"
  }

  depends_on = [local_file.pgadmin_servers]
}
