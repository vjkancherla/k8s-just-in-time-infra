# Console Demo Test Plan

> Run this before you show the console to anyone. It is the manual counterpart to
> `console/test_serve.py` (19 tests) and `scripts/checks/S18.sh`: those prove the console's
> code, this proves the console in a browser, in front of the stack, on this laptop.
>
> Authored `2026-09-17` against `console/serve.py`, `console/index.html`, `scripts/state.sh`,
> `Makefile`, `scripts/demo-up.sh` and `scripts/verify-jit.sh`. **Track A was run on a cold host**
> that day, and the read-model values in B2, B3, B5 and C1 were checked against a live cluster on
> the same day: three module containers with their addresses, the exact `referencedBy` sets, the
> `.100-109` block, `tls: false` on both Ingresses, `softDeleteTTL: 10m`. The rest of Tracks B-E is
> read from those files and **must be re-run here** — that is the point of the exercise.

## How to use it

- Each scenario has an **id**, **steps**, and a **pass line** in bold. Tick it, or write down
  what you saw instead — a scenario that does not match is the finding.
- Run the tracks **in order**. Track D leaves the cluster in a different state than Track B
  does (see C1 and D4), so a demo that follows a testing run needs B re-run first.
- Cost: A ≈ 2 min, B ≈ 5 min, C ≈ 4 min, D ≈ 15 min, E ≈ 10 min.

| Track | What it covers | Needs a cluster |
|---|---|---|
| **A** | Console up, nothing else: the empty states and the refusals | no |
| **B** | The cold path driven from the page, and everything it displays | yes (~3 min) |
| **C** | The 3-minute executive demo, click by click | yes |
| **D** | The Testing mode and the full J1–J11 lifecycle | yes (~15 min) |
| **E** | Failure and recovery drills | mixed |

## Preconditions

Run every command from the repo root unless it says otherwise.

| # | Check | Command | Pass |
|---|---|---|---|
| P1 | Docker is running | `docker ps` | it answers (bare `docker-proxy` is normal on macOS) |
| P2 | Tools present | `k3d version; kubectl version --client; jq --version; python3 --version` | all four answer |
| P3 | The host is cold before a rehearsal | `k3d cluster list; docker ps --format '{{.Names}}'` | no `voting-app` cluster, no `jit-*`/`voting-*` containers |
| P4 | Nothing else holds the console port | `lsof -nP -iTCP:8090 -sTCP:LISTEN` | no output |
| P5 | Working tree known | `git status --short` | write down what is dirty first (see O4) |

`make demo-up` starts by destroying the cluster. **That is the cold path and it is
load-bearing** (`scripts/demo-up.sh`, "Why step 1") — do not "save time" by skipping it.

---

## Track A — Console up, nothing else (no cluster)

Start it and leave it running for the rest of the plan:

```bash
python3 console/serve.py        # prints: console on http://127.0.0.1:8090   (Ctrl-C to stop)
open http://127.0.0.1:8090
```

### A1 — The page loads with no stack behind it

**Steps.** Open the page. Look at the header pill, the Setup tab, and the other three tabs.

**Pass.** Header shows the grey LED and **`Nothing running`**. Setup heading reads
**`Nothing is running yet.`**. Demo mode lists **five** rows and no others: *Start the demo*,
*Delete the deployment*, *Redeploy inside the window*, *Delete the namespace*, *Delete
everything*. **Infrastructure**, **Voting app** and **Guide** are dimmed; Infrastructure shows
**`No infrastructure yet`**, Voting app shows **`The app isn't up`**. Footer reads
**`Live. Polling make state every 2s.`** The log pane holds the dim placeholder *"Output from a
run appears here, as it happens."*

*Measured 2026-09-17: `GET /` = 200, 44,291 bytes, footer marker present.*

### A2 — The three allowlists agree

The page's rows, the server's `ALLOWED`, and the Makefile's `CONSOLE_TARGETS` must not drift.

```bash
a=$(grep -o "name:'[a-z0-9-]*'" console/index.html | sed "s/.*:'//;s/'$//" | sort -u)
b=$(sed -n '/^ALLOWED = {/,/^}/p' console/serve.py | grep -o '"[a-z0-9-]*":' | tr -d '":' | sort -u)
c=$(make -s targets | sort -u)
echo "actions=$(echo "$a"|wc -l|tr -d ' ') allowed=$(echo "$b"|wc -l|tr -d ' ') targets=$(echo "$c"|wc -l|tr -d ' ')"
echo "--- page actions with nothing to run (expect none):"; comm -23 <(echo "$a") <(echo "$b")
echo "--- runnable names with no target (expect ns-delete-a, ns-delete-b — see O2):"
comm -23 <(echo "$b") <(echo "$c")
```

