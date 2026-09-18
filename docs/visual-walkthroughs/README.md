# Visual Walkthroughs

Interactive HTML pages that explain the JIT system visually. Open them in a
browser — no server, no dependencies, no build step. Each one is self-contained.

## Recommended viewing order

Start here if you are new to the project. Each page teaches one layer of the
system, and they build on each other.

| # | Open | What it teaches |
|---|---|---|
| 1 | [`how-it-works-presentation.html`](how-it-works-presentation.html) | **The whole system in 14 slides.** Annotations, provisioning, two-speed cleanup, split-plane design. Arrow keys to advance. This is the 30-second overview that gives you the vocabulary for everything else. |
| 2 | [`annotation-to-state.html`](annotation-to-state.html) | **How names resolve.** Pick a namespace and a module, and every name follows — annotation key, InfraClaim, IP (with the block map), container, Secret/Service/EndpointSlice, MinIO state key — plus the five lookup commands with their answers. |
| 3 | [`controller-explained.html`](controller-explained.html) | **What the controller does.** Reconciler vs admission controller, its four kopf triggers, what each one does, the claim state machine, and why the missing Secret is the gate. |
| 4 | [`deletion-lifecycle.html`](deletion-lifecycle.html) | **What happens when you delete.** A drivable simulation of the retention window: delete the deployment, redeploy inside the clock, or let it expire, and watch which of the container, IP, Secret, Service and EndpointSlice survive each stage. Includes the with/without double-release-guard comparison. |
| 5 | [`timeline.html`](timeline.html) | **What a real run looks like.** One real run on five lanes (deployment, controller, runner, container, pod), every event with the source of its timestamp. Run picker, sub-second zoom, subject filter. Reads `docs/evidence/timeline.log`. |

## Companion markdown docs

Each HTML walkthrough has a written counterpart in `docs/designs/` for deeper
reference:

| Walkthrough | Design doc |
|---|---|
| `how-it-works-presentation` | [`docs/designs/jit-infra-poc.md`](../designs/jit-infra-poc.md) |
| `annotation-to-state` | [`docs/designs/annotation-to-state.md`](../designs/annotation-to-state.md) |
| `controller-explained` | [`docs/designs/jit-infra-poc.md`](../designs/jit-infra-poc.md) (§claim lifecycle) |
| `deletion-lifecycle` | [`docs/designs/deletion-lifecycle.md`](../designs/deletion-lifecycle.md) |
| `timeline` | [`docs/designs/jit-infra-poc.md`](../designs/jit-infra-poc.md) (§timeline) |
