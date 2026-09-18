# Testing the console

Three suites, each answering a different question. Two need nothing installed.
The third needs a browser and is the one that saves you an afternoon.

| Suite | Question it answers | Needs |
|---|---|---|
| `test_serve.py` | Does the server behave? | nothing |
| `test_console.py` | Do the Makefile, the server and the page still agree? | nothing |
| `test_browser.py` | Does the page render correctly, in every state? | Playwright |

---

## 1. The two that need nothing

```bash
cd ~/Downloads/Devops-Projects/k8s-just-in-time-infra
python3 console/test_serve.py
python3 console/test_console.py
```

Both should print `OK`. Together they take about three seconds.

`test_serve.py` starts the real server on a spare port and talks to it over
HTTP: the allowlist refuses unknown names, the repo is not served (`deploy/.env`
must 404), the log offsets work, two runs cannot overlap, and `/state` degrades
to `up: false` rather than raising.

`test_console.py` reads the Makefile, `serve.py` and `index.html` as text and
checks they agree on every name, then runs `make state` once and checks the
payload carries every field the page draws. This is the suite that catches the
kind of bug that has actually happened: a target renamed in one place, a field
dropped from the read model.

> `test_console.py` runs `make state` for real, so it reflects whatever your
> cluster is doing. That is deliberate: it passes with the stack up or down, and
> fails if the payload has the wrong shape either way.

---

## 2. Setting up the browser suite

Once, on this machine. Homebrew has no formula for the Python binding, so this
comes from pip, and macOS will refuse a bare `pip install` into the system
Python.

```bash
cd ~/Downloads/Devops-Projects/k8s-just-in-time-infra

python3 -m venv console/.venv
console/.venv/bin/pip install --upgrade pip
console/.venv/bin/pip install playwright
console/.venv/bin/playwright install chromium
```

The browser downloads to `~/Library/Caches/ms-playwright`, outside the repo,
about 150 MB.

Add the virtualenv to `.gitignore`:

```
console/.venv/
console/shots/
console/fixtures/
```

**If you would rather not download a browser**, Playwright can drive the Chrome
you already have. Skip the `playwright install` line and change one line in
`console/test_browser.py`:

```python
cls.browser = cls.pw.chromium.launch(channel="chrome")
```

The trade-off is that your tests then track your Chrome version rather than a
pinned one.

---

## 3. Running the browser suite

```bash
console/.venv/bin/python console/test_browser.py
```

Twenty-two tests, no cluster required, nothing destructive. Expect it to take
thirty to forty seconds.

**How it works, because this is the part that makes it cheap.** `serve.py` gets
its data by running a command. The tests point that command at a fixture file
instead of `make state`, so the console can be put into any state instantly:

| Fixture | The state it puts the console in |
|---|---|
| `down` | no cluster at all |
| `plane-only` | control plane up, nothing has claimed anything |
| `ready` | three claims, all Ready, app routed |
| `orphaned` | two claims counting down, redis still Ready |
| `expiring` | a claim with four seconds left |
| `failed` | a claim the runner could not provision |
| `pending` | a claim waiting on the runner |
| `two-namespaces` | voting-a and voting-b together |
| `no-routes` | claims up, no Ingress for the app |
| `no-port` | routes exist but nothing is published |

Producing `failed` or `expiring` in a real cluster is slow or awkward. Here they
are a JSON file.

Every entry in `ALLOWED` is replaced with `python3 -c "print('ran demo-up')"`
for the duration, so no test can start or destroy anything.

---

## 4. The part you will use most

```bash
console/.venv/bin/python console/test_browser.py --shots
```

Thirty PNGs in `console/shots/`, one per state per tab. Open the folder in
Finder, set it to large icons, and look at every permutation of the console at
once.

This is the manual testing you are trying to avoid, done in about fifteen
seconds, and it catches layout problems that no assertion will: text that wraps
badly, a card that collapses, a pane that crowds its neighbour.

Run it after any change to `index.html`.

---

## 5. Making it one command

Add to the root `Makefile` (not to `CONSOLE_TARGETS` - the console must not be
able to run its own tests):

```make
.PHONY: console-test
console-test: ## Run the console's suites: server, contract, and browser if installed
	@python3 console/test_serve.py
	@python3 console/test_console.py
	@if [ -x console/.venv/bin/python ]; then \
		console/.venv/bin/python console/test_browser.py; \
	else \
		echo "skipping the browser suite - see docs/guides/TESTING-THE-CONSOLE.md §2"; \
	fi

.PHONY: console-shots
console-shots: ## Render every console state to console/shots/ for review
	@console/.venv/bin/python console/test_browser.py --shots
```

---

## 6. When something fails

**A `Declarations` test fails.** Three files disagree about a name. The message
says which one is missing where. Fix the name in the file that is wrong, not in
the test.

**A `Contract` test fails.** `make state` stopped emitting something the page
draws. Run `make -s state | python3 -m json.tool` and compare against the shape
in [`console/README.md`](../console/README.md).

**A browser test fails on a selector.** The page changed an id or a class and
the test still looks for the old one. Update the test.

**A browser test fails on a number** (`3 claims Ready` became `2 claims Ready`).
Either the fixture changed or the page counts differently. Check the fixture
first; they are written to `console/fixtures/` on every run and are readable.

**Everything fails at import.** You ran the browser suite with the system
`python3` rather than the venv.

---

## 7. What is not tested, and why

The page's JavaScript is not unit tested. Testing it properly means extracting
functions into a second file, which would break the single-file property and the
rule that `serve.py` serves nothing but `index.html`. The browser suite tests the
same logic through its effects, which is enough for a tool with one user.

`state.sh` is not tested directly. `test_console.py` tests its output, which is
the part anything else depends on.

None of these are a checkpoint. Per `.clinerules/01-jit-poc.md` they are a diagnostic
tool. If the console becomes a build step, its frozen checkpoint is the proof.