**Pass (measured 2026-09-17).** `actions=11 allowed=11 targets=14`; the first `comm` prints
nothing; the second prints exactly `ns-delete-a` and `ns-delete-b`. `make -s targets` prints
14 names, which is the count S18's frozen checkpoint asserts.

### A3 — The read model never fails

```bash
curl -s http://127.0.0.1:8090/state | python3 -m json.tool | head -20
make -s state > /dev/null && echo "exit 0 with no cluster"
```

**Pass (measured).** `up: false`, `namespaces: []`, `containers: []`, `stateObjects: []`,
`ingressPorts: {"http": null, "https": null}`, a real `generatedAt`, exit 0. Empty means
*nothing found*, not *nothing broken* — this is the object A1's empty states render from.

### A4 — The console does not serve the repo

```bash
for p in /deploy/.env /Makefile /README.md /.git/config /console/serve.py /console/state.py; do
  printf '%-22s -> ' "$p"; curl -s -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8090$p"
done
```

**Pass (measured 2026-09-17).** `404` for every one of them — including `deploy/.env`, `/.git/config`
and the page's own Python. The whole surface is `/`, `/index.html`, `/state`, `/claim`, `/log`
and `POST /run/{name}`, and the five GETs answer `200`.

### A5 — Refusals are refusals, not accidents

```bash
curl -s -w ' http=%{http_code}\n' -X POST http://127.0.0.1:8090/run/not-a-target
curl -s -w ' http=%{http_code}\n' 'http://127.0.0.1:8090/claim?ns=voting-a&module=redis'
curl -s -w ' http=%{http_code}\n' 'http://127.0.0.1:8090/claim'
curl -s -w ' http=%{http_code}\n' 'http://127.0.0.1:8090/log?name=../../deploy/.env&offset=0'
```

**Pass (measured).** In order: `404 {"rc":1,"out":"not-a-target is not in the allowlist"}`;
`200` with `text: ""` and the kubectl error in `error` (no cluster — see **O3**);
`400 {"text":"","error":"bad ns or module"}` for a parameter that is not a name; and
`{"text":"","offset":0,"running":false}` for the traversal attempt: nothing was read.

### A6 — The server's own tests

```bash
cd console && python3 -m pytest test_serve.py -q
```

**Pass (measured 2026-09-17).** **`19 passed`**. These cover the three things A5 cannot do by
hand: the `409` on a second concurrent run, the log offset, and truncate-per-run.
Leave the server running and go to Track B.

---

## Track B — The cold path, driven from the page (Demo mode)

Cost: ~3 minutes of target time (`docs/guides/JIT-MAKEFILE-GUIDE.md` says ~3 min; **measure it
yourself — this is the number you will budget the meeting around**).

### B1 — *Start the demo* works, and its output is honest

**Steps.** Demo mode, Setup tab. Click **Start the demo** (no confirmation dialog — this one
is not destructive). Watch the log pane fill as it runs.

