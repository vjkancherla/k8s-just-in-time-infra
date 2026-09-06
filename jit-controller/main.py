#!/usr/bin/env python3
import time, json
from kubernetes import client, config

GROUP = "jit.io"
VERSION = "v1alpha1"
PLURAL = "infraclaims"

def load_kube():
    try:
        config.load_incluster_config()
    except Exception:
        config.load_kube_config()

def parse_annotation(dep):
    ann = dep.metadata.annotations or {}
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

def ensure_claim(ns, name, spec):
    api = client.CustomObjectsApi()
    core = client.CoreV1Api()
    ns_obj = core.read_namespace(ns)
    uid = ns_obj.metadata.uid
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
                'uid': uid,
                'blockOwnerDeletion': True
            }],
            'finalizers': ['jit.infra/teardown']
        },
        'spec': spec,
        'status': {}
    }
    try:
        api.create_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, body)
    except client.exceptions.ApiException as e:
        if e.status != 409:
            raise

def ensure_ready(ns, name, module):
    api = client.CustomObjectsApi()
    try:
        obj = api.get_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name)
        status = obj.get('status', {})
        if status.get('phase') != 'Ready':
            core = client.CoreV1Api()
            secret_name = f'jit-{module}'
            secret_body = client.V1Secret(
                metadata=client.V1ObjectMeta(name=secret_name, namespace=ns),
                data={}
            )
            try:
                core.create_namespaced_secret(ns, secret_body)
            except client.exceptions.ApiException as e:
                if e.status != 409:
                    raise
            patch = {'status': {'phase':'Ready','outputsSecret': secret_name}}
            api.patch_namespaced_custom_object_status(GROUP, VERSION, ns, PLURAL, name, patch)
    except client.exceptions.ApiException:
        pass

def handle_finalizers():
    api = client.CustomObjectsApi()
    try:
        objs = api.list_cluster_custom_object(GROUP, VERSION, PLURAL)
        for item in objs.get('items', []):
            meta = item.get('metadata', {})
            ns = meta.get('namespace')
            name = meta.get('name')
            if not ns:
                continue
            if meta.get('deletionTimestamp'):
                finalizers = meta.get('finalizers', [])
                if 'jit.infra/teardown' in finalizers:
                    body = {'metadata': {'finalizers': [f for f in finalizers if f != 'jit.infra/teardown']}}
                    try:
                        api.patch_namespaced_custom_object(GROUP, VERSION, ns, PLURAL, name, body)
                    except client.exceptions.ApiException:
                        pass
    except Exception:
        pass

def main():
    load_kube()
    apps_api = client.AppsV1Api()
    print('jit-controller polling started')
    seen = set()
    while True:
        try:
            deps = apps_api.list_deployment_for_all_namespaces()
            for dep in deps.items:
                ns = dep.metadata.namespace
                for claim_spec in parse_annotation(dep):
                    module = claim_spec['module']
                    name = f"{ns}-{module}"
                    spec = {
                        'module': module,
                        'moduleVersion': claim_spec.get('moduleVersion','v1'),
                        'params': claim_spec.get('params',{}),
                        'softDeleteTTL': claim_spec.get('softDeleteTTL','30d')
                    }
                    key = (ns, name)
                    if key not in seen:
                        seen.add(key)
                        ensure_claim(ns, name, spec)
                    ensure_ready(ns, name, module)
            handle_finalizers()
        except Exception as e:
            print(f'error: {e}')
        time.sleep(5)

if __name__ == '__main__':
    main()
