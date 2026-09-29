#!/usr/bin/env python3
import base64
import hashlib
import json
import logging
import os
import re
import secrets
import threading
from datetime import datetime, timedelta, timezone
from urllib.parse import quote

import kopf
import requests
from ipam import allocate_block, first_free_address, release_block
from kubernetes import client, config

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"
FINALIZER = "jit.infra/teardown"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("jit-controller")
# kopf reconfigures the root logger, which silently drops this logger's INFO records
# (its own "kopf.objects" logger still prints). Without this line the handler's
# decisions - claim creation, IP allocation, provisioning - are invisible in the pod
# log, which is exactly what S17 needed to debug a duplicate-address allocation.
logger.setLevel(logging.INFO)

# Guards the per-claim lock registry below.
_claim_locks_guard = threading.Lock()
_claim_locks = {}

# Guards the per-namespace IPAM registry below.
_ns_locks_guard = threading.Lock()
_ns_locks = {}


def namespace_lock(namespace):
    """Process-local lock for one namespace's IP allocation.

    Allocation is read-then-write: read the other claims' allocatedIP, pick the first
    free address, then patch this claim's status. Without a lock spanning all three
    steps, two claims in one namespace read the same "taken" set and are handed the
    same address - and they really do run concurrently, because kopf fires both
    on.create and on.update for a single Deployment apply, each iterating every claim.
    The loser then fails to start its container ("Address already in use") and the
    claim goes Failed. Found by S17's J1. Single controller replica is assumed, as for
    claim_lock.
    """
    with _ns_locks_guard:
        lock = _ns_locks.get(namespace)
        if lock is None:
            lock = threading.Lock()
            _ns_locks[namespace] = lock
        return lock

RUNNER_URL = os.environ.get("RUNNER_URL", "")
RUNNER_TOKEN = os.environ.get("RUNNER_TOKEN", "")
DOCKER_NETWORK = os.environ.get("DOCKER_NETWORK", "k3d-voting-app")


def load_kube():
    """Load kubernetes config and disable SSL verification for k3d self-signed certs."""
    try:
        configuration = client.Configuration()
        config.load_incluster_config(client_configuration=configuration)
    except Exception:
        configuration = client.Configuration()
        config.load_kube_config(client_configuration=configuration)
    configuration.verify_ssl = False
    client.Configuration.set_default(configuration)


SERVICE_ACCOUNT_TOKEN = "/var/run/secrets/kubernetes.io/serviceaccount/token"


# Registered only in-cluster. Off-cluster (S26's stub run, local diagnostics)
# the file does not exist; registering the handler there would make kopf retry a
# FileNotFoundError login forever instead of falling back to the kubeconfig that
# load_kube() loaded. With no explicit login handler registered, kopf's own
# kubeconfig login is used.
if os.path.exists(SERVICE_ACCOUNT_TOKEN):
    @kopf.on.login()
    def custom_login(**kwargs):
        load_kube()
        return kopf.ConnectionInfo(
            server="https://kubernetes.default.svc",
            ca_path="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
            insecure=True,
            token=open(SERVICE_ACCOUNT_TOKEN).read(),
            default_namespace="default",
            priority=100,
        )


def get_namespace_uid(namespace):
    core = client.CoreV1Api()
    ns_obj = core.read_namespace(namespace)
    return ns_obj.metadata.uid


def claim_lock(namespace, name):
    """Process-local lock for one claim.

    Two Deployments annotating the same claim — or kopf's create+update pair — can
    otherwise call provision_infra concurrently and both drive a tofu apply over the
    same container name. The runner serialises per run too; this avoids the duplicate
    work and the noisy conflict. Single controller replica is assumed.
    """
    key = f"{namespace}/{name}"
    with _claim_locks_guard:
        lock = _claim_locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _claim_locks[key] = lock
        return lock


def parse_annotations(annotations):
    if not annotations:
        return []
    claims = []
    for k, v in annotations.items():
        if k.startswith("jit.infra/"):
            module = k.split("/", 1)[1]
            try:
                data = json.loads(v)
            except Exception:
                data = {}
            data["module"] = module
            claims.append(data)
    return claims


@kopf.on.create("apps", "Deployment")
@kopf.on.update("apps", "Deployment")
def handle_deployment(body, namespace, name, logger, **kwargs):
    logger.info(f"Deployment {name} created/updated in {namespace}")
    load_kube()
    annotations = body.get("metadata", {}).get("annotations", {})
    claims = parse_annotations(annotations)
    if not claims:
        logger.debug(f"No jit.infra annotations on {name}")
        return

    api = client.CustomObjectsApi()
    ns_uid = get_namespace_uid(namespace)

    for claim_spec in claims:
        module = claim_spec["module"]
        claim_name = f"{namespace}-{module}"
        spec = {
            "module": module,
            "moduleVersion": claim_spec.get("moduleVersion", "v1"),
            "params": claim_spec.get("params", {}),
            "softDeleteTTL": claim_spec.get("softDeleteTTL", "30d"),
        }
        ensure_claim(api, namespace, ns_uid, claim_name, spec)
        # Resolve from live Deployments rather than this event's copy, so the
        # create+update pair and a stale event body agree on the desired params.
        reconcile_claim(api, namespace, claim_name, module, spec, force=True)


def _allocated_ip(api, ns, name):
    """Current status.allocatedIP of a claim, or '' when unset."""
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
    except client.exceptions.ApiException:
        return ""
    return (obj.get("status", {}) or {}).get("allocatedIP", "") or ""


def _namespace_ips(api, ns, exclude=""):
    """Addresses already held by the other claims in the namespace."""
    ips = []
    try:
        items = api.list_namespaced_custom_object(
            GROUP, VERSION, ns, PLURAL).get("items", [])
    except client.exceptions.ApiException:
        return ips
    for item in items:
        if item.get("metadata", {}).get("name") == exclude:
            continue
        ip = (item.get("status", {}) or {}).get("allocatedIP", "")
        if ip:
            ips.append(ip)
    return ips


def ensure_claim(api, ns, ns_uid, name, spec):
    body = {
        "apiVersion": f"{GROUP}/{VERSION}",
        "kind": "InfraClaim",
        "metadata": {
            "name": name,
            "namespace": ns,
            "ownerReferences": [
                {
                    "apiVersion": "v1",
                    "kind": "Namespace",
                    "name": ns,
                    "uid": ns_uid,
                    "blockOwnerDeletion": True,
                }
            ],
            "finalizers": [FINALIZER],
        },
        "spec": spec,
        "status": {},
    }
    try:
        api.create_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, body)
        logger.info(f"Created InfraClaim {name} in {ns}")
    except client.exceptions.ApiException as e:
        if e.status != 409:
            raise
        logger.info(f"InfraClaim {name} already exists in {ns}")

    # IPAM: give this claim its own address from the namespace's block.
    # allocate_block is only called for a claim that has no address yet, so the
    # namespace's count tracks real claims rather than handler invocations — it used
    # to grow on every Deployment event, so release_block never reached zero and the
    # block was never freed. A claim that already has an address keeps it: moving a
    # live container's IP would break its EndpointSlice.
    # The read-then-write below has to be atomic per namespace: see namespace_lock.
    with namespace_lock(ns):
        allocated_ip = _allocated_ip(api, ns, name)
        if not allocated_ip:
            base_ip = allocate_block(ns)
            if not base_ip:
                logger.error(f"No IP block available for namespace {ns}; "
                             f"{name} left unprovisioned")
                return
            allocated_ip = first_free_address(base_ip, _namespace_ips(api, ns, exclude=name))
            if not allocated_ip:
                logger.error(f"Block {base_ip} for namespace {ns} is full; "
                             f"{name} cannot be given an address")
                return
            try:
                api.patch_namespaced_custom_object_status(
                    GROUP, VERSION, ns, PLURAL, name,
                    {"status": {"allocatedIP": allocated_ip}})
                logger.info(f"InfraClaim {name} allocated {allocated_ip} (block {base_ip})")
            except client.exceptions.ApiException as e:
                logger.warning(f"Failed to set allocatedIP on {name}: {e}")