**Pass.** The pane opens with `$ make demo-up`, then `== 1/6` … `== 6/6`, then the app's
checks, then **`===== 17 PASS, 0 FAIL =====`** (it appears twice — the app's own report and
the root target's summary), then **`PASS: demo up - voting-a`**, then a green **`exit 0`**.

Two lines in the middle are expected and must not alarm you on stage:

- `deploy stopped before applying the app - expected while the CRD does not exist yet`
  (step 3/6 — the cluster is created, then the CRD does not exist yet by design)
- `unable to recognize "./kustomize/overlays/voting-a"` immediately before it, same reason —
  no cluster to talk to yet

While it runs, every row is disabled and the running row is highlighted. `docker ps` in
another terminal shows `jit-runner` and `jit-minio` appear on the docker network, and the three
module containers appear as `voting-a-<module>-<module>`. (The controller is a pod inside the
cluster, so it is not in `docker ps` — do not go looking for it there mid-demo.)

### B2 — The header and the summary agree with the cluster

**Pass.** LED green, pill reads **`3 claims Ready`**. Setup heading **`voting-a is running.`**
and the line under it reads **`3 claims, 3 containers. Each row runs one make target and
streams it back here.`**

Read it from the right file. `scripts/state.sh` is the read model the page runs (via
`make -s state`); it counts **only module containers**, by the exact name pattern
`-(redis-redis|postgres-postgres|pgadmin-pgadmin)$`. The names are `<ns>-<module>-<module>`,
so the three are `voting-a-pgadmin-pgadmin`, `voting-a-postgres-postgres` and
`voting-a-redis-redis` — the k3d nodes, `jit-runner` and `jit-minio` are **not** in the count,
and `docker ps | grep voting-` is not the same question (see **O10**).

```bash
make -s state | python3 -c 'import json,sys;d=json.load(sys.stdin);print(len(d["namespaces"][0]["claims"]),"claims,",len(d["containers"]),"containers")'
```

**Pass.** `3 claims, 3 containers`. If the page and this command ever disagree, the page is
right — it renders exactly this object, polled every 2 s, and this command *is* the page's
source. The 2026-09-16 run in `docs/evidence/state.log` shows the three objects verbatim if you
want to compare shapes before you have a cluster.

```bash
docker ps -a --format '{{.Names}}' | grep -E -- '-(redis-redis|postgres-postgres|pgadmin-pgadmin)$'
```

**Pass.** The same three names, in the same order the strip lists them.

### B3 — The Infrastructure tab shows the whole claim model

**Pass.**

| Element | Expected |
|---|---|
| Heading | **`3 claims across 1 namespace.`** |
| Sub | *Each one was declared by an annotation on a deployment and created before its pods could start.* |
| Namespaces row | `voting-a` · `3 claims · 3 Ready` · the block the ledger handed it (`172.19.0.100-109` for `voting-a`) |
| Group **In use** | `3 · A deployment is asking for these.` with three cards, in module order: `pgadmin`, `postgres`, `redis` |
| Each card | namespace + the claim's address; the sentence names the Deployments that reference it — `redis` *Used by **voting-app-vote** and **voting-app-worker**.*, `postgres` *Used by **voting-app-result** and **voting-app-worker**.*, `pgadmin` *Used by **voting-app-vote**.* (the annotations were realigned on 2026-09-17; the 2026-09-16 `state.log` shows the old sets, so re-read live) |
| Feed | **`Nothing yet. Phase changes show up here as they happen.`** — you have not changed anything yet |
| *Containers and state objects* (folded) | three container chips — `voting-a-redis-redis` `.100`, `voting-a-pgadmin-pgadmin` `.101`, `voting-a-postgres-postgres` `.102`, verified live 2026-09-17 — and a state-object list that is **every key under `ns/` in the bucket, not just this namespace's**: 21 of them on 2026-09-17, including `ns/voting-b/*` and leftovers from earlier test namespaces. See **O12**; keep the fold closed on stage. |

Cross-check one line of it, so you know the page is reading rather than guessing:

```bash
kubectl get infraclaim voting-a-redis -n voting-a -o jsonpath='{.status.phase} {.status.address} {.status.referencedBy}{"\n"}'
```

**Pass.** The phase and address match the card, and `referencedBy` names the same Deployments
the card's sentence does.

### B4 — A claim card opens the real object

**Steps.** Click the `redis` card, then click `postgres`, then click `postgres` again.

**Pass.** The panel **The claim itself** appears under the *Namespaces* block with the line
*Owned by the **Namespace**, not the Deployment — which is why a rollout does not touch it. The
**finalizer** is what holds a namespace in Terminating if a destroy fails.*, then the YAML with
`ownerReferences`, `finalizers`, `phase` and `referencedBy` bolded. Only one card wears the
blue ring at a time; clicking the open one again closes the panel. `expiresAt` is **absent** on
a Ready claim — nothing is on a clock yet. `redis` and `postgres` each hold **two** Deployments
(`voting-app-vote` + `voting-app-worker`; `voting-app-result` + `voting-app-worker`) and `pgadmin`
holds one (`voting-app-vote`) — which is the whole of the refcount rule you will lean on in
Track C.

```bash
make -s claim NS=voting-a MODULE=redis | head -20      # the same YAML, same source
```

**Pass.** Identical (the panel is this command).

### B5 — The Voting app tab serves the real thing

**Steps.** Open **Voting app**. Cast a vote in the left pane, watch the right one.

**Pass.** Two panes, labelled **`vote.localhost:8081`** and **`result.localhost:8081`** — host,
scheme and port all read from the cluster's Ingress and the load balancer, none typed in — and
**no certificate step is needed**. Verified live on 2026-09-17: this Ingress declares no TLS, so
`state.sh` reports `tls: false` and the page builds an `http://` URL on the published `:8081`.
Both panes answer `200` while the demo is up.

Worth knowing, because `README.md` and the page's own Guide tab both describe a self-signed
certificate and a blank pane until you accept it. The page only shows that note when an Ingress
*does* declare TLS (`anyTls` in `index.html`), and none here does. The HTTPS route does work —
`https://vote.localhost:8082/` answers `200` on Traefik's own self-signed cert — but **the page
will never load it**, so do not spend prep time pre-accepting a certificate for a URL the console
does not use.

No namespace switcher (there is only one namespace, so it is hidden on purpose). Below the panes,
three chips carrying the module names and addresses, and a line about pgAdmin's own host port.

**Then vote.** Click *Cats* (or *Dogs*) in the vote pane, and watch the result pane.

**Pass.** The vote returns `200` and the tally on the result pane increases within 5 seconds
(this is R6). This is the whole system in one gesture: the pod talked to Redis through a
Service with no selector, the worker wrote to Postgres in a container outside the cluster, and
the result page read it back.

### B6 — The frozen gate still passes

```bash
make check STEP=18          # S18 is the console's own checkpoint; needs the live cluster
git status --short          # what this run dirtied (see O4)
```

**Pass.** `make check STEP=18` prints 12 `ok:` lines, then a `PASS` line and exits 0 (recorded
in `docs/evidence/s18-stage-g-gate.log` on 2026-09-16 — re-run it rather than trusting that
file). It is not a console button: `make check` is outside the allowlist on purpose.

---

## Track C — The 3-minute executive demo, click by click

Rehearse this with a timer. What follows is the sequence that the page is built for; the
timings are targets, not measurements.

| t | Do | Say | What they see |
|---|---|---|---|
| 0:00 | Setup tab, Demo mode, page freshly loaded | "One namespace, one annotation on a Deployment. Everything else you are about to see is the system reacting to that annotation." | `Nothing is running yet.` |
| 0:15 | Click **Start the demo** | "It is starting the cluster, the control plane, and the app — for real, from nothing." | the log streaming; 17 PASS 0 FAIL at the end |
| 0:40 | Switch to **Infrastructure** while it runs | "The annotations ask for redis, postgres and pgAdmin; each Deployment names the ones it uses. Nothing in the app knows an IP address." | claims appearing, then `In use` |
| 1:30 | Back to Setup when the log ends | "Three containers, outside the cluster, each with an address from a block the namespace owns." | `3 claims Ready`, `17 PASS, 0 FAIL`, `exit 0` |
| 1:45 | Click the `redis` card, then **Voting app**, cast a vote | "That is the app using the infrastructure that did not exist two minutes ago." | the tally moving |
| 2:15 | **Delete the deployment** | "The pods are gone. The infrastructure is not — and a clock has started." | `Nothing was destroyed. A clock started.`, LED `1 on the clock`, a live countdown |
| 2:35 | Point at the countdown and the feed | "Ten minutes to change your mind. That window is a field in the annotation, not a hard-coded policy." | `9:5x` counting down; feed lines `Ready → Orphaned` |
| 2:50 | **Redeploy inside the window** | "Same container, same data, nothing re-provisioned." | back to `Ready`, countdown gone |
| 3:10 | **Delete the namespace** → confirm **OK** | "And the hard path: the clock is ignored, everything goes at once." | LED `No claims`; heading `Control plane up. Nothing has asked for infrastructure yet.` — **not** `Nothing is running yet.` (see C2) |
| 3:30 | **Delete everything** → confirm **OK** | "That is the whole lifecycle, and the laptop goes home clean." | `Nothing is running yet.`, pill `Nothing running` |

Three things in that table are the demo, and each one is a claim the page makes visibly:

1. **The countdown is 10 minutes, not 2.** `demo-undeploy` deletes only the *vote* Deployment,
   so `redis` and `postgres` stay `Ready` — `worker` still references both, and `result`
   references `postgres` — while `pgadmin`, the one module `vote` leases alone, goes `Orphaned`.
   Expect **two cards under *In use* and one under *On the clock***, not three. Say so before it
   happens and it looks designed; notice it live and it looks broken.
2. **The feed** is the only part of the page that reports *change* rather than *state*. It
   starts empty on every load and fills with `Pending → Ready`, then `Ready → Orphaned`. If you
   want the feed to have something in it, be on the page before you click.
3. **`Nothing was destroyed. A clock started.`** is the heading the page switches to when it
   sees an `Orphaned` claim. It is the sentence to end on.

### C1 — Confirm the window is 10 minutes before the room is in it

`make jit-verify` (Track D) rewrites the annotations to **2m** and never puts them back, so a
testing run the day before leaves the demo with a two-minute clock.

```bash
kubectl get deployment voting-app-vote -n voting-a \
  -o jsonpath='{.metadata.annotations.jit\.infra/redis}{"\n"}'
```

**Pass.** The annotation contains **`"softDeleteTTL":"10m"`**. If it says `2m`, run **Start the
demo** again before the meeting — the cold path re-applies the overlay from the repo, which is
the 10m in `app/kustomize/base/vote-deployment.yaml`.

**If the clock does reach zero on stage,** the containers are destroyed. That is the design
working, not a failure — say so, then rebuild with **Start the demo** (~3 min) or fall back to
the deck. Do not invent a fix in front of the audience.

### C2 — Know which closing screen you are looking at

After **Delete the namespace** the claims and their containers are gone, but the control plane
is not: `up` is asked *of the cluster* — the API answers, the InfraClaim CRD is served and the
controller has an available replica (`scripts/state.sh`, `stack_is_up`) — so it stays `true`.
The page therefore reads **`No claims`** on the pill and *Control plane up. Nothing has asked
for infrastructure yet.* on Setup — **not** `Nothing is running yet.`, which only appears once
the plane is gone.

**Pass.** You can name which of the two screens you are on, and why, without looking it up.
**Only Delete everything returns the page to `Nothing is running yet.`** — which is why the
demo script above ends on it.

---

## Track D — The Testing path and the full lifecycle

Cost: ~15 min. **Run this before Track C, not after**, and re-run Track B afterwards — D3
below leaves the cluster at a 2-minute clock with `voting-b` deleted.

### D1 — The mode switch changes the buttons, not the cluster

**Steps.** With the demo running, click **Testing**.

**Pass.** Seven rows: *Set everything up*, *Start the control plane*, *Check the app works*,
*Check the JIT behaviour*, *Delete voting-b*, *Shut the JIT plane down*, *Delete everything*.
The note under the list now explains `voting-b` and hard deletes. Switching back to **Demo**
changes the list again and leaves the cluster exactly as it was (`make -s state` proves it).

### D2 — *Set everything up* (both namespaces)

**Steps.** Click **Set everything up**, then **Check the app works**.

**Pass.** The cold path runs once per namespace and ends **`PASS: demo up - voting-a voting-b`**,
`exit 0`, with two sets of `===== 17 PASS, 0 FAIL =====`. LED reads **`6 claims Ready`**, Setup
heading **`voting-a and voting-b are running.`**, and the **Voting app** tab now shows the
`voting-a | voting-b` switcher, with `vote-b.localhost:8081` / `result-b.localhost:8081` for the
second namespace.

**Check the app works** is `make verify NS=voting-a`: expect the same `17 PASS, 0 FAIL` and
`exit 0`. It is the root target, so it **exits non-zero if any R-check fails** — a red `exit 1`
here is a real finding, not noise.

### D3 — *Delete voting-b* (do this before D4)

**Steps.** Click **Delete voting-b** and confirm **OK**.

**Pass.** Its three containers go at once — `docker ps --format '{{.Names}}' | grep '^voting-b-'`
returns nothing while the three `voting-a-<module>-<module>` containers keep running — and the
page drops to `3 claims Ready`.
No countdown appears: a Ready claim carries no `expiresAt`, so the clock was never armed and
"it went immediately anyway" is a real assertion. This is J8's shape.

### D4 — *Check the JIT behaviour* (J1–J11)

**Steps.** Click **Check the JIT behaviour**. Budget ~5–8 minutes: J6 has to wait out a
two-minute TTL.

**Pass.** Lines `J1` … `J11`, then **`===== 11 PASS, 0 FAIL =====`** and `exit 0`.

**Know what it just did to your cluster** — it is the one button that changes state you may
have been relying on:

- it **resets both namespaces first** (claims, containers and volumes for both), so anything
  you had deployed is gone and rebuilt;
- it **forces `softDeleteTTL` to 2m** (see C1);
- it **deletes `voting-b` itself** at J8;
- it leaves `voting-a` deployed and `Ready` again at J9 — the console will read `3 claims Ready`.

### D5 — *Shut the JIT plane down*, then *Delete everything*

**Pass after jit-down.** The cluster and the app stay, but the page behaves as if nothing were
running: pill **`Nothing running`**, heading **`Nothing is running yet.`**, Infrastructure
**`No infrastructure yet`**, app tab **`The app isn't up`**. That is correct and not a bug —
`up` asks the cluster for the *controller's* available replicas (`scripts/state.sh`,
`stack_is_up`), and jit-down has just deleted it. The app's pods sit in
`CreateContainerConfigError` for the same reason (the `jit-*` Secrets are gone) — outside the
console, and expected. Use this drill to learn the screen, because on stage it looks like the
console lost the cluster.

