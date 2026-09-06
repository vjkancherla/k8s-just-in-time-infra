#!/usr/bin/env python3
import kopf
import json
from kubernetes import client, config
from kubernetes.client.rest import ApiException

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"

def get_namespace_name(obj):
    return obj.metadata.namespace

@kopf.on.create('apps')
def deployment_created(event, **kwargs):
    return handle_deployment(event, **kwargs)

@kopf.on.update('apps')
def deployment_updated(event, **kwargs):
    return handle_deployment(event, **kwargs)

def parse_annotation(deployment):
    ann = deployment.metadata.annotations or {}
    claims = []
    for k, v in ann.items():
        if k.startswith('jit.infra/'):
            module = k.split('/',1)[1]
            try:
                data = json.loads(v)
            except Exception:
                data = {}
            data['module'] = module
            claims.append(data)
    return claims

def handle_deployment(event, **kwargs):
    deployment = event
    ns = get_namespace_name(deployment)
    claims = parse_annotation(deployment)
    api = client.CustomObjectsApi()
    for claim_spec in claims:
        module = claim_spec['module']
        name = f"{ns}-{module}"
        spec = {
            'module': module,
            'moduleVersion': claim_spec.get('moduleVersion','v1'),
            'params': claim_spec.get('params',{}),
            'softDeleteTTL': claim_spec.get('softDeleteTTL','30d')
        }
        body = {
            'apiVersion': f'{GROUP}/{VERSION}',
            'kind': 'InfraClaim',
            'metadata': {
                'name': name,
                'namespace': ns,
                'ownerReferences': [{
                    'apiVersion': 'v1',
                    'kind': 'Namespace',
                    'name': ns,
                    'uid': '',
                    'blockOwnerDeletion': True
                }],
                'finalizers': ['jit.infra/teardown']
            },
            'spec': spec,
            'status': {}
        }
        try:
            api.create_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, body)
        except ApiException as e:
            if e.status != 409:
                raise
        # ensure status Ready and secret exists
        ensure_ready(ns, name, module)

def ensure_ready(namespace, name, module):
    api = client.CustomObjectsApi()
    crd_api = client.CustomObjectsApi()
    try:
        obj = crd_api.get_namespaced_custom_object(GROUP, VERSION, namespace, PLURAL, name)
        status = obj.get('status',{})
        if status.get('phase') != 'Ready':
            # fake provisioner
            core = client.CoreV1Api()
            secret_name = f'jit-{module}'
            secret_body = client.V1Secret(
                metadata=client.V1ObjectMeta(name=secret_name, namespace=namespace),
                data={}
            )
            try:
                core.create_namespaced_secret(namespace, secret_body)
            except ApiException as e:
                if e.status != 409:
                    raise
            # patch status
            patch = {'status': {'phase':'Ready','outputsSecret': secret_name}}
            crd_api.patch_namespaced_custom_object_status(GROUP, VERSION, namespace, PLURAL, name, patch)
    except ApiException:
        pass

if __name__ == '__main__':
    config.load_incluster_config()
    kopf.run()