def _jit_secret_data(ns, module):
    """Decoded data of the jit-<module> Secret, or {} when it does not exist."""
    core = client.CoreV1Api()
    try:
        secret = core.read_namespaced_secret(f"jit-{module}", ns)
    except client.exceptions.ApiException as e:
        if e.status == 404:
            return {}
        raise
    data = {}
    for k, v in (secret.data or {}).items():
        try:
            data[k] = base64.b64decode(v).decode()
        except Exception:
            data[k] = ""
    return data


def resolve_postgres_credentials(ns, module, params):
    """Fill in the Postgres credentials the tenant did not supply.

    Returns (params, pending). A non-empty `pending` means a dependency is not
    ready yet - the caller must leave the claim pending rather than fail it,
    because Failed is terminal until the Deployment changes.

    The jit-postgres Secret is the single source of truth for the generated
    password: pgadmin reads it to pair with the database, and a cold destroy
    reads it before cleanup deletes it. Reusing the stored value keeps the
    password stable across re-provisioning, so a Postgres container that already
    holds data is never asked to change its password.
    """
    if module == "pgadmin":
        secret = _jit_secret_data(ns, "postgres")
        if not secret.get("address"):
            return params, "waiting for the jit-postgres Secret (the postgres claim is not Ready)"
        params.setdefault("postgres_url", f"{secret['address']}:{secret.get('port', '5432')}")
        if not secret.get("POSTGRES_PASSWORD"):
            return params, "waiting for POSTGRES_PASSWORD in the jit-postgres Secret"
        params.setdefault("postgres_password", secret["POSTGRES_PASSWORD"])
        return params, ""

    if module == "postgres" and "postgres_password" not in params:
        stored = _jit_secret_data(ns, "postgres").get("POSTGRES_PASSWORD")
        params["postgres_password"] = stored or secrets.token_urlsafe(24)
    return params, ""


def provision_infra(api, ns, name, module, spec, tenant_params=None):
    """Create path: fetch the claim, then apply the resolved params via the runner.

    `tenant_params` is the resolved desired params from declarers; when omitted
    (older callers) the claim's spec.params is used.
    """
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
    except client.exceptions.ApiException:
        return

    status = obj.get("status", {})
    phase = status.get("phase", "")
    logger.info(f"provision_infra: {name} phase={phase}, allocatedIP={status.get('allocatedIP', 'none')}")

    # Check for stale Ready state: if claim is Ready but Secret is missing or empty,
    # force re-provision (happens when namespace was deleted/recreated).
    if phase == "Ready":
        secret_name = f"jit-{module}"
        core = client.CoreV1Api()
        try:
            secret = core.read_namespaced_secret(secret_name, ns)
            if secret.data and len(secret.data) > 0:
                logger.info(f"provision_infra: {name} is Ready with Secret data, skipping")
                return  # Secret exists with data, truly provisioned
            else:
                logger.info(f"Stale Ready claim {name} (Secret empty), forcing re-provision")
        except client.exceptions.ApiException as e:
            if e.status == 404:
                logger.info(f"Stale Ready claim {name} (Secret gone), forcing re-provision")
            else:
                return
        # Reset phase and clear stale expiresAt so provisioning runs
        try:
            api.patch_namespaced_custom_object_status(
                GROUP, VERSION, ns, PLURAL, name,
                {"status": {"phase": "", "expiresAt": None}})
        except client.exceptions.ApiException:
            pass
        # Re-read the claim after phase reset
        try:
            obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
            status = obj.get("status", {})
            phase = status.get("phase", "")
        except client.exceptions.ApiException:
            return

    if phase == "Deleting":
        return

    allocated_ip = status.get("allocatedIP", "")
    if not allocated_ip:
        logger.warning(f"No allocatedIP on {name}, cannot provision")
        return

    if tenant_params is None:
        tenant_params = _normalize_params(spec.get("params", {}))
    _apply_via_runner(api, ns, name, module, spec, tenant_params, allocated_ip,
                      is_update=False)


def _existing_outputs_changed(ns, module, new_outputs):
    """True when a Secret key that exists today would change value (design §Update flow 6)."""
    old = _jit_secret_data(ns, module)
    for key, value in old.items():
        if key in new_outputs and str(new_outputs[key]) != str(value):
            return True
    return False


def _apply_via_runner(api, ns, name, module, spec, tenant_params, allocated_ip, is_update):
    """POST the resolved params plus the controller overlay; record the outcome.

    Both the create path (`is_update=False`) and the update path (`is_update=True`)
    share this. A create failure sets phase `Failed`; an update failure keeps the
    design's `Ready` + `UpdateFailed`, never `Deleting`, and never touches the
    finalizer.
    """
    runner_params = dict(tenant_params)
    runner_params["name"] = f"{ns}-{module}"
    runner_params["ip"] = allocated_ip
    runner_params["network"] = DOCKER_NETWORK

    # Postgres and pgadmin need the generated password; pgadmin also needs the
    # database's address. A missing dependency leaves the claim pending so the
    # resync retries - see resolve_postgres_credentials.
    runner_params, pending = resolve_postgres_credentials(ns, module, runner_params)
    if pending:
        logger.info(f"provision_infra: {name} pending - {pending}")
        return

    patch_status_fields(api, ns, name,
                        {"attemptedParamsHash": params_hash(module, ns, tenant_params)})
    set_condition(ns, name, "Updating", "True", "Applying",
                  f"applying {sorted(_normalize_params(tenant_params))}")

    # Call the runner.
    runner_resp = call_runner(module, spec.get("moduleVersion", "v1"), ns, runner_params)
    if runner_resp is None:
        # Runner URL not configured — pretend success (fake mode, S8-S12 compat).
        logger.info(f"No runner URL, using fake provisioning for {name}")
        _provision_fake(api, ns, name, module)
        patch_applied_params(api, ns, name, tenant_params)
        set_condition(ns, name, "Updating", "False", "Done", "")
        return

    if runner_resp.get("status") != "success":
        error_msg = str(runner_resp.get("error", "unknown runner error"))[:512]
        logger.error(f"Runner failed for {name}: {error_msg}")
        if is_update:
            # The design keeps phase Ready and the old Secret; the condition is
            # the report. attemptedParamsHash stays, so the same desired params
            # are not retried until they change.
            set_condition(ns, name, "Updating", "False", "Done", "")
            set_condition(ns, name, "UpdateFailed", "True", "RunnerError", error_msg)
        else:
            set_condition(ns, name, "Updating", "False", "Done", "")
            patch_status_fields(api, ns, name,
                                {"phase": "Failed", "message": error_msg})
        return

    outputs = runner_resp.get("outputs", {})
    logger.info(f"Runner returned {len(outputs)} outputs for {name}: {list(outputs.keys())[:5]}")

    # Record the generated password in the outputs Secret. It cannot travel back
    # as a module output: the runner reads `tofu output` in plain text, where a
    # sensitive value renders as "<sensitive>" (the postgres module's `url`
    # output is already in that state). The controller knows the value it sent,
    # so it writes that.
    if module == "postgres" and runner_params.get("postgres_password"):
        outputs["POSTGRES_PASSWORD"] = runner_params["postgres_password"]

    changed = _existing_outputs_changed(ns, module, outputs)
    _write_k8s_resources(api, ns, name, module, outputs, allocated_ip, runner_params)

    # appliedParams carries tenant params only - never the password the overlay
    # just added - because claim status is readable by anyone who can get claims.
    patch_applied_params(api, ns, name, tenant_params)
    set_condition(ns, name, "Updating", "False", "Done", "")
    if is_update:
        set_condition(ns, name, "UpdateFailed", "False", "Done", "")
    if changed:
        set_condition(ns, name, "OutputsChanged", "True", "ContractViolation",
                      "an existing output key changed value")
    else:
        set_condition(ns, name, "OutputsChanged", "False", "Done", "")
    logger.info(f"Applied desired params for {name}: {tenant_params}")


