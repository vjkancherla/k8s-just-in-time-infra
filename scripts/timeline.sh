#!/usr/bin/env bash
set -euo pipefail

# scripts/timeline.sh - what actually happened, with a source on every event (build-plan S21).
#
#   make timeline   ->   one JSON object on stdout, and nothing else
#
# A read model exactly like scripts/state.sh: bash for the preflight, one python program for
# the document, because it is one JSON object. Every `t` is read from one of the sources the
# step names, and `source` records which one:
#
#   kubectl get deployments/infraclaims/secrets/pods   the objects' own creationTimestamps,
#                                                     and a pod container's running.startedAt
#   kubectl logs --timestamps deploy/jit-controller    the only record of when the controller
#                                                     saw a Deployment, allocated an address,
#                                                     created a Service or set a claim Ready -
#                                                     no phase transition is timestamped and
#                                                     the claims carry no conditions
#   docker inspect, per module container               .Created, .State.StartedAt,
#                                                     .State.FinishedAt, .RestartCount
#   docker logs --timestamps jit-runner                its access lines: when a provisioning
#                                                     call was served
#
# `lane` is one of the five the page draws (`deployment`, `controller`, `runner`, `container`,
# `pod`); `subject` is `<namespace>/<name>` for a namespaced object and the container name for
# a container. One event per step per subject, first-seen wins: the 30-second resync repeats
# the controller's lines and re-runs handle_deployment, and without that rule the axis fills
# with controller noise. Events are sorted ascending by `t` as written - the sources' own text,
# untouched - and no event carries a duration: the axis arithmetic belongs in the browser, the
# same way the countdown does.
#
# `up` is `make state`'s: the API, the InfraClaim CRD and an available controller replica. With
# no cluster the document is {"up": false, "t0": null, "events": []} and this exits 0, because
# the page may ask before a cluster exists. With the stack up, a source that fails exits
# non-zero - a lie to the page is worse than an error.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTRL_NS="default"
CTRL_DEPLOY="jit-controller"
RUNNER_CONTAINER="jit-runner"

# The namespaces the console is allowed to know about - the same pair `make ns-delete` refuses
# to go outside of, so there is one fence in the project, not two.
ALLOWED_NS="${ALLOWED_NS:-voting-a voting-b}"

for c in kubectl docker python3; do
  command -v "$c" >/dev/null 2>&1 \
    || { echo "FAIL: '$c' is not on PATH (build-plan S21 needs it)" >&2; exit 1; }
done

export CTRL_NS CTRL_DEPLOY RUNNER_CONTAINER ALLOWED_NS

# The shell above is checks and fences; the timeline itself is one program, because it is one
# JSON object and splitting it across two languages is how the shape drifts.
python3 - <<'PY'
import datetime
import json
import os
import re
import subprocess
import sys

CTRL_NS = os.environ["CTRL_NS"]
CTRL_DEPLOY = os.environ["CTRL_DEPLOY"]
RUNNER_CONTAINER = os.environ["RUNNER_CONTAINER"]
ALLOWED_NS = os.environ["ALLOWED_NS"].split()

# Module containers are named "<ns>-<module>-<module>" (jit-modules/modules/*/main.tf); the
# pattern is exact, the same one scripts/state.sh uses, so an unrelated container that merely
# ends in "-redis" is not read as JIT infra.
MODULE_CONTAINER = re.compile(r"-(redis-redis|postgres-postgres|pgadmin-pgadmin)$")

# What Docker reports for a container that has never stopped. It is not an event.
NEVER = "0001-01-01T00:00:00Z"

# The controller's own log lines, as kopf writes them:
#   2026-09-15T18:50:47.137231236Z 2026-09-15 18:50:47,137 jit-controller INFO <message>
# The first field is the timestamp `kubectl logs --timestamps` stamped, and it is the one read.
CONTROLLER_LINE = re.compile(
    r"^(\S+Z) \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} "
    r"(?:kopf\.objects|jit-controller) (?:INFO|WARNING|ERROR) (.*)$")

# Which controller messages name a step, and what each one is. The third field says whether the
# message names its namespace; the rest name only the claim, whose namespace is resolved from
# the claim listing.
CONTROLLER_SOURCE = "kubectl logs --timestamps deploy/jit-controller"
CONTROLLER_MESSAGES = (
    (re.compile(r"^Deployment (\S+) created/updated in (\S+)$"), "controller.saw", True),
    (re.compile(r"^Created Service (\S+) in (\S+)$"), "service.created", True),
    (re.compile(r"^InfraClaim (\S+) allocated (\S+) \(block \S+\)$"), "ipam.allocated", False),
    (re.compile(r"^InfraClaim (\S+) phase set to Ready(?: \(runner\)| \(fake mode\))?$"),
     "claim.ready", False),
)