**Getting back from here is Track B, not a warm re-apply.** A Deployment that already exists
produces no create event, so clicking *Start the control plane* on its own will not bring the
claims back; the cold path will (`scripts/demo-up.sh`, "Why step 1").

**Pass after destroy.** ~1 minute; the page returns to `Nothing is running yet.`,
`k3d cluster list` shows no cluster, and `docker ps` shows no `jit-*` or `voting-*` containers.

---

## Track E — Failure drills: the things that actually happen on stage

Run each one deliberately, at least once. The point is that you have already seen the screen
you are about to be looking at.

### E1 — A second window clicks the same button

The page disables its own rows while a run is in flight, but that guard is per tab. A second
window — a leftover tab, a presenter view, a phone on the same Wi-Fi — can click during a run.

**Pass.** The second window logs a red **`exit 1`** and the server's answer
`another run is in progress`; the first run is unaffected. **Recovery:** wait for the first run,
or close the second window. Before the demo, close every other console tab.

### E2 — The console process dies

```bash
# with the page open and a run deliberately started, Ctrl-C the server
docker ps --format '{{.Names}}'      # the make child is NOT killed with the server
k3d cluster list
```

**Pass.** The page keeps showing the last good state (polls fail silently), and the next click
logs **`could not reach the console process — is it still running?`**. The `make` child keeps
going — this is a documented rough edge, not a surprise, and the reason the drill exists:
**check `docker ps` and `k3d cluster list` before starting anything again**, then recover with
**Start the demo** once a fresh server is up.

