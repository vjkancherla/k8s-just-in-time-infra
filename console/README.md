# console

A local page for starting the stack and looking at what it made. Runs on your
laptop, not in the cluster — it has to work before the cluster exists.

```
python3 console/serve.py
open http://127.0.0.1:8090
```

Ctrl-C stops it. Nothing is left running.

## Files

| | |
|---|---|
| `index.html` | the page. One file, no build step, no dependencies |
| `serve.py` | serves the page, calls `make state`, runs an allowlist of make targets |

Three endpoints, and that is the whole surface:

- `GET /` — the page
- `GET /state` — `make state`
- `GET /log?name=x&offset=n` — what the current run has written since byte `n`
- `POST /run/{name}` — the make target in `serve.py`'s `ALLOWED`, and nothing else

## The rule

**The console holds no state, computes nothing, and runs no `kubectl` of its own.**

Everything it shows comes from `make state`, which reads the same sources the
frozen checkpoints read. Every action is one make target. `expiresAt` is passed
through exactly as the controller wrote it; the countdown on screen is
arithmetic in the browser, not a second opinion about when something expires.

If the page ever computes phase or expiry for itself, it will disagree with
`make jit-verify`, and the disagreement becomes the thing you debug instead of
the system.

## Where to look when it is wrong

Start with the read model, outside the browser:

```
make -s state | python3 -m json.tool
```

`scripts/state.sh` produces it and never fails: if something is unreachable it
prints `"up": false` with empty lists, because the page polls this before
anything exists. An empty result means *nothing found*, not *nothing broken*.

If `/state` returns nothing useful, `serve.py` prints the stderr from
`make state` to the terminal — look there before the browser console.

## What the page expects from `make state`

```json
{
  "up": true,
  "generatedAt": "2026-09-12T09:41:06Z",
  "ingressPorts": { "http": 8081, "https": 8082 },
  "namespaces": [
    { "name": "voting-a",
      "block": "172.19.0.100-109",
      "claims": [
        { "module": "redis", "phase": "Ready", "address": "172.19.0.100",
          "referencedBy": ["vote","worker"], "expiresAt": null } ],
      "ingresses": [
        { "host": "vote.localhost", "path": "/", "service": "voting-app-vote", "tls": true } ] } ],
  "containers": [ { "name": "voting-a-redis", "address": "172.19.0.100", "running": true } ],
  "stateObjects": [ "ns/voting-a/redis/terraform.tfstate" ]
}
```

`ingresses` and `ingressPorts` are what the Voting app tab builds its URLs from
— host, scheme and port all come from the cluster, none of them are constructed
here. Drop those fields and the Infrastructure tab still works; the app panes
have nothing to point at.

## The page

Two modes in the toolbar:

| Mode | What it does | Buttons (in order) |
|---|---|---|
| **Demo** | One namespace (`voting-a`), guided walkthrough | **Start the demo** → **Delete the deployment** → **Redeploy inside the window** → **Delete the namespace** |
| **Testing** | Both namespaces (`voting-a` + `voting-b`), full lifecycle | **Set everything up** → **Start the control plane** → **Check the app works** → **Check the JIT behaviour** → **Delete `voting-b`** → **Shut the JIT plane down** → **Delete everything** |

Demo is for showing the JIT concept in ~3 minutes. Testing is for running the full
J1-J11 lifecycle suite — `voting-b` exists so J8 can show that a hard delete is bounded.

Three tabs. **Setup** runs things, with the log below the actions at full width.
**Infrastructure** shows the claims, their phase, the live countdown on anything
Orphaned, the containers and the state objects. **Voting app** embeds the vote
and result pages for the selected namespace.

The panes are real iframes of the real Ingress hosts. The app serves HTTPS with
a self-signed certificate, so a pane stays blank until the browser trusts it:
use **Open**, accept the warning once per host, then reload. Chrome gives no
event for this, which is why the page says so rather than detecting it.

## The allowlist

Every button maps to exactly one `make` target. The full mapping:

| Button name | Make target | Notes |
|---|---|---|
| `demo-up` | `make demo-up` | Cold start for one namespace |
| `demo-undeploy` | `make demo-undeploy` | Delete vote Deployment |
| `demo-redeploy` | `make demo-redeploy` | Re-apply the overlay |
| `ns-delete-a` | `make ns-delete NS=voting-a` | Hard delete voting-a |
| `test-up` | `make test-up` | Cold start for both namespaces |
| `jit-up` | `make jit-up` | Start the JIT control plane |
| `verify` | `make verify NS=voting-a` | Run R1-R17 |
| `jit-verify` | `make jit-verify` | Run J1-J11 |
| `ns-delete-b` | `make ns-delete NS=voting-b` | Hard delete voting-b |
| `jit-down` | `make jit-down` | Stop the JIT control plane |
| `destroy` | `make destroy` | Everything: JIT plane + cluster |

A name missing from `ALLOWED` in `serve.py` gets a 404. Run `make targets` to see
the current allowlist as the console sees it.

## Adding an action

Three places, and they must agree on the name:

1. `CONSOLE_TARGETS` in the root `Makefile` — the allowlist `make targets` prints.
2. `ALLOWED` in `serve.py` — the name and the target it runs.
3. `ACTIONS` in `index.html` — the same name, plus the label and description.

A name in the page that is missing from `ALLOWED` gets a 404 rather than
running something unexpected. Keep the action name and the target name
identical; there is no reason for them to differ and every reason not to.

## Known rough edges

Restarting the server loses the log pane — the run's output is still in
`docs/evidence/console-*.log`, the page just doesn't go looking for it on load.
State and countdowns survive fine, since neither lives here.

Ctrl-C during a run does not kill the `make` child; it is not in a process group
that dies with the parent. An interrupted `demo-up` leaves a half-built cluster,
so check `docker ps` and `k3d cluster list` before restarting.

Mode resets to Demo on reload. It is client-side and not persisted.

Container addresses are read through `docker inspect`, never by connecting to
them. On macOS the host cannot route to `172.19.0.x` at all.
