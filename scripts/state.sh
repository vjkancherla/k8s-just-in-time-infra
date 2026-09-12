#!/usr/bin/env bash
set -euo pipefail

# scripts/state.sh - the console's read model (build-plan S18).
#
#   make state   ->   one JSON object on stdout, and nothing else
#
# Every field is *read*, never computed: kubectl for the claims, the `jit-ipam` ledger for
# the block a namespace owns, `docker ps`/`docker inspect` for the module containers, and
# the `jit-state` bucket for the state objects. A claim's phase is passed through as the
# controller wrote it, and so is `expiresAt` - the countdown is the caller's problem. The
# sources are the ones the frozen checks read, so the page cannot drift from `make verify`.
#
# The one normalisation: the controller spells "no expiry" two ways - the field absent, or
# an empty string from `clear_status_field` (jit-controller/main.py) - and the design's read
# model has a single spelling for it, `"expiresAt": null` (docs/build-plan.md S18). Both
# collapse to null here; everything else is verbatim.
#
# `up` is whether the stack `make jit-up` defines is there, asked of the cluster itself: the
# API answers, the InfraClaim CRD is served, and the controller has an available replica.
# False means the console is talking to nothing - no cluster at all (KUBECONFIG=/nonexistent)
# or a cluster without the control plane - and then every list is empty, because an absent
# stack's read model is an empty one. It is not an error: the console polls this before a
# cluster exists, so this exits 0 either way, and exits non-zero only when the stack *is* up
# and a source it must read fails. A lie to the console is worse than an error.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CTRL_NS="default"
CTRL_DEPLOY="jit-controller"
LEDGER_CM="jit-ipam"
BUCKET="jit-state"

# The namespaces the console is allowed to know about - the same pair `make ns-delete`
# refuses to go outside of, so there is one fence in the project, not two.
ALLOWED_NS="${ALLOWED_NS:-voting-a voting-b}"

for c in kubectl docker python3; do
  command -v "$c" >/dev/null 2>&1 \
    || { echo "FAIL: '$c' is not on PATH (build-plan S18 needs it)" >&2; exit 1; }
done

# The MinIO credentials come from the same place scripts/verify-jit.sh J11 reads them.
env_get() { grep -E "^$1=" deploy/.env 2>/dev/null | head -n1 | cut -d= -f2-; }
MINIO_ROOT_USER="$(env_get MINIO_ROOT_USER)"
MINIO_ROOT_PASSWORD="$(env_get MINIO_ROOT_PASSWORD)"
export MINIO_ROOT_USER MINIO_ROOT_PASSWORD
export CTRL_NS CTRL_DEPLOY LEDGER_CM BUCKET ALLOWED_NS

# The shell above is checks and credentials; the read model itself is one program, because
# it is one JSON object and splitting it across two languages is how the shape drifts.
python3 - <<'PY'
import datetime
import hashlib
import hmac
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

CTRL_NS = os.environ["CTRL_NS"]
CTRL_DEPLOY = os.environ["CTRL_DEPLOY"]
LEDGER_CM = os.environ["LEDGER_CM"]
BUCKET = os.environ["BUCKET"]
ALLOWED_NS = os.environ["ALLOWED_NS"].split()

# Module containers are named "<ns>-<module>-<module>" (jit-modules/modules/*/main.tf), so
# the pattern is exact: it cannot match an unrelated container that merely ends in "-redis".
MODULE_CONTAINER = re.compile(r"-(redis-redis|postgres-postgres|pgadmin-pgadmin)$")

# The MinIO endpoint the stack publishes (deploy/minio.sh).
ENDPOINT = os.environ.get("MINIO_ENDPOINT", "http://127.0.0.1:9000")
HOST = ENDPOINT.split("//", 1)[-1]

# ipam.BLOCK_SIZE (jit-controller/ipam.py): a namespace's block is ten addresses and the
# ledger records the first. The read model does not own that number; it is how the design
# spells "the block this namespace owns", and the console only displays it.
BLOCK_SIZE = 10
BLOCK_PREFIX = "ns/"


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


def read_ledger():
    proc = run(["kubectl", "get", "configmap", LEDGER_CM, "-n", CTRL_NS,
                "-o", "jsonpath={.data.allocations}"])
    raw = proc.stdout.strip() if proc.returncode == 0 else ""
    if not raw:
        # No ledger means no namespace has been given a block yet - not an error, and not a
        # reason to report a block for anyone.
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        note("note: the %s ledger is not the JSON the controller writes; ignoring it" % LEDGER_CM)
        return {}


def read_containers():
    """Every module container on the host, running or not, with the address it holds."""
    proc = run(["docker", "ps", "-a", "--format", "{{.Names}}"])
    if proc.returncode != 0:
        note("note: docker is not answering; no containers reported")
        return []
    containers = []
    for name in sorted(n for n in proc.stdout.split("\n") if MODULE_CONTAINER.search(n)):
        inspect = run(["docker", "inspect", "-f",
                       "{{.State.Running}} {{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}",
                       name])
        fields = inspect.stdout.split()
        containers.append({
            "name": name,
            "address": fields[1] if len(fields) > 1 else "",
            "running": bool(fields) and fields[0] == "true",
        })
    return containers