### E3 — The cluster disappears behind the page

```bash
k3d cluster delete voting-app
```

**Pass.** Within two seconds the pill reads **`Nothing running`**, the heading
**`Nothing is running yet.`**, Infrastructure goes back to **`No infrastructure yet`** and the
app tab to **`The app isn't up`** — because `up` is "the cluster answers and the controller has
a replica" (`scripts/state.sh`, `stack_is_up`), and with the cluster gone it is false.
`jit-runner` and `jit-minio` are still running on the docker network, which is why this
distinction is worth rehearsing: the page is answering about the *plane*, not about containers.

**Recovery.** **Start the demo** — `scripts/state.sh` never fails, so the page correctly
reports *nothing found* rather than *nothing broken*.

### E4 — If a pane is blank anyway

**Pass / resolution.** With the demo up the panes should render with no prompt at all (B5).
If one is blank, open the URL the pane label shows — `http://vote.localhost:8081/` — in a tab.
If that renders and the pane does not, the console is the suspect, not the app; if it does not
render either, the app is. Each pane's **Open** link does this for you. The page's own
"self-signed certificate" fallback only appears for a TLS Ingress, which this project does not
declare, so seeing it at all is worth writing down as a finding.

### E5 — The port is already taken

```bash
lsof -nP -iTCP:8090 -sTCP:LISTEN        # usually a console left over from an earlier session
pkill -f 'console/serve.py'
```

