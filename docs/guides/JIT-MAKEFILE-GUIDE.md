# Makefile Guide — JIT Infra PoC

> The root `Makefile` wraps `scripts/jit-*.sh` and the demo targets. It exists so the
> whole stack can be driven with short targets instead of remembering script paths, and
> so the console has exactly one name per action it can take.
>
> 👉 For driving the same thing by hand — one `kubectl` at a time, watching each piece
> appear — see [`JIT-MANUAL-GUIDE.md`](JIT-MANUAL-GUIDE.md). For the *app's* own build
> loop inside `app/`, see [`app/docs/MAKEFILE-GUIDE.md`](../app/docs/MAKEFILE-GUIDE.md).

---

## Table of Contents

1. [The two halves](#the-two-halves)
2. [Quick Start](#quick-start)
3. [Target Reference](#target-reference)
4. [Common Workflows](#common-workflows)
5. [Variables](#variables)
6. [The console's allowlist](#the-consoles-allowlist)
7. [Evidence and exit codes](#evidence-and-exit-codes)
8. [Troubleshooting](#troubleshooting)
9. [Quick Reference](#quick-reference)

---

## The two halves

Two Makefiles, deliberately separate:

| | |
|---|---|
| `app/Makefile` | the voting app's own build → deploy → verify loop (`make all`, `make verify`) |
| root `Makefile` | the JIT stack: MinIO, the runner, the CRD, the controller, and J1–J11 |

The root targets are thin wrappers over `scripts/jit-*.sh` — the same idiom the app uses.
The logic lives in a script you can read and run on its own; the target exists so you
don't have to remember which.

**Order matters in one direction only:** the JIT plane must be up before the app is
deployed, because the app's pods block on Secrets the controller has not created yet.
`demo-up` and `test-up` encode that order; nothing else needs to think about it.

---

## Quick Start

From nothing to a running, verified stack:

```bash
make demo-up          # one namespace, voting-a  (~3 min)
make test-up          # both namespaces, then the R-checks
```

Then look at it:

```bash
make state | python3 -m json.tool    # everything the console shows
kubectl get infraclaims -A
```

And take it all away:

```bash
make jit-down         # the JIT plane; the cluster and the app stay
make destroy          # the plane, then the cluster and the secret file
```

`make help` lists every target with its one-line description.

---

## Target Reference

| Target | Runs | Description |
|--------|------|-------------|
| `make help` | — | List targets (default goal) |
| `make jit-up` | `scripts/jit-up.sh` | Boot the out-of-cluster half: MinIO, the runner, the CRD, the controller |
| `make jit-verify` | `scripts/verify-jit.sh` | J1–J11 lifecycle suite → `.workflow/verify-jit.md`. Non-zero on FAIL |
| `make jit-down` | `scripts/jit-down.sh` | Remove the controller, the runner, MinIO and any leftover JIT containers |
| `make verify` | `app/scripts/verify.sh` | The app's R1–R17 in `NS` (default `voting-a`) → `app/.workflow/verify.md` |
| `make demo-up` | `scripts/demo-up.sh voting-a` | Cold path for one namespace: down, deploy, jit-up, then app deploy + verify |
| `make test-up` | `scripts/demo-up.sh voting-a voting-b` | The same for both namespaces |
| `make demo-undeploy` | `kubectl delete deployment` | Delete all three app Deployments (vote, worker, result) in `DEMO_NS`, so every claim orphans. The containers keep running on a clock |
| `make demo-redeploy` | `kubectl apply -k` | Re-apply the overlay. The claim returns to Ready with the same data |
| `make ns-delete NS=…` | `kubectl delete namespace` | Destroy `NS` now, ignoring the clock. Refuses anything outside `TENANTS` |
| `make destroy` | `jit-down` then `app make destroy` | Everything: the plane, then the k3d cluster and the generated secret |
| `make state` | `scripts/state.sh` | Print the read model as one JSON object |
| `make targets` | — | Print the console's allowlist, one name per line |
| `make check STEP=NN` | `scripts/checks/SNN.sh` | Run one frozen checkpoint |

**Idiom:** `demo-up` to get going, `jit-verify` to prove it behaves, `destroy` to get your
laptop back.

---

## Common Workflows

**Coming back after a long gap — is it still working?**
```bash
make destroy          # start from nothing so nothing stale can flatter you
make demo-up
make jit-verify       # 11 PASS means the design still holds
```
About five minutes, and it separates "the project is broken" from "I have forgotten how
to use it", which is the first thing you need to know.

**The soft-delete story, by target:**
```bash
make demo-up
make demo-undeploy    # pods go, containers stay, a clock starts
make state | jq '.namespaces[].claims[] | {module, phase, expiresAt}'
make demo-redeploy    # inside the window: same container, same data
```

**The hard-delete contrast:**
```bash
make test-up
make ns-delete NS=voting-b   # three containers go at once
make state | jq '.namespaces[].name'   # voting-a still there
```

**Run one checkpoint:**
```bash
make check STEP=17
```

**Just the app's checks, against the other namespace:**
```bash
make verify NS=voting-b
```

**Watch the controller while something happens:**
```bash
kubectl logs -f deploy/jit-controller -n default
```

---

## Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `DEMO_NS` | `voting-a` | Which namespace the demo targets act on |
| `TENANTS` | `voting-a voting-b` | The fence: the only namespaces `ns-delete` will destroy |
| `NS` | `voting-a` | Namespace for `make verify`; **required** for `make ns-delete` |
| `STEP` | — | Checkpoint number for `make check STEP=15` |

`TENANTS` is a guard, not a convenience. `make ns-delete NS=default` fails on purpose, and
so does `ns-delete` with no `NS` at all — the console can reach this target, so it is the
one place a typo could be expensive.

---

## The console's allowlist

`CONSOLE_TARGETS` in the Makefile is the list `make targets` prints, and the console
builds its buttons from that output. Three places have to agree on a name:

1. `CONSOLE_TARGETS` — the allowlist
2. `ALLOWED` in `console/serve.py` — the name and the command it runs
3. `ACTIONS` in `console/index.html` — the same name, plus the label

A name in the page that is missing from `ALLOWED` is refused with a 404 rather than
running something unexpected. Keep the action name and the target name identical.

`scripts/checks/S18.sh` asserts that `make targets` matches its own list exactly, so
adding or renaming a target reopens that checkpoint. That is deliberate.

---

## Evidence and exit codes

Every target appends its output to `docs/evidence/<target>.log`.

The recipes use `| tee` and then re-exit on `${PIPESTATUS[0]}`, because a bare pipe would
hand `make` *tee's* exit status — which is always 0 — and a target that cannot fail is
not a gate. If you add a target, copy that idiom.

Two targets are reads rather than runs: `state` and `targets`. Their stdout **is** the
payload something else parses, so nothing may print to stdout in those recipes but the
payload itself.

> **Note:** `make verify` deliberately does not trust `verify.sh`'s exit code —
> `verify.sh` omits `set -e` and returns 0 even when checks fail. The target parses the
> `===== N PASS, M FAIL =====` line out of `app/.workflow/verify.md` instead. If you ever
> find yourself trusting that script's status, you have reintroduced a bug the project
> already fixed once.

---

## Troubleshooting

| Symptom | Cause / Fix |
|---------|-------------|
| Pods stuck in `CreateContainerConfigError` | Expected, briefly. The kubelet is blocking on a Secret the controller has not created yet. If it persists, the claim is not Ready — `kubectl get infraclaims -A` and the controller logs. |
| Namespace stuck `Terminating` | A finalizer is held because the runner call failed. `kubectl get infraclaims -n <ns> -o yaml` to see which; escape hatch is `tofu destroy` by hand then patch the finalizer off. |
| `ns-delete` refuses | Missing `NS=`, or an `NS` outside `TENANTS`. Both are intentional. |
| A container survived a teardown | `jit-down` sweeps by name; if it was renamed or created outside the runner, remove it and **its volume** by hand. A Postgres data directory carries its own password, so a volume outliving its container makes the next stack's fresh password unusable. |
| `make state` prints nothing | It should print `"up": false` rather than fail. If it prints nothing at all, run `scripts/state.sh` directly. |
| Two claims took the same address | Should not happen — the IPAM pick is serialised per namespace. If it does, the ledger is `kubectl get cm jit-ipam -n default -o yaml`. |
| Port 5000 in use | AirPlay on macOS. The app's registry mode moves it: `REGISTRY=1 REGISTRY_PORT=5001`. |

---

## Quick Reference

| Goal | Command |
|------|---------|
| Everything up, one namespace | `make demo-up` |
| Everything up, both | `make test-up` |
| Prove the lifecycle works | `make jit-verify` |
| Prove the app works | `make verify` |
| See what exists | `make state \| python3 -m json.tool` |
| Soft delete / undo | `make demo-undeploy` / `make demo-redeploy` |
| Hard delete | `make ns-delete NS=voting-b` |
| Plane down, cluster stays | `make jit-down` |
| Everything gone | `make destroy` |
| One checkpoint | `make check STEP=NN` |

**Tip:** `make demo-up` starts with `jit-down`, so running it twice is a clean restart.
You rarely need `destroy` unless you want the cluster gone too.
