#!/usr/bin/env python3
import json
import logging
import os
import re
from datetime import datetime, timedelta, timezone

import kopf
import requests
from kubernetes import client, config

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"
FINALIZER = "jit.infra/teardown"

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
logger = logging.getLogger("jit-controller")

RUNNER_URL = os.environ.get("RUNNER_URL", "")
RUNNER_TOKEN = os.environ.get("RUNNER_TOKEN", "")


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
        ensure_ready(api, namespace, claim_name, module)


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


def ensure_ready(api, ns, name, module):
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
        status = obj.get("status", {})
        if status.get("phase") != "Ready":
            core = client.CoreV1Api()
            secret_name = f"jit-{module}"
            secret_body = client.V1Secret(
                metadata=client.V1ObjectMeta(name=secret_name, namespace=ns), data={}
            )
            try:
                core.create_namespaced_secret(ns, secret_body)
                logger.info(f"Created Secret {secret_name} in {ns}")
            except client.exceptions.ApiException as e:
                if e.status != 409:
                    raise
            patch = {"status": {"phase": "Ready", "outputsSecret": secret_name}}
            api.patch_namespaced_custom_object_status(
                GROUP, VERSION, ns, PLURAL, name, patch
            )
            clear_status_field(ns, name, "expiresAt")
            logger.info(f"InfraClaim {name} phase set to Ready")
    except client.exceptions.ApiException:
        pass


def clear_status_field(namespace, name, field_path):
    """Remove a field from status using JSON Patch (strategic merge can't remove fields)."""
    api = client.CustomObjectsApi()
    patch = [{"op": "remove", "path": f"/status/{field_path}"}]
    try:
        api.api_client.call_api(
            f"/apis/{GROUP}/{VERSION}/namespaces/{namespace}/{PLURAL}/{name}/status",
            "PATCH", body=patch,
            header_params={"Content-Type": "application/json-patch+json"},
            auth_settings=["BearerToken"],
        )
    except Exception as e:
        # Field may already be absent — that's fine
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


def destroy_infra(namespace, module):
    """Call the runner to destroy infrastructure. Returns True on success."""
    if not RUNNER_URL:
        logger.warning("RUNNER_URL not set, skipping destroy")
        return False
    workspace = namespace
    url = f"{RUNNER_URL}/v1/runs/{workspace}"
    headers = {}
    if RUNNER_TOKEN:
        headers["Authorization"] = f"Bearer {RUNNER_TOKEN}"
    try:
        r = requests.delete(url, timeout=120, headers=headers)
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
    status = body.get("status", {}) or {}
    phase = status.get("phase", "")
    ttl_str = body.get("spec", {}).get("softDeleteTTL", "30d")

    if refs and phase != "Deleting":
        # References exist: ensure Ready, clear expiresAt
        # (but NOT if committed to destruction — no resurrection from Deleting)
        patch = {"status": {"referencedBy": refs, "phase": "Ready"}}
        try:
            api.patch_namespaced_custom_object_status(
                GROUP, VERSION, namespace, PLURAL, name, patch)
            clear_status_field(namespace, name, "expiresAt")
            logger.info(f"Resync {name}: referencedBy={refs}, phase=Ready")
        except client.exceptions.ApiException as e:
            logger.warning(f"Failed to patch {name}: {e}")
    else:
        # No references
        if phase == "Deleting":
            # Committed to destruction — retry the destroy+cleanup
            logger.info(f"Resync {name}: retrying destroy (Deleting)")
            if destroy_infra(namespace, module):
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
                logger.warning(f"Failed to patch {name}: {e}")
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
                    if destroy_infra(namespace, module):
                        cleanup_k8s_resources(namespace, module)
                        remove_finalizer_and_delete(namespace, name, FINALIZER)
                    else:
                        logger.warning(
                            f"Destroy failed for {name}, claim stays Deleting — "
                            "will retry next tick")


@kopf.on.delete("jit.io", "v1alpha1", "infraclaims")
def handle_claim_delete(body, namespace, name, **kwargs):
    load_kube()
    api = client.CustomObjectsApi()
    finalizers = body.get("metadata", {}).get("finalizers", [])
    if FINALIZER in finalizers:
        new_finalizers = [f for f in finalizers if f != FINALIZER]
        body["metadata"]["finalizers"] = new_finalizers
        try:
            api.patch_namespaced_custom_object(
                GROUP, VERSION, namespace, PLURAL, name, body
            )
        except client.exceptions.ApiException:
            pass


if __name__ == "__main__":
    load_kube()
    kopf.run(namespaces=["default"])