def _provision_fake(api, ns, name, module):
    """Fake provisioning mode (S8-S12): just create empty Secret and set Ready."""
    secret_name = f"jit-{module}"
    try:
        core = client.CoreV1Api()
        # A non-empty marker key, so the stale-Ready detector — which requires Secret
        # data — is satisfied and fake mode stops re-provisioning on every event.
        secret_body = client.V1Secret(
            metadata=client.V1ObjectMeta(name=secret_name, namespace=ns),
            data={"fake": base64.b64encode(b"true").decode()},
        )
        try:
            core.create_namespaced_secret(ns, secret_body)
        except client.exceptions.ApiException as e:
            if e.status != 409:
                raise
        patch = {"status": {"phase": "Ready", "outputsSecret": secret_name,
                            "message": ""}}
        api.patch_namespaced_custom_object_status(GROUP, VERSION, ns, PLURAL, name, patch)
        clear_status_field(ns, name, "expiresAt")
        logger.info(f"InfraClaim {name} phase set to Ready (fake mode)")
    except client.exceptions.ApiException:
        pass


def _write_k8s_resources(api, ns, name, module, outputs, fallback_ip, params=None):
    """Write Secret + Service + EndpointSlice from runner outputs."""
    params = params or {}
    secret_name = f"jit-{module}"
    svc_name = f"jit-{module}"

    # Add app-facing connection metadata that uses the controller-written Service.
    # The raw IP outputs stay present for pgadmin and the controller's own use;
    # pods consume the service-hosted URL so they resolve the Service and its
    # EndpointSlice rather than binding to a single container IP.
    outputs = dict(outputs)
    default_port = "6379" if module == "redis" else "5432"
    port = int(outputs.get("port", default_port))
    outputs["service_host"] = svc_name
    if module == "redis":
        outputs["service_url"] = f"redis://{svc_name}:{port}/0"
    elif module == "postgres":
        password = outputs.get("POSTGRES_PASSWORD", "")
        db = params.get("postgres_db") or outputs.get("POSTGRES_DB") or "voting"
        user = params.get("postgres_user") or outputs.get("POSTGRES_USER") or "postgres"
        outputs["POSTGRES_DB"] = db
        outputs["POSTGRES_USER"] = user
        # Percent-encode the password so special characters do not break the DSN.
        quoted_pw = quote(password, safe="")
        outputs["service_url"] = f"postgresql://{user}:{quoted_pw}@{svc_name}:{port}/{db}"

    # Secret with runner outputs.
    try:
        core = client.CoreV1Api()
        secret_data = {k: base64.b64encode(str(v).encode()).decode()
                       for k, v in outputs.items()}
        secret_body = client.V1Secret(
            metadata=client.V1ObjectMeta(name=secret_name, namespace=ns),
            data=secret_data,
        )
        try:
            core.create_namespaced_secret(ns, secret_body)
            logger.info(f"Created Secret {secret_name} in {ns}")
        except client.exceptions.ApiException as e:
            if e.status == 409:
                core.patch_namespaced_secret(secret_name, ns, secret_body)
                logger.info(f"Updated Secret {secret_name} in {ns}")
            else:
                raise
    except Exception as e:
        logger.error(f"Failed to write Secret {secret_name}: {e}")

    # Service (no selector) + EndpointSlice.
    address = outputs.get("address", fallback_ip)
    port = int(outputs.get("port", "6379"))

    create_jit_service(ns, svc_name, port)
    create_jit_endpoint_slice(ns, svc_name, address, port)

    # Set claim to Ready.
    patch = {"status": {"phase": "Ready", "outputsSecret": secret_name,
                         "endpoint": f"{address}:{port}", "message": ""}}
    try:
        api.patch_namespaced_custom_object_status(GROUP, VERSION, ns, PLURAL, name, patch)
        clear_status_field(ns, name, "expiresAt")
        logger.info(f"InfraClaim {name} phase set to Ready (runner)")
    except client.exceptions.ApiException:
        pass


def call_runner(module, version, workspace, params):
    """POST to the runner to provision infra. Returns response dict or None if not configured."""
    if not RUNNER_URL:
        return None
    url = f"{RUNNER_URL}/v1/runs"
    headers = {"Content-Type": "application/json"}
    if RUNNER_TOKEN:
        headers["Authorization"] = f"Bearer {RUNNER_TOKEN}"
    body = {
        "module": module,
        "version": version or "main",
        "workspace": workspace,
        # Structured values survive: the runner's `_var_args` JSON-encodes lists
        # and objects for tofu, and a postgres `databases` list sent as its
        # Python repr (`"['voting']"`) is not valid HCL.
        "params": _normalize_params(params),
    }
    try:
        r = requests.post(url, json=body, timeout=600, headers=headers)
        return r.json()
    except Exception as e:
        logger.error(f"Runner call failed for {workspace}/{module}: {e}")
        return {"status": "error", "error": str(e)}


def create_jit_service(namespace, name, port):
    """Create a headless Service with no selector (for JIT infra endpoints)."""
    core = client.CoreV1Api()
    svc = client.V1Service(
        metadata=client.V1ObjectMeta(name=name, namespace=namespace),
        spec=client.V1ServiceSpec(
            cluster_ip="None",
            ports=[client.V1ServicePort(port=port, target_port=port, protocol="TCP")],
        ),
    )
    try:
        core.create_namespaced_service(namespace, svc)
        logger.info(f"Created Service {name} in {namespace}")
    except client.exceptions.ApiException as e:
        if e.status == 409:
            # A Service that already exists keeps its old ports. Re-state the spec:
            # the port comes from the module's own output, and a stale value (the
            # pgadmin module gained a `port` output in S17, before which the Service
            # advertised redis's default 6379) would leave the EndpointSlice
            # pointing at a closed port.
            try:
                core.patch_namespaced_service(name, namespace, svc)
                logger.info(f"Updated Service {name} in {namespace}")
            except client.exceptions.ApiException as pe:
                logger.warning(f"Failed to update Service {name}: {pe}")
        else:
            logger.warning(f"Failed to create Service {name}: {e}")


