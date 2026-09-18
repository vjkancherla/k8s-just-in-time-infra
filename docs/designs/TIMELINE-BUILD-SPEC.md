# Build spec: the timeline in the console

A task for an implementer who has the repository but not the conversation that
produced this. Read it end to end before writing anything.

The data source already exists: `make timeline` prints the JSON described in §1,
and `scripts/timeline.sh` produces it. **Nothing in this task changes that
script's output shape.** The work is a `/timeline` endpoint in
`console/serve.py`, a view in `console/index.html`, and tests.

---

## 0. The rules this project works under

These are not negotiable and the review will check them.

- **The console holds no state and computes nothing.** Every number it shows
  comes from a make target reading the same sources the frozen checkpoints read.
  The one exception is arithmetic on values it was given: the existing countdown
  subtracts `expiresAt` from the clock, and this feature subtracts `t0` from an
  event time. Deriving a *fact* the payload did not state is out of bounds.
- **`console/index.html` is one file.** No build step, no framework, no CDN, no
  second file to serve. `serve.py` serves that page and nothing else, because
  `deploy/.env` and `app/kustomize/postgres-secret.env` live under the repo root.
- **Three declarations must agree**: `CONSOLE_TARGETS` in the root `Makefile`,
  `ALLOWED` and the upper-case command constants in `serve.py`, and `ACTIONS` in
  `index.html`. `console/test_console.py` enforces this.
- **Plain language in the interface.** No jargon on a label where a sentence
  would do. Existing examples: a claim card says "Used by vote and worker", not
  "referencedBy: [vote, worker]".
- No em dashes in any user-facing text.

---

## 1. The payload

`make timeline` prints one JSON object:

```json
{
  "up": true,
  "generatedAt": "2026-09-16T15:05:00Z",
  "t0": "2026-09-16T14:59:52.446643192Z",
  "events": [
    { "t": "2026-09-16T14:59:52.446643192Z",
      "lane": "controller",
      "kind": "controller.saw",
      "subject": "voting-a/voting-app-result",
      "source": "kubectl logs --timestamps deploy/jit-controller" }
  ]
}
```

When nothing is running it prints `{"up": false, "t0": null, "events": []}` and
exits 0. Handle that first; it is the state the page is in most often.

**Lanes**: `controller`, `runner`, `container`, `deployment`, `pod`.

**Kinds**: `controller.saw`, `ipam.allocated`, `claim.created`, `claim.ready`,
`runner.call`, `container.created`, `container.started`, `container.stopped`,
`secret.created`, `service.created`, `deployment.applied`, `pod.created`,
`pod.started`.

Treat both lists as open. An unknown lane or kind must render as itself rather
than being dropped or crashing the view.

**Precision differs by source and this matters.** Events from container
inspection and controller logs carry nanoseconds. Events from Kubernetes object
timestamps (`claim.created`, `secret.created`, `pod.created`, `pod.started`,
`deployment.applied`, `service.created`) are truncated to the second. A
second-granularity event can therefore compute to a small negative offset from
`t0`, because `t0` has nanoseconds and the event's true time was rounded down.
§4 says what to do about it.

---

## 2. The endpoint

In `console/serve.py`, beside `STATE` and `CLAIM`:

```python
TIMELINE = ["make", "-s", "timeline"]
```

It must be an upper-case module constant holding the make invocation.
`test_console.py` derives the set of "reads that are not buttons" by scanning
for exactly that shape, and a command inlined in the handler will fail that test.

Add a `/timeline` branch to `do_GET`, in the same shape as `/state`:

```python
if path == "/timeline":
    r = subprocess.run(TIMELINE, capture_output=True, text=True, cwd=ROOT)
    try:
        return self.send_json(json.loads(r.stdout))
    except Exception as e:
        print(f"!!! make timeline did not return JSON: {e}", flush=True)
        if r.stderr.strip():
            print(r.stderr.strip(), flush=True)
        return self.send_json({"up": False, "t0": None, "events": []})
```

Add `timeline` to `CONSOLE_TARGETS` in the root `Makefile` if it is not there.
Do **not** add it to `ALLOWED` and do **not** give it a row in `ACTIONS`: it is a
read the page makes for itself, like `state` and `claim`, not a button.

**Never poll it.** `/state` is polled every two seconds; `/timeline` shells out
to `kubectl logs` and `docker inspect` and is far more expensive. Fetch it when
the person asks for it, and again only when they ask again.

---

## 3. Where it goes in the page

A fourth tab, **Timeline**, after **Voting app** and before **Guide**.

Follow the existing pattern exactly, which is visible in the Infrastructure tab:

- a `<button role="tab" data-view="timeline">` in `.seg.mid`
- a `<div class="view" id="view-timeline">` with two children: an empty state
  (`id="timelineEmpty"`, hidden when there is data) and the content
  (`id="timelineLive"`, hidden when there is not)
- the tab button gets the `sleeping` class when the stack is down, like the
  other two

Fetch on first visit to the tab and cache the result. Add a **Refresh** button,
since the interesting moment is right after a run. After any action completes in
`run()`, mark the cached timeline stale so the next visit refetches.

The empty state says what to do: nothing has been provisioned yet, start the demo.

---

## 4. Rendering

### 4.1 The window

