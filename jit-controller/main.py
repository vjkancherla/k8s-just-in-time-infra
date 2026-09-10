#!/usr/bin/env python3
import base64
import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone

import kopf
import requests
from ipam import allocate_block, release_block
from kubernetes import client, config

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"
FINALIZER = "jit.infra/teardown"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("jit-controller")

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
        provision_infra(api, namespace, claim_name, module, spec)


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

    # IPAM: allocate a block for this namespace (idempotent — returns existing).
    base_ip = allocate_block(ns)
    if base_ip:
        try:
            api.patch_namespaced_custom_object_status(
                GROUP, VERSION, ns, PLURAL, name,
                {"status": {"allocatedIP": base_ip}})
        except client.exceptions.ApiException:
            pass


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
    _write_k8s_resources(api, ns, name, module, outputs, allocated_ip)


def _provision_fake(api, ns, name, module):
    """Fake provisioning mode (S8-S12): just create empty Secret and set Ready."""
    secret_name = f"jit-{module}"
    try:
        core = client.CoreV1Api()
        secret_body = client.V1Secret(
            metadata=client.V1ObjectMeta(name=secret_name, namespace=ns), data={}
        )
        try:
            core.create_namespaced_secret(ns, secret_body)
        except client.exceptions.ApiException as e:
            if e.status != 409:
                raise
        patch = {"status": {"phase": "Ready", "outputsSecret": secret_name}}
        api.patch_namespaced_custom_object_status(GROUP, VERSION, ns, PLURAL, name, patch)
        clear_status_field(ns, name, "expiresAt")
        logger.info(f"InfraClaim {name} phase set to Ready (fake mode)")
    except client.exceptions.ApiException:
        pass


def _write_k8s_resources(api, ns, name, module, outputs, fallback_ip):
    """Write Secret + Service + EndpointSlice from runner outputs."""
    secret_name = f"jit-{module}"
    svc_name = f"jit-{module}"

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
                         "endpoint": f"{address}:{port}"}}
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
            logger.info(f"Service {name} already exists in {namespace}")
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


def list_referencing_deployments(namespace, module):
    """List Deployment names in the namespace that annotate jit.infra/<module>."""
    apps = client.AppsV1Api()
    deploys = apps.list_namespaced_deployment(namespace)
    refs = []
    for d in deploys.items:
        annotations = d.metadata.annotations or {}
        if f"jit.infra/{module}" in annotations:
            refs.append(d.metadata.name)
    return sorted(refs)


def parse_ttl(ttl_str):
    """Parse a softDeleteTTL string like '2m', '30d', '1h' into a timedelta."""
    m = re.match(r"^(\d+)(s|m|h|d)$", ttl_str.strip())
    if not m:
        return timedelta(days=30)
    val = int(m.group(1))
    unit = m.group(2)
    return timedelta(seconds={"s": val, "m": val * 60, "h": val * 3600, "d": val * 86400}[unit])


def destroy_infra(namespace, module, allocated_ip=""):
    """Call the runner to destroy infrastructure. Returns True on success."""
    if not RUNNER_URL:
        logger.warning("RUNNER_URL not set, skipping destroy")
        return True
    workspace = namespace
    url = f"{RUNNER_URL}/v1/runs/{workspace}"
    headers = {"Content-Type": "application/json"}
    if RUNNER_TOKEN:
        headers["Authorization"] = f"Bearer {RUNNER_TOKEN}"
    # Pass all required vars for tofu destroy
    params = {
        "name": f"{workspace}-{module}",
        "network": DOCKER_NETWORK,
    }
    if allocated_ip:
        params["ip"] = allocated_ip
    try:
        r = requests.delete(url, json={"module": module, "params": params},
                            timeout=120, headers=headers)
        logger.info(f"Destroy response for {workspace}/{module}: {r.status_code}")
        return r.status_code in (200, 404)
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


def remove_finalizer_and_delete(namespace, name, finalizer):
    """Remove the finalizer from a claim and delete it."""
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
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to delete claim {name}: {e}")


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
    try:
        obj = api.get_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name)
        status = obj.get("status", {}) or {}
    except client.exceptions.ApiException:
        status = body.get("status", {}) or {}
    phase = status.get("phase", "")

    if refs and phase != "Deleting":
        # References exist: update refs, trigger provisioning if not yet Ready
        if phase != "Ready":
            spec = body.get("spec", {})
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
            if destroy_infra(namespace, module, status.get("allocatedIP", "")):
                cleanup_k8s_resources(namespace, module)
                remove_finalizer_and_delete(namespace, name, FINALIZER)
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
                    if destroy_infra(namespace, module, status.get("allocatedIP", "")):
                        cleanup_k8s_resources(namespace, module)
                        remove_finalizer_and_delete(namespace, name, FINALIZER)
                        release_block(namespace)
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
        destroy_infra(namespace, module, allocated_ip)
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

    release_block(namespace)


if __name__ == "__main__":
    load_kube()
    watch_ns_env = os.environ.get("WATCH_NAMESPACES", "")
    namespaces = [ns.strip() for ns in watch_ns_env.split(",") if ns.strip()]
    if namespaces:
        kopf.run(namespaces=namespaces)
    else:
        kopf.run(clusterwide=True)