def create_jit_endpoint_slice(namespace, svc_name, address, port):
    """Create an EndpointSlice pointing to a JIT container IP."""
    disco = client.DiscoveryV1Api()
    ep = client.V1EndpointSlice(
        metadata=client.V1ObjectMeta(
            name=svc_name,
            namespace=namespace,
            labels={"kubernetes.io/service-name": svc_name},
        ),
        address_type="IPv4",
        endpoints=[
            client.V1Endpoint(
                addresses=[address],
                conditions=client.V1EndpointConditions(ready=True),
            )
        ],
        ports=[
            client.DiscoveryV1EndpointPort(port=port, protocol="TCP", name="tcp")
        ],
    )
    try:
        disco.create_namespaced_endpoint_slice(namespace, ep)
        logger.info(f"Created EndpointSlice {svc_name} in {namespace}")
    except client.exceptions.ApiException as e:
        if e.status == 409:
            logger.info(f"EndpointSlice {svc_name} already exists in {namespace}")
        else:
            logger.warning(f"Failed to create EndpointSlice {svc_name}: {e}")


def clear_status_field(namespace, name, field_path):
    """Clear a field from status by setting it to empty string.

    For expiresAt: only clear if the claim is actually Ready (not stale).
    An empty expiresAt blocks TTL sweep, so we must be careful.
    """
    api = client.CustomObjectsApi()
    try:
        # Only clear if the field actually has a value
        obj = api.get_namespaced_custom_object_status(GROUP, VERSION, namespace, PLURAL, name)
        current = obj.get("status", {}).get(field_path)
        if not current:
            return  # Already empty/absent
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name,
            {"status": {field_path: ""}})
    except Exception as e:
        if "not found" not in str(e).lower() and "404" not in str(e):
            logger.warning(f"Failed to clear status.{field_path} on {name}: {e}")


def list_referencing_deployments_with_params(namespace, module):
    """Return sorted [(name, params)] for Deployments annotating jit.infra/<module>."""
    apps = client.AppsV1Api()
    deploys = apps.list_namespaced_deployment(namespace)
    out = []
    for d in deploys.items:
        annotations = d.metadata.annotations or {}
        raw = annotations.get(f"jit.infra/{module}")
        if raw is None:
            continue
        try:
            params = (json.loads(raw) or {}).get("params", {}) or {}
        except Exception:
            params = {}
        out.append((d.metadata.name, params))
    return sorted(out)


def list_referencing_deployments(namespace, module):
    """List Deployment names in the namespace that annotate jit.infra/<module>."""
    return [name for name, _ in list_referencing_deployments_with_params(namespace, module)]


def _max_reference_ttl(namespace, module):
    """The largest `softDeleteTTL` declared by any reference, by duration (rule 7).

    TTL is lifecycle data, not a setting, so it may appear on declarers and
    consumers alike; the maximum errs in the safe direction once no references
    remain. Returns the raw string of the longest window, or None when no
    reference declares a parseable one.
    """
    apps = client.AppsV1Api()
    best = None
    best_seconds = None
    for d in apps.list_namespaced_deployment(namespace).items:
        raw = (d.metadata.annotations or {}).get(f"jit.infra/{module}")
        if raw is None:
            continue
        try:
            data = json.loads(raw) or {}
        except Exception:
            data = {}
        ttl = data.get("softDeleteTTL")
        m = re.match(r"^(\d+)(s|m|h|d)$", (ttl or "").strip())
        if not m:
            continue
        seconds = int(m.group(1)) * {"s": 1, "m": 60, "h": 3600, "d": 86400}[m.group(2)]
        if best_seconds is None or seconds > best_seconds:
            best, best_seconds = ttl, seconds
    return best


def _normalize_params(params):
    """Params are compared as JSON-safe values.

    Scalars stringify (that is what the retry hash and the runner's `-var`
    transport have always compared), but lists and objects keep their shape:
    postgres `databases` is a list and `settings` an object. Stringifying the
    list to its Python repr hid the container from `validate_params`' removal
    guard - `isinstance(applied["databases"], list)` was never true against the
    stored status - and sent the runner a repr rather than a JSON value.
    """
    def norm(value):
        if isinstance(value, dict):
            return {k: norm(v) for k, v in value.items()}
        if isinstance(value, list):
            return [norm(v) for v in value]
        return str(value)
    return {k: norm(v) for k, v in (params or {}).items()}


def _reference_declarers(namespace, module):
    """Live Deployments annotating jit.infra/<module>: [(name, params, declares)].

    `declares` is True when the annotation carries a `params` key. The key's
    *presence* is the role (design §Terms): `params: {}` declares the defaults,
    a missing key consumes.
    """
    apps = client.AppsV1Api()
    out = []
    for d in apps.list_namespaced_deployment(namespace).items:
        raw = (d.metadata.annotations or {}).get(f"jit.infra/{module}")
        if raw is None:
            continue
        try:
            data = json.loads(raw) or {}
        except Exception:
            data = {}
        out.append((d.metadata.name, data.get("params") or {},
                    "params" in data))
    return sorted(out)


def resolve_desired(refs):
    """Desired params from declarer references only.

    `refs` is `[(name, params, declares)]`. Returns `(desired, declarers,
    conflict)`:

    - no declarers: `(None, [], False)` — the caller distinguishes a new
      consumer-only claim (AwaitingDeclarer) from an existing one (NoDeclarer);
    - declarers disagree: `(None, [...], True)` — desired holds at applied;
    - otherwise: the agreed normalized params, the declarers, False.

    Rule 6 falls out of this: a single declarer after a gap is not a conflict,
    so its params are desired and go through the contract.
    """
    declarers = [(n, p) for n, p, declares in refs if declares]
    if not declarers:
        return None, [], False
    norms = [_normalize_params(p) for _, p in declarers]
    if any(n != norms[0] for n in norms):
        return None, declarers, True
    return norms[0], declarers, False


_IDENTITY_KEYS = ("name", "ip", "network", "postgres_db", "postgres_password",
                  "postgres_user", "postgres_url")
# The condition types the CRD's `status.conditions.type` enum admits
# (deploy/crd/infraclaim.yaml). A type outside it makes the API server reject the
# whole conditions array, so set_condition checks this first rather than let a
# swallowed ApiException drop every condition write in that call. Keep in step with
# the CRD; S25 asserts the two lists match.
_CONDITION_TYPES = (
    "ParamsConflict", "AwaitingDeclarer", "NoDeclarer", "UpdateRefused",
    "Updating", "UpdateFailed", "OutputsChanged",
)
_IDENTIFIER = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
_MAXMEMORY = re.compile(r"^[0-9]+(kb|mb|gb)$")
_PG_SIZE = re.compile(r"^[0-9]+(kB|MB|GB|TB)?$")
_PG_SETTINGS = ("max_connections", "shared_buffers", "work_mem")


# The update contract (design §Mutability contract): which params may *change* on
# a provisioned claim. pgadmin's params are refused on change in v1.
_UPDATE_ALLOWED = {
    "redis": {"maxmemory"},
    "postgres": {"databases", "settings"},
}
# The create surface: the tenant-settable subset of a module's declared inputs,
# so a brand-new claim may carry them without passing the change contract. It is
# the update allowlist plus pgadmin's `http_port` - the module-declared port the
# voting-b overlay pins, the case ADR 0020 hit. It is deliberately not every
# declared variable: the rest (pgadmin's `share_dir`/`postgres_port`/credentials,
# postgres's `service_name`) are controller-supplied, not tenant settings. A key
# outside this surface (a typo, an identity key) is refused on create too, so it
# is never silently recorded as applied.
_CREATE_ALLOWED = {
    "redis": {"maxmemory"},
    "postgres": {"databases", "settings"},
    "pgadmin": {"http_port"},
}