# The five lanes and the thirteen kinds are fixed by the step; one outside them is a design
# change and not a parser tweak, so it stops the read rather than printing.
LANES = ("deployment", "controller", "runner", "container", "pod")
KINDS = ("deployment.applied", "controller.saw", "claim.created", "ipam.allocated",
         "claim.ready", "runner.call", "secret.created", "service.created",
         "container.created", "container.started", "container.stopped",
         "pod.created", "pod.started")

events = []


def note(msg):
    print(msg, file=sys.stderr)


def run(cmd):
    return subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def read_or_die(cmd, what):
    """A source that must answer while the stack is up - non-zero here is a failure."""
    proc = run(cmd)
    if proc.returncode != 0:
        note("FAIL: could not read %s (%s)" % (what, " ".join(cmd)))
        if proc.stderr.strip():
            note("      " + proc.stderr.strip().splitlines()[-1])
        sys.exit(1)
    return proc.stdout


def stack_is_up():
    """`make jit-up`'s stack, asked of the cluster: API, CRD and a controller replica."""
    if run(["kubectl", "get", "ns", "default", "-o", "name"]).returncode != 0:
        return False
    if run(["kubectl", "get", "crd", "infraclaims.jit.io"]).returncode != 0:
        return False
    proc = run(["kubectl", "get", "deployment", CTRL_DEPLOY, "-n", CTRL_NS,
                "-o", "jsonpath={.status.availableReplicas}"])
    replicas = proc.stdout.strip()
    return proc.returncode == 0 and replicas.isdigit() and int(replicas) > 0


def tenant_json(cmd, what):
    """One `kubectl get -A -o json` listing, filtered to the two tenant namespaces.

    Everything in `default` and `kube-system` belongs to the control plane and the cluster, and
    is not part of the run the axis draws.
    """
    doc = json.loads(read_or_die(cmd, what))
    return [item for item in doc.get("items", [])
            if item["metadata"]["namespace"] in ALLOWED_NS]


def qualified(namespace, name):
    """<namespace>/<name> for a namespaced object, or None when it is not ours."""
    return "%s/%s" % (namespace, name) if namespace in ALLOWED_NS else None


def add(t, lane, kind, subject, source):
    """One event: when, where, what, whom, and the command the time came from."""
    if lane not in LANES or kind not in KINDS:
        note("FAIL: %s on lane %s is outside the design's lanes and kinds" % (kind, lane))
        sys.exit(1)
    if not (t and subject and source):
        note("FAIL: an event is missing its time, subject or source (%s %s)" % (kind, subject))
        sys.exit(1)
    events.append({"t": t, "lane": lane, "kind": kind, "subject": subject, "source": source})


def claim_subject(name, claim_ns):
    """<namespace>/<claim> for a controller line that names only the claim.

    The allocation and Ready lines carry no namespace, so it comes from the claim listing, and
    failing that - a claim deleted before this read - from the "<namespace>-" prefix the
    controller gives every claim name (create_infra_claim in jit-controller/main.py).
    """
    ns = claim_ns.get(name) or next((n for n in ALLOWED_NS if name.startswith(n + "-")), None)
    return qualified(ns, name) if ns else None


# ---------------------------------------------------------------- the five sources

def read_deployments():
    """When each tenant Deployment was applied: the API's own creationTimestamp."""
    for item in tenant_json(["kubectl", "get", "deployments", "-A", "-o", "json"],
                            "the Deployments"):
        add(item["metadata"]["creationTimestamp"], "deployment", "deployment.applied",
            "%s/%s" % (item["metadata"]["namespace"], item["metadata"]["name"]),
            "kubectl:deployment.metadata.creationTimestamp")


def read_claims():
    """The claims themselves, and the name -> namespace map the log lines need.

    claim.created comes from the object rather than from the controller's line saying it made
    one: the API's creationTimestamp is the record that the claim exists.
    """
    by_name = {}
    for item in tenant_json(["kubectl", "get", "infraclaims", "-A", "-o", "json"],
                            "the InfraClaims"):
        namespace = item["metadata"]["namespace"]
        name = item["metadata"]["name"]
        by_name[name] = namespace
        add(item["metadata"]["creationTimestamp"], "controller", "claim.created",
            "%s/%s" % (namespace, name),
            "kubectl:infraclaim.metadata.creationTimestamp")
    return by_name


def read_secrets():
    for item in tenant_json(["kubectl", "get", "secrets", "-A", "-o", "json"],
                            "the Secrets"):
        add(item["metadata"]["creationTimestamp"], "controller", "secret.created",
            "%s/%s" % (item["metadata"]["namespace"], item["metadata"]["name"]),
            "kubectl:secret.metadata.creationTimestamp")


