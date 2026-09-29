# 0016. The postgres initial-database import is plan-time-incompatible; the module manages additions only

Date: 2026-09-29
Status: accepted

## Context

The design (`docs/designs/declarers-and-consumers.md:170`) and build-plan S27 require the
postgres module to manage `postgresql_database` resources with `for_each` over
`var.databases`, and to bring the initial database — created by `POSTGRES_DB` at
`initdb` — into state with an **import block**:

> The initial database from `POSTGRES_DB` already exists after init, so a plain create
> would fail; an import block brings it into state instead (for_each on imports needs
> OpenTofu 1.7+).

In this module the container that runs `initdb` is created by the *same* `tofu apply` that
would carry the import. OpenTofu evaluates `import` blocks during **plan**, before any
resource is applied, and refuses a non-existent target. Measured on this host with
OpenTofu 1.8.1: a `docker_volume` resource plus an import block for that same volume fails
`tofu plan` with

```
Error: Cannot import non-existent remote object
While attempting to import an existing object to "docker_volume.x", the provider
detected that no object exists with the given id. Only pre-existing objects can be
imported ...
```

`-target` does not help: the import is processed even for a targeted plan. So on the first
apply for a workspace (the S27 checkpoint's first apply, and the controller's first apply
for any declarer that names its databases from the start) the initial database does not
exist at plan time and the import fails. There is no single-apply formulation in which the
import can succeed.

## Decision

The postgres module leaves the initial database (`var.postgres_db`) unmanaged: it is
created by `initdb` and lives in the named volume. `postgresql_database` is
`for_each = setsubtract(var.databases, [var.postgres_db])`, so a database that starts as
part of `databases` and already exists is never created (and never imported); only
*additions* become managed resources.

The destroy path is unaffected: the volume is destroyed with the container, and the
runner's `tofu state rm postgresql_*` still drops the additions from state before destroy.
Removals are refused by the controller (U7), so no database is ever dropped through the
module.

This is the same intent the design states — additions create databases in place, removals
are refused — reached without an import.

## Consequences

**Easy.** A first apply succeeds whether or not `databases` names the initial database
(the checkpoint's `["voting"]`, and the demo's declarer), and a fresh apply that names
additional databases (`["voting","analytics"]` from a cold namespace) creates them after
the container is healthy. No import state is carried.

**Hard / ruled out.** The initial database's existence is not a managed Terraform
resource, so Terraform will not recreate it if it is dropped out of band; the volume is
the source of truth and a cold destroy removes it, which is the accepted s17 contract.
The design's "for_each over `var.databases` + import" line is superseded for this module;
the build-plan's U2/U7 assertions (in-place additions, removals refused) still hold.