def validate_params(module, desired, applied=None, on_create=False):
    """The per-module param contract. Returns `(ok, bad_key, reason)`.

    A provisioned claim is judged by the update contract (which params may
    change); a brand-new claim by the create surface. Either way a key outside the
    module's v1 surface is refused, so a typo never reaches tofu (which only warns
    on unknown `-var`s and would record it as applied). The whole edit is refused,
    not just the offending key.
    """
    desired = desired or {}
    applied = applied or {}
    allowed = (_CREATE_ALLOWED if on_create else _UPDATE_ALLOWED).get(module, set())

    for key in desired:
        if key in _IDENTITY_KEYS:
            return False, key, "identity or controller-owned, not a tenant setting"
        if key not in allowed:
            return False, key, f"unknown key for module {module}"

    if module == "redis" and "maxmemory" in desired:
        if not _MAXMEMORY.match(str(desired["maxmemory"])):
            return False, "maxmemory", "must match ^[0-9]+(kb|mb|gb)$"

    if module == "postgres":
        if "databases" in desired:
            dbs = desired["databases"]
            if not isinstance(dbs, list) or not all(
                    isinstance(d, str) and _IDENTIFIER.match(d) for d in dbs):
                return False, "databases", "must be a list of identifier-shaped names"
            old = applied.get("databases")
            if isinstance(old, list):
                for d in old:
                    if d not in dbs:
                        return False, "databases", f"removing database {d} is refused"
        if "settings" in desired:
            settings = desired["settings"]
            if not isinstance(settings, dict):
                return False, "settings", "must be an object"
            for key, value in settings.items():
                if key not in _PG_SETTINGS:
                    return False, f"settings.{key}", "not in the v1 settings allowlist"
                if key == "max_connections":
                    try:
                        int(str(value))
                    except ValueError:
                        return False, f"settings.{key}", "must be an integer"
                elif not _PG_SIZE.match(str(value)):
                    return False, f"settings.{key}", "must be a Postgres size"

    if module == "pgadmin" and "http_port" in desired:
        try:
            port = int(str(desired["http_port"]))
        except (TypeError, ValueError):
            return False, "http_port", "must be an integer"
        if not 1 <= port <= 65535:
            return False, "http_port", "must be a port (1-65535)"
    return True, "", ""


def params_hash(module, workspace, params):
    """Hash of module + workspace + normalized params (the retry gate's key)."""
    payload = json.dumps({"module": module, "workspace": workspace,
                          "params": _normalize_params(params)}, sort_keys=True)
    return hashlib.sha256(payload.encode()).hexdigest()


def patch_status_fields(api, namespace, name, fields):
    """Patch status fields in one call; failures are logged, not raised."""
    try:
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name, {"status": fields})
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to patch status {sorted(fields)} on {name}: {e}")


def _merge_patch(old, new):
    """A JSON merge patch that clears keys removed at any depth.

    A JSON merge patch treats `{}` as "change nothing", so a nested dict that
    dropped a key (e.g. `settings.work_mem`) survived a top-level-only clear: the
    resync then saw applied `{"settings": {"work_mem": ...}}` != desired, and
    re-applied on every tick (a container-replace loop). Null the removed keys at
    every depth; a dict present in both recurses, everything else is set from
    `new`.
    """
    if not isinstance(old, dict) or not isinstance(new, dict):
        return new
    patch = {}
    for k, v in old.items():
        if k not in new:
            patch[k] = None
        elif isinstance(v, dict) and isinstance(new[k], dict):
            patch[k] = _merge_patch(v, new[k])
    for k, v in new.items():
        if k not in patch:
            patch[k] = v
    return patch


def patch_applied_params(api, namespace, name, params):
    """Set status.appliedParams, clearing the keys the new params dropped.

    A JSON merge patch treats `{}` as "change nothing", so patching the new,
    smaller dict left every removed key behind: after a change back to defaults
    `appliedParams.maxmemory` survived, the resync saw desired `{}` != applied
    and re-applied forever (a container-replace loop), and a later edit to the
    old value was then judged "equal" and never applied. Null the removed keys in
    the same patch, then set the new ones - at every depth, so a dropped nested
    `settings` key clears too.
    """
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to read {name} before patching appliedParams: {e}")
        return
    old = (obj.get("status", {}) or {}).get("appliedParams") or {}
    patch = _merge_patch(old, params or {})
    try:
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name,
            {"status": {"appliedParams": patch}})
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to patch appliedParams on {name}: {e}")


def _condition_status(status, cond_type):
    for c in (status.get("conditions") or []):
        if c.get("type") == cond_type:
            return c.get("status")
    return None


def _project_spec_params(api, namespace, name, desired):
    """Project the agreed desired params onto spec.params (no-op when equal)."""
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
    except client.exceptions.ApiException:
        return
    existing = (obj.get("spec", {}) or {}).get("params") or {}
    desired = desired or {}
    if existing == desired:
        return
    # A merge patch merges object keys: projecting {"b": "2"} onto {"a": "1"}
    # would leave "a" behind, and a refused key would then travel into the
    # destroy call. Null the keys this projection removes - at every depth, so a
    # dropped nested `settings` key clears too; the desired keys are set in the
    # same patch.
    patch = _merge_patch(existing, desired)
    try:
        api.patch_namespaced_custom_object(
            GROUP, VERSION, namespace, PLURAL, name, {"spec": {"params": patch}})
        logger.info(f"Projected desired params onto {name}: {desired}")
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to project spec.params on {name}: {e}")


def _destroy_params(status, spec):
    """What to send the runner at teardown: the last applied params, not the desired.

    A refused edit leaves spec.params different from what was applied; destroying
    with a refused key makes the real module reject the whole destroy (observed:
    an unknown `wikijunk` var failed S26's teardown). Falls back to spec.params
    for pre-S26 claims, which have no appliedParams.
    """
    return status.get("appliedParams") or spec.get("params", {}) or {}


def _recover_stale_updating(namespace, name, status):
    """Clear a leftover Updating flag when this process does not hold the lock.

    One controller replica: an Updating=True with the claim's lock unlocked is a
    crash's leftover (or a seeded flag), never a live apply.
    """
    if _condition_status(status, "Updating") == "True":
        if not claim_lock(namespace, name).locked():
            set_condition(namespace, name, "Updating", "False", "Stale",
                          "no apply holds the claim lock; cleared for re-evaluation")
            return True
    return False


def apply_update(api, ns, name, module, spec, desired, status):
    """Update path: apply new desired params against an existing provisioned claim."""
    allocated_ip = status.get("allocatedIP", "") or _allocated_ip(api, ns, name)
    if not allocated_ip:
        logger.warning(f"No allocatedIP on {name}, cannot update")
        return
    _apply_via_runner(api, ns, name, module, spec, desired, allocated_ip, is_update=True)