**Pass.** With no listener, `python3 console/serve.py` prints
`console on http://127.0.0.1:8090   (Ctrl-C to stop)`. The port is a constant in `serve.py`
(`PORT = 8090`) — there is no flag, so free the port rather than hunting for one.

### E6 — You reload the page mid-demo

**Pass.** You are back on Setup in **Demo** mode (mode is client-side and not remembered), the
log pane is empty with its placeholder, and every claim, address and countdown is right back
within two seconds. The finished run's output is still on disk:

```bash
ls -l docs/evidence/console-*.log       # one file per action name, rewritten on each run
```

**Know this before the room does**: a refresh costs you the log pane and the feed, not the state.

### E7 — An R-check fails in front of everyone

`make verify` exits non-zero and writes red lines. **Say what is true** — the app's own checks
failed, and the JIT behaviour is a separate question — then check the report:

```bash
grep -E 'FAIL|=====' app/.workflow/verify.md | tail -20
```

**Pass.** You can name the failing R-check from that file without leaving the page.

### E8 — Everything looks right and the app is empty

The four known causes and their evidence trail are in
[`JIT-MANUAL-GUIDE.md`](JIT-MANUAL-GUIDE.md) §15 — the ones we have hit: the database is
`voting`, not `votingdb`; a second pgAdmin needs `http_port` 5051 (`voting-b` sets it);
a Postgres volume that outlived its container rejects the new password. Keep that table open
on the second screen during a rehearsal.