def read_state_objects():
    """Every key under ns/ in the state bucket.

    The listing is a SigV4 GET in stdlib python, mirroring scripts/verify-jit.sh J11: the
    aws CLI is unusable on this host (its shebang is /usr/bin/python, which does not exist)
    and `mc` is not installed. Same code path as the frozen check, which is what "the same
    sources the frozen checks read" means.
    """
    access = os.environ.get("MINIO_ROOT_USER", "")
    secret = os.environ.get("MINIO_ROOT_PASSWORD", "")
    if not access or not secret:
        note("note: deploy/.env has no MINIO_ROOT_USER / MINIO_ROOT_PASSWORD; stateObjects reported empty")
        return []

    now = datetime.datetime.now(datetime.timezone.utc)
    ts = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")
    # S3's canonical query string encodes "/" as %2F; signing the raw prefix and sending it
    # that way is a SignatureDoesNotMatch (verify-jit.sh J11 found that the hard way).
    query = "list-type=2&prefix=" + urllib.parse.quote(BLOCK_PREFIX, safe="")

    def sign(key, msg):
        return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

    ch = "host:%s\nx-amz-date:%s\n" % (HOST, ts)
    sh = "host;x-amz-date"
    ph = hashlib.sha256(b"").hexdigest()
    cr = "GET\n/%s\n%s\n%s\n%s\n%s" % (BUCKET, query, ch, sh, ph)
    scope = "%s/%s/%s/aws4_request" % (date, "us-east-1", "s3")
    sts = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (ts, scope, hashlib.sha256(cr.encode("utf-8")).hexdigest())
    k = ("AWS4" + secret).encode("utf-8")
    kd = sign(k, date)
    kr = sign(kd, "us-east-1")
    ks = sign(kr, "s3")
    ksig = sign(ks, "aws4_request")
    sig = hmac.new(ksig, sts.encode("utf-8"), hashlib.sha256).hexdigest()

    req = urllib.request.Request("%s/%s?%s" % (ENDPOINT, BUCKET, query), method="GET")
    req.add_header("Host", HOST)
    req.add_header("x-amz-date", ts)
    req.add_header("x-amz-content-sha256", ph)
    req.add_header("Authorization",
                   "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                   % (access, scope, sh, sig))
    try:
        body = urllib.request.urlopen(req, timeout=10).read()
    except (urllib.error.HTTPError, urllib.error.URLError, OSError) as exc:
        note("note: could not list %s at %s (%s); stateObjects reported empty"
             % (BUCKET, ENDPOINT, exc))
        return []

    s3 = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    return sorted(c.find("s3:Key", s3).text
                  for c in ET.fromstring(body).findall("s3:Contents", s3))


def block_of(ledger, namespace):
    """The block a namespace owns, as the design spells it: "<base>-<last>", ten wide."""
    base = (ledger.get(namespace) or {}).get("base_ip")
    if not base or "." not in base:
        return None
    head, _, last = base.rpartition(".")
    if not last.isdigit():
        return None
    return "%s.%d-%d" % (head, int(last), int(last) + BLOCK_SIZE - 1)


def build_namespaces(claims, ledger):
    by_namespace = {}
    for item in claims.get("items", []):
        namespace = item["metadata"]["namespace"]
        status = item.get("status") or {}
        by_namespace.setdefault(namespace, []).append({
            "module": (item.get("spec") or {}).get("module", ""),
            "phase": status.get("phase", ""),
            "address": status.get("allocatedIP") or "",
            "referencedBy": status.get("referencedBy") or [],
            # absent, "" and null are the same thing to the console: no countdown.
            "expiresAt": status.get("expiresAt") or None,
        })

    proc = run(["kubectl", "get", "ns", "-o", "jsonpath={.items[*].metadata.name}"])
    existing = proc.stdout.split() if proc.returncode == 0 else []
    # The demo's two namespaces are shown whenever they exist - the console is theirs - plus
    # any other namespace that owns a claim or a block, so the read model can never report
    # fewer claims than the cluster holds.
    names = set(by_namespace) | set(ledger) | {n for n in existing if n in ALLOWED_NS}

    return [{"name": namespace,
             "block": block_of(ledger, namespace),
             "claims": sorted(by_namespace.get(namespace, []), key=lambda c: c["module"])}
            for namespace in sorted(names)]


def emit(document):
    print(json.dumps(document, separators=(",", ":")))


def main():
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    if not stack_is_up():
        emit({"up": False, "generatedAt": generated_at,
              "namespaces": [], "containers": [], "stateObjects": []})
        return 0

    claims = json.loads(read_or_die(["kubectl", "get", "infraclaims", "-A", "-o", "json"],
                                    "the InfraClaims"))
    emit({"up": True,
          "generatedAt": generated_at,
          "namespaces": build_namespaces(claims, read_ledger()),
          "containers": read_containers(),
          "stateObjects": read_state_objects()})
    return 0


sys.exit(main())
PY