def reconcile_claim(api, ns, name, module, spec, force=False):
    """Level-triggered evaluation of one claim (design §Resolution, §Update flow).

    Runs on every Deployment event and every resync tick. Resolution always reads
    live Deployments, so it survives a controller restart and does not trust the
    event's copy of the annotation.
    """
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
    except client.exceptions.ApiException:
        return
    status = obj.get("status", {}) or {}
    phase = status.get("phase", "")
    if phase == "Deleting":
        return

    _recover_stale_updating(ns, name, status)

    refs = _reference_declarers(ns, module)
    ref_names = sorted(n for n, _, _ in refs)
    desired, declarers, conflict = resolve_desired(refs)
    declarer_names = sorted(n for n, _ in declarers)

    # referencedBy/declaredBy are a recomputation, not an event log.
    patch_status_fields(api, ns, name,
                        {"referencedBy": ref_names, "declaredBy": declarer_names})

    # Rule 7: `spec.softDeleteTTL` is the maximum declared across all references,
    # declarers and consumers alike. It is a spec patch only - never a runner call.
    # Compare against the claim's own spec, not the caller's event copy: on the
    # Deployment-event path `spec` is that Deployment's annotation, not the claim's.
    max_ttl = _max_reference_ttl(ns, module)
    claim_ttl = (obj.get("spec", {}) or {}).get("softDeleteTTL") or ""
    if max_ttl and max_ttl != claim_ttl:
        try:
            api.patch_namespaced_custom_object(
                GROUP, VERSION, ns, PLURAL, name,
                {"spec": {"softDeleteTTL": max_ttl}})
            logger.info(f"softDeleteTTL for {name}: "
                        f"{claim_ttl} -> {max_ttl} (max over references)")
        except client.exceptions.ApiException as e:
            logger.warning(f"Failed to patch softDeleteTTL on {name}: {e}")
        spec = dict(spec, softDeleteTTL=max_ttl)

    if not ref_names:
        return  # orphan/TTL handling lives in the resync branch

    if phase == "Failed" and not force:
        logger.info(f"Reconcile {name}: phase=Failed, not retrying until the "
                    f"Deployment changes")
        return

    if not declarers:
        set_condition(ns, name, "ParamsConflict", "False", "NoDeclarers", "")
        if status.get("appliedParams") or phase in ("Ready", "Orphaned"):
            # An existing claim keeps its applied params; consumers hold the lease.
            set_condition(ns, name, "NoDeclarer", "True", "DeclarerGone",
                          "all declarers are gone; applied params kept")
            set_condition(ns, name, "AwaitingDeclarer", "False", "Done", "")
        else:
            # A new claim with only consumers waits, Pending, for a declarer.
            set_condition(ns, name, "AwaitingDeclarer", "True", "NoDeclarerYet",
                          "a new claim has only consumers")
            set_condition(ns, name, "NoDeclarer", "False", "Done", "")
            if phase != "Pending":
                patch_status_fields(api, ns, name, {"phase": "Pending"})
        return

    set_condition(ns, name, "AwaitingDeclarer", "False", "Done", "")
    set_condition(ns, name, "NoDeclarer", "False", "Done", "")

    if conflict:
        detail = ", ".join(f"{n} wants {p}" for n, p in declarers)
        set_condition(ns, name, "ParamsConflict", "True", "DeclarersDisagree", detail)
        return  # desired holds at applied

    set_condition(ns, name, "ParamsConflict", "False", "DeclarersAgree", "")

    # `resolve_desired` already normalized each declarer (rule 1). Use that one
    # value throughout, so spec.params, appliedParams and validate_params cannot
    # hold the same params in different shapes.
    desired_norm = desired
    # The backfill below adopts what the old controller had projected onto
    # spec.params, so capture it before this reconcile overwrites it with the
    # current desired. Adopting the current desired would record an annotation
    # change made during the upgrade window as applied without a runner call.
    spec_params_before = (obj.get("spec", {}) or {}).get("params") or {}

    applied_raw = status.get("appliedParams") or {}
    applied_norm = _normalize_params(applied_raw)
    provisioned = phase in ("Ready", "Orphaned")

    if provisioned and "appliedParams" not in status:
        # Backfill on upgrade: a Ready claim with no appliedParams adopts the
        # normalized spec.params it carried, without calling the runner, or the
        # first resync after the upgrade would replace every live container. The
        # key's *absence* is the test: an explicit `appliedParams: {}` is a real
        # applied result, and a later non-empty desired must go through the
        # update flow.
        backfilled = _normalize_params(spec_params_before)
        patch_applied_params(api, ns, name, backfilled)
        set_condition(ns, name, "UpdateRefused", "False", "Done", "")
        logger.info(f"Backfilled appliedParams for {name}: {backfilled}")
        return

    if provisioned and applied_norm == desired_norm:
        # Equal: stop. This is what keeps rollouts free. A reappearing reference
        # resurrects an Orphaned claim without a runner call.
        if phase == "Orphaned":
            patch_status_fields(api, ns, name, {"phase": "Ready"})
            clear_status_field(ns, name, "expiresAt")
            logger.info(f"Resurrected {name} from Orphaned")
        set_condition(ns, name, "UpdateRefused", "False", "Done", "")
        return

    # Every path is validated: a provisioned claim against the update contract
    # (which params may *change*, design §Mutability contract), a brand-new claim
    # against the tenant-settable create surface (design :112 "a key the module
    # does not declare -> Refused", :114 "values are validated before any runner
    # call"). Create is not exempt any more - ADR 0020 left it unvalidated to let
    # pgadmin's module-declared `http_port` through, and that also let an
    # unknown/typo'd key be recorded as applied; the create allowlist admits
    # `http_port` while refusing a key the module does not declare.
    ok, bad_key, reason = validate_params(module, desired_norm, applied_raw,
                                          on_create=not provisioned)
    if not ok:
        set_condition(ns, name, "UpdateRefused", "True", "RefusedKey",
                      f"{bad_key}: {reason}")
        return
    set_condition(ns, name, "UpdateRefused", "False", "Done", "")

    # Project only after validation: a refused desired must not land on
    # spec.params, or teardown's `appliedParams or spec.params` fallback would
    # send the refused key to the module, whose destroy then fails and retries
    # forever (the invariant _project_spec_params' comment states).
    _project_spec_params(api, ns, name, desired_norm)

    h = params_hash(module, ns, desired_norm)
    if (h == status.get("attemptedParamsHash")
            and _condition_status(status, "UpdateFailed") == "True"):
        return  # one attempt per desired params; retried only when they change

    with claim_lock(ns, name):
        # Re-read and re-resolve inside the lock: spec can move between the
        # compare above and here (ensure_claim runs outside the lock).
        try:
            obj2 = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
        except client.exceptions.ApiException:
            return
        status2 = obj2.get("status", {}) or {}
        if status2.get("phase", "") == "Deleting":
            return
        refs2 = _reference_declarers(ns, module)
        desired2, declarers2, conflict2 = resolve_desired(refs2)
        if conflict2 or not declarers2:
            return
        if desired2 != desired_norm:
            return  # params moved; the next tick evaluates them
        if status2.get("phase", "") in ("Ready", "Orphaned"):
            apply_update(api, ns, name, module, spec, desired2, status2)
        else:
            provision_infra(api, ns, name, module, spec, desired2)