---

## Observations — found while writing this plan

Verified today against the code, the running endpoints or the tests. **None of them blocks the
demo.** They are here so that none of them is discovered in the room.

| # | Observation | Why it matters |
|---|---|---|
| **O1** | Demo mode shows **five** rows, but `console/README.md`'s table lists four buttons and the Guide tab says "four steps in order". The fifth is *Delete everything*. | Wording only. Worth a one-line fix if management reads the README during Q&A — the page is right, the prose is short by one row. |
| **O2** | `ns-delete-a` / `ns-delete-b` are the only allowlist names with no matching make target — both run `make ns-delete`. A2's parity check reports them by design. | It is the single exception to README's "keep the action name and the target name identical" rule, and it is necessary: one target, two namespaces. Do not "fix" it. |
| **O3** | `GET /claim` with no reachable cluster answers `200` with raw kubectl output in `error`, which the panel prints verbatim. | Only reachable if the cluster dies while a card is selected. Cosmetic; a cleanup candidate, not a demo risk. |
| **O4** | Every **2 seconds** the page polls `/state`, which runs `make -s state`, **which appends a full JSON line to `docs/evidence/state.log`** — a tracked file (`Makefile`'s `state` target pipes through `tee -a`; `serve.py`'s `STATE` is `make -s state`). A 10-minute demo with the page open adds roughly 300 lines to it, on top of the per-run `docs/evidence/console-<action>.log` rewrites (`console-demo-up.log` is 23,640 bytes from a 15 Sep run). | Measured today: my two `GET /state` calls added exactly two lines. So a rehearsal or a demo leaves `git status` dirty with evidence churn, and no click is needed for it. Decide *before* the meeting whether to commit it or ignore it — do not discover it during the commit after. |
| **O5** | `docs/evidence/console-demo-soft.log` (64 B, 12 Sep) is tracked but no `demo-soft` action exists in `ACTIONS`, `ALLOWED` or `CONSOLE_TARGETS`. | A leftover from a cut button. Harmless; delete it if you are tidying. |
| **O6** | **Inferred, not observed:** if a run is refused (409) after the page's log pump has started, `/log` can hand back the *previous* run's content for that name — I measured 23,638 readable bytes at offset 0 for `demo-up`. Confirming it needs two windows and a slow target. | The mitigation is E1's rule: one window per target. Listed because "the log started with someone else's output" is exactly the kind of thing that looks like a console bug on stage. |
| **O7** | With nothing running, `/state` returns `ingressPorts: {http: null, https: null}` and the App tab is hidden while `up` is false. | Verified correct — nothing tries to build a URL from nulls. Leave it alone. |
| **O8** | The 2 s poll is not free: each one shells out to `kubectl` (namespace, CRD, controller replicas, claims, Ingress), `docker ps`/`inspect`, and a SigV4 listing of the MinIO bucket (`scripts/state.sh`). | Fine for a demo; worth knowing if a laptop is left open on the page all day, and the reason O4's churn happens at all. |
| **O9** | `serve.py`'s `do_GET` comment names `app/kustomize/postgres-secret.env` as a file it must never hand out. That path is not in the tree — the live secret is `deploy/.env`. | The refusal is correct either way (A4 proves it); only the comment has drifted. Do not use the comment as a file inventory. |
| **O10** | **`console/state.py` is not the read model.** The page's `/state` runs `make -s state` → **`scripts/state.sh`**. `state.py` is a superseded standalone implementation, restored deliberately as a reference (`memory-bank/journal/2026-09-13.md`, and `README-BAK.md` calls it "the earlier standalone read model"). The two disagree on both of the things you would look it up for: containers (any name starting `jit-` or containing `voting-`, which is 8 on a demo host including the k3d nodes — versus only the three module containers) and `up` (any namespace or running container — versus the cluster answering, the CRD being served and the controller having a replica). | Anyone who reads `state.py` to predict what the page shows gets it wrong. I did, while writing B2, and only `docs/evidence/state.log` caught it. Keep it if it is useful, but its docstring should name the file that superseded it. |
| **O11** | The Setup sub-line says `, one on the clock.` whenever *any* claim is `Orphaned`, however many there are (`console/index.html`, `render`). | Since the 2026-09-17 realignment only `pgadmin` orphans after **Delete the deployment**, so the pill and the sub-line agree and this is invisible in the single-namespace flow. Still latent: two orphans at once (e.g. `demo-undeploy` in both namespaces) show `2 on the clock` against *one*. Cosmetic and one word wide; a presenter pointing at both would look worse than the bug does. |
| **O12** | The folded *Containers and state objects* strip lists **every** `ns/...` state object in the MinIO bucket, not this namespace's: 21 keys on 2026-09-17, including `ns/voting-b/*` (which Demo mode never creates) and leftovers from historic test namespaces (`ns/default/*`, `ns/s13-a/*`, `ns/hatch-leak/*`, …). | It is inside a `<details>`, closed by default, so a demo that never expands it is unaffected — keep it closed. Pruning the bucket would fix the display, but that is deleting state, so treat it as a decision rather than tidying. |

