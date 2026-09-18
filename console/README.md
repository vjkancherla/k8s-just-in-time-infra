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
| `state.py` | the read model — `make state` calls this to build the JSON the page polls |
| `state.sh` | the shell read model — the original, used by `make state` and the checkpoints |
| `test_browser.py` | Playwright browser tests — renders every fixture state, asserts on every tab |
| `test_console.py` | declaration/contract tests — the page's structural assertions against serve.py |
| `test_serve.py` | proxy/unit tests — the allowlist, the SAFE regex, the /log tail, /claim |
| `fixtures/` | JSON state files written by `test_browser.py` before each run |
| `shots/` | numbered PNGs from `--shots`, one per fixture × tab |

## Endpoints

Five endpoints, and that is the whole surface:

| Endpoint | Method | What it does |
|---|---|---|
| `/` | GET | the page |
| `/state` | GET | `make state` — the read model the page polls every 2 s |
| `/claim?ns=&module=` | GET | `make claim` — one InfraClaim as YAML, for the object panel |
| `/log?name=x&offset=n` | GET | what the current run has written since byte `n` |
| `/run/{name}` | POST | the make target in `ALLOWED`, and nothing else |

`/claim` is fetched on demand — the page never polls it.
`/state` is the only endpoint on the 2-second poll.

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

Destructive actions (those with `danger:true`) show a browser confirm dialog before
running. The action list and mode note update immediately when you switch modes.

### Tabs

Five tabs. When nothing is running the non-setup tabs dim to 45 % opacity
(`.sleeping`); switching to them still works but shows the empty state.

| Tab | What it shows |
|---|---|
| **Setup** | The action buttons for the current mode, a mode-explanation note, and the live log of the current run. |
| **Infrastructure** | Claims grouped by phase (In use / On the clock / In flight / Failed), the namespace summary, the phase-change feed, and a collapsible container/state-object strip. |
| **Voting app** | The vote and result pages as real iframes, with URLs read from the cluster's Ingress. A namespace switcher appears when two namespaces exist. Claim chips and a pgAdmin note sit below the iframes. |
| **Timeline** | Fetched on demand (never polled). Shows how long each provisioning step took, with a chart and an event table. Empty until the first run completes. |
| **Guide** | Reference page: the two modes, what each tab does, the five claim phases, every action with its make target, and common gotchas. |

### The bar

The sticky top bar has: the JIT logo, the Demo/Testing mode switch, the five
tab buttons, and a status LED pill.

| LED state | Meaning |
|---|---|
| Grey | Nothing running (`up: false`) |
| Green | All claims Ready |
| Amber | At least one claim is Orphaned or Failed |

The LED text is a short summary: "Nothing running", "3 claims Ready", "1 on the
clock", "1 claim failed", etc.

### Infrastructure tab in detail

The Infrastructure tab has several sections, top to bottom:

1. **H1 and subtitle** — dynamic: "3 claims across 1 namespace" when Ready,
   "Nothing was destroyed. A clock started." when Orphaned.
2. **Namespaces panel** — one row per namespace showing the claim count and
   phase breakdown (e.g. "3 claims · 3 Ready").
3. **Claim groups** — claims are grouped by phase category. Each claim card
   shows the module name, namespace + address, and a sentence: "Used by
   vote and worker" for Ready, "Destroyed in 9:45 unless something asks for
   it again" for Orphaned, etc. Clicking a claim opens the object panel.
4. **Object panel** — appears when a claim is clicked. Two collapsible
   `<details>` blocks: "Running on Docker" (container name, address, image,
   status, ports, volume) and "Asked for in Kubernetes" (the InfraClaim YAML,
   with a toggle to hide/show Kopf bookkeeping lines).
5. **Phase-change feed** — "What changed since you opened this page". Shows
   transitions observed across polls (e.g. "pgadmin Ready → Orphaned").
   Empty on first load: "Nothing yet. Phase changes show up here as they
   happen."
6. **Containers and state objects** — collapsed `<details>`. Container chips
   are colour-coded: green for claim-owned, grey for control-plane, dashed
   for orphaned. State-object chips show the MinIO key.

### Voting app tab in detail

- Vote and result are real iframes of the Ingress hosts.
- The URL bar shows the full URL without `http://`.
- **Open** links open the URL in a new tab — necessary because the app uses
  HTTPS with a self-signed certificate, and a pane stays blank until the
  browser trusts it. Accept the warning once per host, then reload.
- A namespace switcher (`#nsSwitch`) appears only when two namespaces exist.
- Claim chips below the iframes show each module's phase and address.
- `#pgAdminLine` shows: "pgAdmin is up on its own host port — open it to see
  the votes table the worker writes to." when pgAdmin is Ready.

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
3. `ACTIONS` in `index.html` — the same name, plus the label, description, mode,
   and optional `hint` and `danger` flags.

A name in the page that is missing from `ALLOWED` gets a 404 rather than
running something unexpected. Keep the action name and the target name
identical; there is no reason for them to differ and every reason not to.

## Testing

Three test files, no cluster required:

| File | What it tests | Runner |
|---|---|---|
| `test_serve.py` | The allowlist, the SAFE regex, /log tail, /claim, rejection of bad names | `python3 console/test_serve.py` |
| `test_console.py` | Declaration/contract: every ALLOWED name appears in ACTIONS, every ACTIONS name is in ALLOWED, endpoint count, SAFE regex coverage | `python3 console/test_console.py` |
| `test_browser.py` | Playwright: renders ten fixture states (down, ready, pending, orphaned, expiring, failed, plane-only, no-port, no-routes, two-namespaces) and asserts on every tab, the LED, claim cards, the feed, the object panel, the guide, mode switching, destructive confirm dialogs, and a full JS error sweep | `console/.venv/bin/python console/test_browser.py` |

```bash
# All three
make console-test

# Browser screenshots only (writes numbered PNGs to console/shots/)
make console-shots
```

See [`docs/guides/TESTING-THE-CONSOLE.md`](../docs/guides/TESTING-THE-CONSOLE.md) for the
full testing guide, including how to set up the Playwright venv.

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