def read_pods():
    """Every pod's creation, and the moment each of its containers was running."""
    for item in tenant_json(["kubectl", "get", "pods", "-A", "-o", "json"], "the Pods"):
        namespace, name = item["metadata"]["namespace"], item["metadata"]["name"]
        add(item["metadata"]["creationTimestamp"], "pod", "pod.created",
            "%s/%s" % (namespace, name), "kubectl:pod.metadata.creationTimestamp")
        for container in ((item.get("status") or {}).get("containerStatuses") or []):
            started = ((container.get("state") or {}).get("running") or {}).get("startedAt")
            if started:
                add(started, "pod", "pod.started", "%s/%s" % (namespace, name),
                    "kubectl:pod.status.containerStatuses[].state.running.startedAt")


def read_containers():
    """Each module container's life, read from Docker rather than from the cluster."""
    proc = read_or_die(["docker", "ps", "-a", "--format", "{{.Names}}"], "the containers")
    for name in sorted(n for n in proc.split("\n") if MODULE_CONTAINER.search(n)):
        fields = read_or_die(
            ["docker", "inspect", "-f",
             "{{.Created}}|{{.State.StartedAt}}|{{.State.FinishedAt}}|{{.RestartCount}}", name],
            "container %s" % name).strip().split("|")
        created, started, finished = fields[0], fields[1], fields[2]
        # RestartCount is read with the three timestamps, as the step names it, but no event
        # carries it: the kind set has no restart, and a count is not a time. A restart shows
        # up where it happened - the container stopped, and then it started again.
        add(created, "container", "container.created", name, "docker inspect:.Created")
        if started and started != NEVER:
            add(started, "container", "container.started", name,
                "docker inspect:.State.StartedAt")
        if finished and finished != NEVER:
            add(finished, "container", "container.stopped", name,
                "docker inspect:.State.FinishedAt")


def read_controller_log(claim_ns):
    """What the controller did, from the only log that says so.

    Every decision the controller makes is logged with the time kopf's handler ran, and the
    30-second resync repeats those lines - which is what first-seen wins is for.
    """
    proc = read_or_die(["kubectl", "logs", "--timestamps", "deploy/" + CTRL_DEPLOY,
                        "-n", CTRL_NS], "the controller's log")
    for line in proc.split("\n"):
        matched = CONTROLLER_LINE.match(line)
        if not matched:
            continue
        t, message = matched.group(1), matched.group(2)
        for pattern, kind, names_namespace in CONTROLLER_MESSAGES:
            hit = pattern.match(message)
            if not hit:
                continue
            subject = (qualified(hit.group(2), hit.group(1)) if names_namespace
                       else claim_subject(hit.group(1), claim_ns))
            if subject:
                add(t, "controller", kind, subject, CONTROLLER_SOURCE)
            break


def read_runner_log():
    """When a provisioning call was served: the runner's own access lines."""
    proc = run(["docker", "logs", "--timestamps", RUNNER_CONTAINER])
    if proc.returncode != 0:
        note("FAIL: could not read the runner's log (docker logs --timestamps %s)"
             % RUNNER_CONTAINER)
        if proc.stderr.strip():
            note("      " + proc.stderr.strip().splitlines()[-1])
        sys.exit(1)
    # docker logs puts the container's stdout on stdout and its stderr on stderr; the access
    # lines uvicorn writes are on stderr, so both are read.
    for line in (proc.stdout + proc.stderr).split("\n"):
        t, _, rest = line.partition(" ")
        if t.endswith("Z") and "POST /v1/runs" in rest:
            add(t, "runner", "runner.call", RUNNER_CONTAINER,
                "docker logs --timestamps jit-runner")


# ------------------------------------------------------------------- the document

def first_seen():
    """One event per step per subject, ascending by `t`.

    Sorted by `t` as written - the source's own text, untouched, which is how the page and the
    frozen checkpoint read the order (jq's own sort is a text sort). Within one second that
    puts a fractional stamp (`...32.9Z`) before a whole one (`...32Z`); the axis is drawn in
    seconds, and this is the order the checkpoint compares. First-seen wins: the earliest
    arrival of a step for a subject is the one that happened, and the resync's repeats are
    dropped.
    """
    earliest = {}
    for event in sorted(events, key=lambda e: e["t"]):
        earliest.setdefault((event["kind"], event["subject"]), event)
    return sorted(earliest.values(),
                  key=lambda e: (e["t"], e["lane"], e["kind"], e["subject"]))


def emit(document):
    print(json.dumps(document, separators=(",", ":")))


def main():
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not stack_is_up():
        # One shape in both branches: an absent stack has no events either, and the page should
        # read a null rather than find the key missing.
        emit({"up": False, "generatedAt": generated_at, "t0": None, "events": []})
        return 0

    claim_ns = read_claims()
    read_deployments()
    read_secrets()
    read_pods()
    read_containers()
    read_controller_log(claim_ns)
    read_runner_log()

    kept = first_seen()
    emit({"up": True, "generatedAt": generated_at,
          "t0": kept[0]["t"] if kept else None,
          "events": kept})
    return 0


sys.exit(main())
PY