**Do not draw every event.** The payload covers the whole life of the objects
that still exist, so a capture taken after a verify run contains the provisioning
sequence, then a Postgres restart from R9 at +114s, a worker scaled down and back
by R8, and a Deployment recreated by an undeploy and redeploy at +287s. Drawn
together they compress the part that matters into the first fifteen percent of
the width.

Default to the **provisioning window**: `t0` to the last `claim.ready`, plus two
seconds. Show everything after it as a single collapsed row, "14 later events",
that expands on click.

If there is no `claim.ready` at all, fall back to the full range.

### 4.2 Lanes

Five lanes is one too many. `deployment` and `pod` are the same story told twice
and neither is about the infrastructure. Draw three rows:

| Row | Lane or lanes | What it shows |
|---|---|---|
| Controller | `controller` | saw the annotation, allocated an address, created a claim, marked it Ready |
| Runner | `runner` | the call across the boundary |
| Infrastructure | `container` | the container appearing and starting |

Put `deployment` and `pod` behind the same disclosure as the later events, or
leave them out. The app's own pods are not what the timeline is for.

### 4.3 The drawing

Inline SVG, sized by `viewBox`, no library. The existing page has hand-authored
SVG glyphs to copy the style from.

- Horizontal axis is time from `t0`, linear. Tick marks every 10s with a label.
- One row per lane, labelled at the left.
- Each event is a dot on its row at its offset, with the subject as a label where
  there is room and always as a `<title>` for hover.
- **Nanosecond events are dots. Second-granularity events are one-second bands.**
  A dot claims a precision the source does not have. Clamp a negative offset to
  zero and draw the band from 0 to 1s.
- Colour carries meaning or is absent. The page's variables are `--blue` for
  attention, `--green` for ready, `--amber` for waiting, `--ink-3` for quiet.
  `claim.ready` in green, everything else quiet, is enough.

Above the drawing, one sentence in plain language stating the headline the data
supports, for example: **"Annotation to all infrastructure ready: 48 seconds."**
Compute it as the offset of the last `claim.ready`. Say "not yet ready" when
there is none.

### 4.4 The finding worth surfacing

In the sample data, redis is ready at 17.1s, postgres at 29.8s, pgadmin at 48.1s,
and no two provisions overlap. Provisioning is serialised, roughly twelve to
eighteen seconds each.

This is the most interesting thing in the payload and it is invisible everywhere
else in the console. Under the drawing, list each module with the time from its
`claim.created` to its `claim.ready`, and state whether any two overlapped.

Compute "overlapped" from the intervals in the payload. Do not assume the answer
is no; it is a property of the data, not a fact about the system.

### 4.5 A table underneath

Every event in the window: offset, lane, kind, subject. Monospaced, the way the
claim YAML is on the Infrastructure tab. This is what someone reads when the
drawing has told them something is odd. Include `source` as a hover title, since
it says which command produced the row and is how a wrong number gets traced.

---

## 5. Tests

### `console/test_console.py`
Should pass unchanged once `TIMELINE` is a module constant. Run it first.

### `console/test_browser.py`
Add fixtures to the `states()` function and tests to `Page`. Fixtures must be
built inside that function so their timestamps are relative to now; a fixture
built at import time goes stale mid-suite, which is a bug this suite has already
had once.

The timeline needs its own fixtures, because `states()` currently returns
`/state` payloads. Add a parallel `timelines()` function and a `serve_timeline(name)`
helper that points `serve.TIMELINE` at a file, the way `serve_fixture` points
`serve.STATE`.

Cover at least:

- **down**: the empty state shows, the live view does not
- **a normal run**: three modules, serial, one `claim.ready` each. Assert the
  headline sentence contains the right number of seconds, and that three rows
  are drawn
- **contaminated**: the same run plus events at +114s and +287s. Assert the
  default view ends near the last `claim.ready` and the later events are
  collapsed behind a control
- **no `claim.ready`**: provisioning failed or is still running. Assert it does
  not crash and says so
- **second-granularity only**: every event truncated to the second, some
  computing negative. Assert nothing is drawn at a negative offset
- **an unknown lane and an unknown kind**: assert they render rather than
  disappear
- **overlap**: a fixture where two provisions genuinely overlap, asserting the
  overlap claim flips. This is the test that stops §4.4 becoming a hardcoded
  sentence

Add the timeline tab to the existing `test_exactly_one_view_is_visible_at_a_time`
and to the sweep in `test_no_javascript_errors_anywhere`.

### Manual check
`python3 console/test_browser.py --shots` renders every state across every tab.
Add the timeline tab to the loop in `screenshots()`.

---

## 6. Done means

- `python3 console/test_serve.py` passes
- `python3 console/test_console.py` passes, including the reachability test
  finding `TIMELINE` on its own
- `console/.venv/bin/python console/test_browser.py` passes, with the new tests
- `--shots` shows a readable timeline for the normal run and a sensible empty
  state for the down case
- `make -s timeline` is unchanged: no field added, renamed or removed

## 7. Do not

- Poll `/timeline`
- Add a `timeline` row to `ACTIONS` or to `ALLOWED`
- Read `kubectl` or `docker` from `serve.py` or from the page
- Introduce a charting library, a build step, or a second served file
- Compute a duration the payload did not contain, beyond subtracting two
  timestamps it did contain
- Draw a second-granularity event as though it were precise