---

## Demo-day run sheet

**The evening before**

1. Track D (optional, ~15 min) — it resets both namespaces and arms a 2m clock.
2. Track B **last**, so the host ends the day in the 10m demo state with `voting-a` running.
3. Confirm B5's pane URLs read `http://…:8081` — no certificate step is needed (verified 2026-09-17).
4. Settle O4: commit or ignore the evidence churn.
5. Do **not** run `jit-verify` after this point (C1).

**T-60 minutes**

```bash
make demo-up                      # ~3 min; it destroys first, so it is safe from any state
make check STEP=18                # 12 ok lines, PASS — the console's own frozen gate
```

`make demo-up` is itself the reset — it runs the destroy, the deploy, `jit-up` and then deploy
+ verify per namespace. Do not run `make destroy` first and do not skip the cold path.

Then walk Track B once, click-verify B2–B5, and leave the cluster **up**.

**T-10 minutes**

- Open `http://127.0.0.1:8090` on the display you are presenting from, freshly loaded, Demo
  mode, Setup tab — a fresh load means the feed is empty and will capture the transitions.
- Close every other console tab and window (E1).
- Keep two terminals visible: `docker ps --format '{{.Names}}\t{{.Status}}'` and
  `kubectl get infraclaims -A`.
- Keep the fallback open in another tab: `docs/how-it-works-presentation.html` and
  `docs/deletion-lifecycle.html` are single files with no server behind them. If the host
  misbehaves, you can present the design from the deck and lose nothing.

**During:** Track C. **After:** *Delete everything* if the laptop goes home with you, or leave
it up if there is a second session — and remember that leaving it up means the clock in C1 is
still ticking only if something is `Orphaned`.

---

## Record sheet

Copy this table into your notes and fill it in on each rehearsal. "First run" is the state the
host was in; write the actual value when it differs from the plan.

| id | Scenario | Run 1 | Run 2 | Notes / what actually happened |
|---|---|---|---|---|
| A1 | Page loads with nothing behind it | | | |
| A2 | Three allowlists agree | | | |
| A3 | The read model never fails | | | |
| A4 | The console does not serve the repo | | | |
| A5 | Refusals are refusals | | | |
| A6 | `19 passed` | | | |
| B1 | *Start the demo* end to end, `17 PASS, 0 FAIL` | | | |
| B2 | Header and summary agree with the cluster | | | |
| B3 | Infrastructure tab complete | | | |
| B4 | A card opens the real object | | | |
| B5 | The app tab, the panes, a real vote | | | |
| B6 | `make check STEP=18` → PASS | | | |
| C1 | The window is 10m, not 2m | | | |
| C2 | The closing screen (`No claims`, not `Nothing running`) | | | |
| C | The 3-minute run-through, timed: ____ | | | |
| D1 | Mode switch changes buttons only | | | |
| D2 | *Set everything up*, both namespaces | | | |
| D3 | *Delete voting-b* — bounded hard delete | | | |
| D4 | *Check the JIT behaviour* → 11 PASS | | | |
| D5 | *jit-down*, then *destroy* | | | |
| E1 | Second window during a run | | | |
| E2 | Console process killed mid-run | | | |
| E3 | Cluster deleted behind the page | | | |
| E4 | Blank panes resolved | | | |
| E5 | Port 8090 freed | | | |
| E6 | Reload mid-demo | | | |
| E7 | A failing R-check read from the report | | | |
| E8 | The empty-app checklist located | | | |

**Demo-ready:** rehearsal ____ on ____________, tracked findings ____________, agreed with
____________. Signed off by ____________.