def set_condition(namespace, name, cond_type, status, reason, message):
    """Add or replace one entry in status.conditions, leaving other types alone."""
    if cond_type not in _CONDITION_TYPES:
        # The whole array is patched at once, and conditions.type is a closed enum,
        # so one out-of-enum type would make the API server reject the patch and
        # drop every condition write in this call. Refuse loudly instead.
        logger.error(f"Refusing unknown condition type {cond_type!r} on {name}: "
                     f"not in the CRD enum {_CONDITION_TYPES}")
        return
    api = client.CustomObjectsApi()
    condition = {
        "type": cond_type,
        "status": status,
        "reason": reason,
        "message": message,
        "lastTransitionTime": datetime.now(timezone.utc).isoformat(),
    }
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
        existing = obj.get("status", {}).get("conditions") or []
        current = next((c for c in existing if c.get("type") == cond_type), None)
        if current and current.get("status") == status and current.get("message") == message:
            return  # already correct — avoid status churn on every resync
        conditions = [dict(c) for c in existing if c.get("type") != cond_type]
        conditions.append(condition)
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name,
            {"status": {"conditions": conditions}})
        logger.info(f"Condition {cond_type}={status} on {name}: {message}")
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to set condition {cond_type} on {name}: {e}")


def clear_condition(namespace, name, cond_type):
    """Remove a condition if it is present. No-op when absent."""
    api = client.CustomObjectsApi()
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
        existing = obj.get("status", {}).get("conditions") or []
        if not any(c.get("type") == cond_type for c in existing):
            return
        conditions = [dict(c) for c in existing if c.get("type") != cond_type]
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name,
            {"status": {"conditions": conditions}})
        logger.info(f"Condition {cond_type} cleared on {name}")
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to clear condition {cond_type} on {name}: {e}")


def parse_ttl(ttl_str):
    """Parse a softDeleteTTL string like '2m', '30d', '1h' into a timedelta."""
    m = re.match(r"^(\d+)(s|m|h|d)$", ttl_str.strip())
    if not m:
        return timedelta(days=30)
    val = int(m.group(1))
    unit = m.group(2)
    return timedelta(seconds={"s": val, "m": val * 60, "h": val * 3600, "d": val * 86400}[unit])


def destroy_infra(namespace, module, allocated_ip="", extra_params=None):
    """Call the runner to destroy infrastructure. Returns True on success.

    extra_params carries the claim's recorded module params: postgres and pgadmin
    cannot be destroyed from a cold work dir without their passwords, and the
    controller otherwise only knows the fixed name/network/ip triple.
    """
    if not RUNNER_URL:
        logger.warning("RUNNER_URL not set, skipping destroy")
        return True
    workspace = namespace
    url = f"{RUNNER_URL}/v1/runs/{workspace}"
    headers = {"Content-Type": "application/json"}
    if RUNNER_TOKEN:
        headers["Authorization"] = f"Bearer {RUNNER_TOKEN}"
    # Module params first, then the mandatory vars, so a stale annotation cannot
    # redirect the destroy at the wrong container. Structured values survive the
    # same way as the apply path: the runner JSON-encodes them for tofu.
    params = _normalize_params(extra_params)
    params["name"] = f"{workspace}-{module}"
    params["network"] = DOCKER_NETWORK
    if allocated_ip:
        params["ip"] = allocated_ip

    # Cold destroy: the claim's recorded params may predate the generated
    # password, because the controller generates it rather than the tenant. The
    # Secret still exists - cleanup_k8s_resources runs only after a successful
    # destroy - so read the value back from there. Once it is gone (postgres
    # destroyed before pgadmin) a placeholder lets tofu evaluate the config and
    # remove the container: deleting a container does not need the real password.
    #
    # postgres_url needs the same treatment and did not have it: the pgadmin module
    # requires it with no default, so once postgres's Secret had been cleaned up the
    # destroy failed on "No value for required variable" and the claim stayed
    # Deleting forever (found by S17's J6, which destroys both in the same sweep).
    if module in ("postgres", "pgadmin"):
        secret = _jit_secret_data(workspace, "postgres")
        params.setdefault("postgres_password",
                          secret.get("POSTGRES_PASSWORD") or "unknown-at-destroy")
        if module == "pgadmin":
            params.setdefault(
                "postgres_url",
                f"{secret['address']}:{secret.get('port', '5432')}"
                if secret.get("address") else "unknown-at-destroy:5432")

    logger.info(f"Destroy {workspace}/{module} vars={sorted(params)}")
    try:
        r = requests.delete(url, json={"module": module, "params": params},
                            timeout=120, headers=headers)
        if r.status_code == 404:
            logger.info(f"Destroy: runner has no run for {workspace}/{module} (404)")
            return True
        if r.status_code != 200:
            logger.warning(
                f"Destroy failed for {workspace}/{module}: HTTP {r.status_code}")
            return False
        # The runner answers HTTP 200 for every logical outcome, so the verdict is in
        # the body: "destroyed" / "not_found" are success, anything else is a failure
        # that must not be treated as a completed destroy.
        result = r.json()
        status = result.get("status", "")
        if status in ("destroyed", "not_found"):
            logger.info(f"Destroy response for {workspace}/{module}: {status}")
            return True
        logger.warning(
            f"Destroy reported failure for {workspace}/{module}: {result}")
        return False
    except Exception as e:
        logger.warning(f"Runner destroy failed for {workspace}/{module}: {e}")
        return False


def cleanup_k8s_resources(namespace, module):
    """Delete Secret, Service, EndpointSlice for a JIT module."""
    core = client.CoreV1Api()
    secret_name = f"jit-{module}"
    svc_name = f"jit-{module}"
    ep_name = f"jit-{module}"
    for kind, delete_fn, name in [
        ("Secret", core.delete_namespaced_secret, secret_name),
        ("Service", core.delete_namespaced_service, svc_name),
    ]:
        try:
            delete_fn(name, namespace)
            logger.info(f"Deleted {kind} {name} in {namespace}")
        except client.exceptions.ApiException as e:
            if e.status != 404:
                logger.warning(f"Failed to delete {kind} {name}: {e}")
    # EndpointSlice uses different API
    disco = client.DiscoveryV1Api()
    try:
        disco.delete_namespaced_endpoint_slice(ep_name, namespace)
        logger.info(f"Deleted EndpointSlice {ep_name} in {namespace}")
    except client.exceptions.ApiException as e:
        if e.status != 404:
            logger.warning(f"Failed to delete EndpointSlice {ep_name}: {e}")


def remove_finalizer_and_delete(namespace, name, finalizer) -> bool:
    """Remove the finalizer from a claim and delete it.

    Returns True only once the claim is gone (a 404 counts: already gone is the
    desired state, not a failure). Both teardown paths gate their IP-block release
    on this value, because the release and the claim's removal have to move
    together: releasing before the claim is really removed releases the block a
    second time on the next tick, and never releasing it - what this used to do on
    the retry path - strands the block for good (S17, docs/evidence/leak-probe2.log).
    """
    api = client.CustomObjectsApi()
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
        finalizers = obj.get("metadata", {}).get("finalizers", [])
        if finalizer in finalizers:
            new_finalizers = [f for f in finalizers if f != finalizer]
            api.patch_namespaced_custom_object(
                GROUP, VERSION, namespace, PLURAL, name,
                {"metadata": {"finalizers": new_finalizers}},
            )
        api.delete_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
        logger.info(f"Deleted claim {name} after TTL expiry")
        return True
    except client.exceptions.ApiException as e:
        if e.status == 404:
            return True
        logger.warning(f"Failed to delete claim {name}: {e}")
        return False


