#!/usr/bin/env python3
import base64
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


@kopf.on.login()
def custom_login(**kwargs):
    load_kube()
    return kopf.ConnectionInfo(
        server="https://kubernetes.default.svc",
        ca_path="/var/run/secrets/kubernetes.io/serviceaccount/ca.crt",
        insecure=True,
        token=open("/var/run/secrets/kubernetes.io/serviceaccount/token").read(),
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
        with claim_lock(namespace, claim_name):
            provision_infra(api, namespace, claim_name, module, spec)


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


def provision_infra(api, ns, name, module, spec):
    """Call the runner to provision real infra, then create Secret + Service + EndpointSlice."""
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

    # Compute runner params: annotation params + mandatory overrides.
    allocated_ip = status.get("allocatedIP", "")
    if not allocated_ip:
        logger.warning(f"No allocatedIP on {name}, cannot provision")
        return

    runner_params = dict(spec.get("params", {}))
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

    # Call the runner.
    runner_resp = call_runner(module, spec.get("moduleVersion", "v1"), ns, runner_params)
    if runner_resp is None:
        # Runner URL not configured — pretend success (fake mode, S8-S12 compat).
        logger.info(f"No runner URL, using fake provisioning for {name}")
        _provision_fake(api, ns, name, module)
        return

    if runner_resp.get("status") != "success":
        error_msg = runner_resp.get("error", "unknown runner error")
        logger.error(f"Runner failed for {name}: {error_msg}")
        patch = {"status": {"phase": "Failed", "message": str(error_msg)[:512]}}
        try:
            api.patch_namespaced_custom_object_status(GROUP, VERSION, ns, PLURAL, name, patch)
        except client.exceptions.ApiException:
            pass
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

    _write_k8s_resources(api, ns, name, module, outputs, allocated_ip, runner_params)


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
        "params": {k: str(v) for k, v in params.items()},
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


def _normalize_params(params):
    """Params are compared as strings, matching how they are sent to the runner."""
    return {k: str(v) for k, v in (params or {}).items()}


def set_condition(namespace, name, cond_type, status, reason, message):
    """Add or replace one entry in status.conditions, leaving other types alone."""
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


def check_param_conflict(namespace, name, module, refs, stored_params, status):
    """First writer wins on params.

    The claim keeps the params of the writer that provisioned it. Any other referencing
    Deployment whose annotation params differ is recorded in a ParamsConflict condition
    naming both. The condition is cleared once the conflicting writers are gone or agree.
    """
    has_condition = any(c.get("type") == "ParamsConflict"
                        for c in (status.get("conditions") or []))
    if len(refs) < 2:
        if has_condition:
            clear_condition(namespace, name, "ParamsConflict")
        return

    stored = _normalize_params(stored_params)
    deployments = list_referencing_deployments_with_params(namespace, module)
    matching = [n for n, p in deployments if _normalize_params(p) == stored]
    ignored = [(n, _normalize_params(p)) for n, p in deployments
               if _normalize_params(p) != stored]
    if not ignored:
        if has_condition:
            clear_condition(namespace, name, "ParamsConflict")
        return

    winner = matching[0] if matching else refs[0]
    detail = ", ".join(f"{n} wants {p}" for n, p in ignored)
    set_condition(
        namespace, name, "ParamsConflict", "True", "FirstWriterWins",
        f"{winner} won with params {stored}; ignored: {detail}",
    )


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
    # redirect the destroy at the wrong container.
    params = {k: str(v) for k, v in (extra_params or {}).items()}
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
    refs = list_referencing_deployments(namespace, module)
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

    # First writer wins on params: warn any writer whose params were ignored.
    check_param_conflict(namespace, name, module, refs, spec.get("params", {}), status)

    if refs and phase != "Deleting":
        # References exist: update refs, trigger provisioning if not yet Ready.
        # Failed is terminal: the resync must not re-drive a failing runner every
        # tick. A Deployment change re-fires handle_deployment, which retries.
        if phase == "Failed":
            logger.info(f"Resync {name}: phase=Failed, not retrying until the "
                        f"Deployment changes")
        elif phase != "Ready":
            with claim_lock(namespace, name):
                provision_infra(api, namespace, name, module, spec)
            # Re-read phase after provisioning attempt
            try:
                obj = api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
                phase = obj.get("status", {}).get("phase", "")
            except client.exceptions.ApiException:
                pass
        # If Ready (or still pending), update refs
        try:
            api.patch_namespaced_custom_object_status(
                GROUP, VERSION, namespace, PLURAL, name,
                {"status": {"referencedBy": refs}})
        except client.exceptions.ApiException as e:
            logger.warning(f"Failed to patch {name}: {e}")
        if phase == "Ready":
            clear_status_field(namespace, name, "expiresAt")
            logger.info(f"Resync {name}: referencedBy={refs}, phase=Ready")
    else:
        # No references
        if phase == "Deleting":
            # Committed to destruction — retry the destroy+cleanup
            logger.info(f"Resync {name}: retrying destroy (Deleting)")
            if destroy_infra(namespace, module, status.get("allocatedIP", ""),
                             spec.get("params", {})):
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
                                     spec.get("params", {})):
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
        params = body.get("spec", {}).get("params", {})
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
