#!/usr/bin/env python3
import json
import logging
import kopf
from kubernetes import client, config

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"
FINALIZER = "jit.infra/teardown"

logger = logging.getLogger("jit-controller")


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
            logger.info(f"InfraClaim {name} phase set to Ready")
    except client.exceptions.ApiException:
        pass


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


@kopf.timer("jit.io", "v1alpha1", "infraclaims", interval=30, initial_delay=True)
def resync_referenced_by(body, namespace, name, logger, **kwargs):
    """Periodic resync: recompute referencedBy from live Deployments."""
    load_kube()
    module = body.get("spec", {}).get("module")
    if not module:
        return
    refs = list_referencing_deployments(namespace, module)
    patch = {"status": {"referencedBy": refs}}
    api = client.CustomObjectsApi()
    try:
        api.patch_namespaced_custom_object_status(
            GROUP, VERSION, namespace, PLURAL, name, patch
        )
        logger.info(f"Resync {name}: referencedBy={refs}")
    except client.exceptions.ApiException as e:
        logger.warning(f"Failed to patch referencedBy on {name}: {e}")


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