@kopf.timer("jit.io", "v1alpha1", "infraclaims", interval=30, initial_delay=True)
def resync_referenced_by(body, namespace, name, logger, **kwargs):
    """Periodic resync: recompute referencedBy, handle orphaning and TTL sweep."""
    load_kube()
    module = body.get("spec", {}).get("module")
    if not module:
        return

    api = client.CustomObjectsApi()
    ttl_str = body.get("spec", {}).get("softDeleteTTL", "30d")

    # Re-read status fresh: the kopf timer body can lag behind status patches
    # that the controller itself made.
    spec = body.get("spec", {}) or {}
    try:
        obj = api.get_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name)
        status = obj.get("status", {}) or {}
        spec = obj.get("spec", {}) or spec
    except Exception as e:
        # Transport failures (urllib3 MaxRetryError) are not ApiException, so the
        # catch is deliberately broad — but say so, because falling back means a
        # stale phase is being acted on.
        logger.warning(f"Fresh status read failed for {name}, using the handler body "
                       f"instead: {e}")
        status = body.get("status", {}) or {}
    phase = status.get("phase", "")

    refs = list_referencing_deployments(namespace, module)
    if refs and phase != "Deleting":
        # References exist: declarer resolution, the mutability contract, the
        # update flow and provisioning all live in reconcile_claim, recomputed
        # from live Deployments so the answer survives a restart. Failed is
        # terminal until the Deployment changes; reconcile_claim carries that.
        reconcile_claim(api, namespace, name, module, spec)
        if phase == "Ready":
            clear_status_field(namespace, name, "expiresAt")
        logger.info(f"Resync {name}: referencedBy={refs}, phase={phase}")
    else:
        # No references
        if phase == "Deleting":
            # Committed to destruction — retry the destroy+cleanup
            logger.info(f"Resync {name}: retrying destroy (Deleting)")
            if destroy_infra(namespace, module, status.get("allocatedIP", ""),
                             _destroy_params(status, spec)):
                cleanup_k8s_resources(namespace, module)
                # This branch must release the block itself: it is the one path in
                # the teardown machine that used to leave the claim in the ledger.
                # The TTL path's release only runs when its *own* destroy succeeded,
                # and the delete handler deliberately skips phase Deleting — so a
                # sweep that failed and a retry that then succeeded left the block
                # allocated for good, claim and container both gone. Exactly one of
                # the two paths releases any given claim: reaching this line means
                # the claim still exists, so the sweep did not remove it.
                # Found by S17 (docs/evidence/leak-probe2.log).
                if remove_finalizer_and_delete(namespace, name, FINALIZER):
                    release_block(namespace)
                else:
                    logger.warning(
                        f"Not releasing the IP block for {name}: the claim survived "
                        "removal, will retry next tick")
            else:
                logger.warning(f"Destroy retry failed for {name}, will retry next tick")
        elif phase != "Orphaned":
            # Transition to Orphaned, set expiresAt
            ttl = parse_ttl(ttl_str)
            expires = (datetime.now(timezone.utc) + ttl).isoformat()
            patch = {"status": {"referencedBy": refs, "phase": "Orphaned",
                                "expiresAt": expires}}
            try:
                api.patch_namespaced_custom_object_status(
                    GROUP, VERSION, namespace, PLURAL, name, patch)
                logger.info(f"Resync {name}: Orphaned, expiresAt={expires}")
            except client.exceptions.ApiException as e:
                logger.warning(f"Failed to patch {name} to Orphaned: {e}")
        else:
            # Already Orphaned — update refs (skip if unchanged)
            existing_refs = sorted(status.get("referencedBy", []) or [])
            if refs != existing_refs:
                patch = {"status": {"referencedBy": refs}}
                try:
                    api.patch_namespaced_custom_object_status(
                        GROUP, VERSION, namespace, PLURAL, name, patch)
                except client.exceptions.ApiException:
                    pass

            # Check TTL
            expires_at = status.get("expiresAt")
            if expires_at and expires_at != "":
                try:
                    exp = datetime.fromisoformat(expires_at)
                    if exp.tzinfo is None:
                        exp = exp.replace(tzinfo=timezone.utc)
                except (ValueError, TypeError):
                    logger.warning(f"Invalid expiresAt on {name}: {expires_at}")
                    return
                if datetime.now(timezone.utc) > exp:
                    logger.info(f"TTL expired on {name}, sweeping")
                    # Transition to Deleting, then attempt destroy
                    try:
                        api.patch_namespaced_custom_object_status(
                            GROUP, VERSION, namespace, PLURAL, name,
                            {"status": {"phase": "Deleting"}})
                    except client.exceptions.ApiException:
                        pass
                    if destroy_infra(namespace, module, status.get("allocatedIP", ""),
                                     _destroy_params(status, spec)):
                        cleanup_k8s_resources(namespace, module)
                        if remove_finalizer_and_delete(namespace, name, FINALIZER):
                            release_block(namespace)
                        else:
                            logger.warning(
                                f"Not releasing the IP block for {name}: the claim "
                                "survived removal, will retry next tick")
                    else:
                        logger.warning(
                            f"Destroy failed for {name}, claim stays Deleting — "
                            "will retry next tick")


@kopf.on.delete("jit.io", "v1alpha1", "infraclaims")
def handle_claim_delete(body, namespace, name, logger, **kwargs):
    """Hard-delete handler: destroy infra immediately when claim is deleted
    (e.g. namespace deletion via GC), regardless of TTL."""
    load_kube()
    module = body.get("spec", {}).get("module")
    if module:
        logger.info(f"Hard delete triggered for {name} in {namespace}, destroying infra")
        allocated_ip = body.get("status", {}).get("allocatedIP", "")
        params = _destroy_params(body.get("status", {}) or {}, body.get("spec", {}) or {})
        if not destroy_infra(namespace, module, allocated_ip, params):
            # S11 semantics keep namespace deletion unconditional, so the claim is
            # removed regardless — make the leak loud rather than silent.
            logger.error(
                f"Destroy FAILED for {name} ({namespace}/{module}) while deleting the "
                f"claim: the container and its tofu state may leak")
        cleanup_k8s_resources(namespace, module)
    else:
        logger.warning(f"Claim {name} has no module in spec, skipping infra cleanup")

    api = client.CustomObjectsApi()
    finalizers = body.get("metadata", {}).get("finalizers", [])
    if FINALIZER in finalizers:
        new_finalizers = [f for f in finalizers if f != FINALIZER]
        try:
            api.patch_namespaced_custom_object(
                GROUP, VERSION, namespace, PLURAL, name,
                {"metadata": {"finalizers": new_finalizers}},
            )
        except client.exceptions.ApiException:
            pass

    # Release the namespace's IP block once, not twice. A claim the TTL sweep already
    # tore down is in phase Deleting and has had its block released; removing the
    # finalizer there deletes the object, which fires this handler again. Releasing
    # again drives the namespace's claim count to zero while claims still hold
    # addresses, so the block is handed to another namespace and two containers end up
    # with the same IP ("Address already in use"). Found by S17's J1.
    phase = (body.get("status", {}) or {}).get("phase", "")
    if phase == "Deleting":
        logger.info(f"Claim {name} was already swept; not releasing its IP block twice")
    else:
        release_block(namespace)


if __name__ == "__main__":
    load_kube()
    watch_ns_env = os.environ.get("WATCH_NAMESPACES", "")
    namespaces = [ns.strip() for ns in watch_ns_env.split(",") if ns.strip()]
    if namespaces:
        kopf.run(namespaces=namespaces)
    else:
        kopf.run(clusterwide=True)
