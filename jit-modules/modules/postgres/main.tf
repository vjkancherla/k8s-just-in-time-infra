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
    # Databases are logical objects managed against the running server (S27), not
    # init-time environment variables. The provider connects from the runner
    # container to the container's IP on the Docker network; the runner is at
    # .10 and Postgres at the allocated address, so no port publishing is needed.
    postgresql = {
      source  = "cyrilgdn/postgresql"
      version = "~> 1.22"
    }
  }
}

# Provider config from inputs, never from container attributes: the provider has
# known values on the first apply, before the container exists (S27 design note).
provider "postgresql" {
  host            = var.ip
  port            = 5432
  username        = "postgres"
  password        = var.postgres_password
  sslmode         = "disable"
  connect_timeout = 15
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
    # The password is NOT owned by this module. The controller generates it once
    # per namespace, reuses the value stored in the jit-postgres Secret so that
    # re-provisioning never rotates it, and writes it into that Secret as
    # POSTGRES_PASSWORD after a successful apply. The app pods read it from there.
    #
    # Do not add a `random_password` resource that replaces var.postgres_password:
    # the controller would keep writing its own value into the Secret and the pods'
    # PGPASSWORD would silently stop matching this container.
    #
    # Moving ownership into the module (the right production shape) requires the
    # runner to read `tofu output -json` first: plain-text `tofu output` renders a
    # sensitive value as the literal "<sensitive>", so the password would reach the
    # Secret unusable. Recorded in docs/lessons.md. (The runner now reads -json,
    # but the controller still owns the value, so this stays as-is.)
    "POSTGRES_PASSWORD=${var.postgres_password}",
    "POSTGRES_DB=${var.postgres_db}",
  ]

  # Allowlisted server settings become `-c key=value` flags. The allowlist itself
  # lives in the controller (S26), which refuses an unknown key before any runner
  # call; the module passes what it is given and refuses nothing itself.
  command = concat(["postgres"], flatten([
    for k, v in var.settings : ["-c", "${k}=${v}"]
  ]))

  # Wait until Postgres accepts connections before the postgresql_* resources run,
  # so a database is never created against a server that is not listening yet.
  healthcheck {
    test     = ["CMD-SHELL", "pg_isready -U postgres"]
    interval = "5s"
    timeout  = "3s"
    retries  = 12
  }
  wait         = true
  wait_timeout = 90

  # Deliberately no `ports` block. Publishing with `external = 0` records the
  # random host port in state, and the next plan diffs it (`external = <assigned>
  # -> 0 # forces replacement`), so every apply replaced the container even with
  # unchanged params — the side finding carried in ADR 0007 and fatal to S27/U2
  # ("adding a database keeps the container id"). Pods reach the container on the
  # Docker network by IP; nothing needs a host port.
}

# Additions only. The initial database is created by POSTGRES_DB at initdb and is
# already present in the volume; POSTGRES_DB cannot be imported on the apply that
# creates the container, because import blocks are evaluated before any resource
# is applied and refuse a non-existent target (ADR 0016). Removals are refused by
# the controller (U7), so a database is never dropped through this resource.
resource "postgresql_database" "this" {
  for_each   = setsubtract(var.databases, [var.postgres_db])
  name       = each.value
  owner      = "postgres"
  depends_on = [docker_container.postgres]
}
