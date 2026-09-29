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

resource "docker_container" "redis" {
  image = "redis:7-alpine"
  name  = "${var.name}-redis"

  networks_advanced {
    name         = data.docker_network.this.name
    ipv4_address = var.ip
  }

  command = ["redis-server", "--maxmemory", var.maxmemory, "--maxmemory-policy", "noeviction"]

  # Deliberately no `ports` block: `external = 0` records the random host port in
  # state and the next plan diffs it, forcing a replacement on every apply even
  # with unchanged params (the side finding carried in ADR 0007). Consumers reach
  # redis by IP on the Docker network (the app uses the Service+EndpointSlice),
  # so no host port is needed. The maxmemory change still replaces the container,
  # which is the intended U1 behaviour.
}
