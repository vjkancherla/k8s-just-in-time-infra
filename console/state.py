#!/usr/bin/env python3
"""
Read the JIT stack and print one JSON object on stdout.

Reads the same sources the frozen checks read: kubectl, the jit-ipam ConfigMap,
docker, and the MinIO data directory. Computes nothing - expiresAt is passed
through exactly as the controller wrote it.

Never raises. If there is no cluster it prints {"up": false, ...} and exits 0,
because the page polls this before anything exists.

    python3 console/state.py
"""

import json
import subprocess
import datetime
import sys

TIMEOUT = 15


# ----------------------------------------------------------------- helpers

def sh(*args):
    """Run a command. Return stdout, or '' if anything at all goes wrong."""
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=TIMEOUT)
        return r.stdout if r.returncode == 0 else ""
    except Exception:
        return ""


def jload(text):
    try:
        return json.loads(text) if text.strip() else None
    except Exception:
        return None


def dig(d, *path, default=None):
    """Walk a nested dict safely."""
    for k in path:
        if not isinstance(d, dict) or k not in d:
            return default
        d = d[k]
    return d if d is not None else default


# ------------------------------------------------------------------ claims

def read_claims():
    """
    -> {namespace: [claim, ...]}

    ADJUST HERE if your CRD names these fields differently. Everything else in
    the console is driven off this shape.
    """
    doc = jload(sh("kubectl", "get", "infraclaims", "-A", "-o", "json"))
    out = {}
    for item in (doc or {}).get("items", []):
        meta = item.get("metadata", {})
        spec = item.get("spec", {})
        status = item.get("status", {})

        ns = meta.get("namespace", "unknown")
        module = spec.get("module") or meta.get("name", "").split("-")[-1]

        address = (status.get("address")
                   or dig(status, "endpoint", "address")
                   or spec.get("address"))

        refs = status.get("referencedBy") or []
        if isinstance(refs, str):
            refs = [r for r in refs.split(",") if r]
        refs = [r.get("name", str(r)) if isinstance(r, dict) else str(r) for r in refs]

        out.setdefault(ns, []).append({
            "module": module,
            "phase": status.get("phase") or "Unknown",
            "address": address,
            "referencedBy": refs,
            "expiresAt": status.get("expiresAt"),
        })

    for ns in out:
        out[ns].sort(key=lambda c: c["module"])
    return out


# -------------------------------------------------------------------- ipam

def read_blocks():
    """-> {namespace: 'x.x.x.a-b'} from the jit-ipam ConfigMap. Best effort."""
    doc = jload(sh("kubectl", "get", "cm", "jit-ipam", "-n", "default", "-o", "json"))
    data = (doc or {}).get("data", {}) or {}
    blocks = {}
    for ns, raw in data.items():
        parsed = jload(raw)
        if isinstance(parsed, dict):
            base = parsed.get("base") or parsed.get("start") or parsed.get("block")
            size = parsed.get("size") or parsed.get("count") or 10
            if base:
                try:
                    head, last = str(base).rsplit(".", 1)
                    blocks[ns] = f"{base}-{int(last) + int(size) - 1}"
                    continue
                except Exception:
                    blocks[ns] = str(base)
                    continue
        if isinstance(raw, str) and raw.strip():
            blocks[ns] = raw.strip()
    return blocks


# -------------------------------------------------------------- containers

def read_containers():
    lines = sh("docker", "ps", "-a", "--format", "{{.Names}}\t{{.State}}").splitlines()
    rows = []
    for line in lines:
        if "\t" not in line:
            continue
        name, state = line.split("\t", 1)
        if not (name.startswith("jit-") or "voting-" in name):
            continue
        rows.append({"name": name, "state": state.strip()})

    if rows:
        names = [r["name"] for r in rows]
        fmt = "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}"
        ips = sh("docker", "inspect", "-f", fmt, *names).splitlines()
        for r, ip in zip(rows, ips):
            r["address"] = (ip.split() or [None])[0]

    return [{"name": r["name"],
             "address": r.get("address"),
             "running": r["state"] == "running"} for r in rows]


# ---------------------------------------------------------------- ingress

def read_ingress_ports():
    """
    The host ports k3d published for the cluster's :80 and :443.
    On this app that is 8081 and 8082 - read, not assumed.
    """
    names = sh("docker", "ps", "--filter", "name=serverlb",
               "--format", "{{.Names}}").split()
    ports = {"http": None, "https": None}
    if not names:
        return ports
    for scheme, container_port in (("http", "80/tcp"), ("https", "443/tcp")):
        for line in sh("docker", "port", names[0], container_port).splitlines():
            if ":" in line:
                try:
                    ports[scheme] = int(line.rsplit(":", 1)[1])
                    break
                except ValueError:
                    pass
    return ports


def read_ingresses():
    """-> {namespace: [{host, path, service, tls}]}, straight from the cluster."""
    doc = jload(sh("kubectl", "get", "ingress", "-A", "-o", "json"))
    out = {}
    for item in (doc or {}).get("items", []):
        ns = dig(item, "metadata", "namespace", default="unknown")

        secured = set()
        for tls in dig(item, "spec", "tls", default=[]) or []:
            for h in tls.get("hosts", []) or []:
                secured.add(h)

        for rule in dig(item, "spec", "rules", default=[]) or []:
            host = rule.get("host") or "localhost"
            for path in dig(rule, "http", "paths", default=[]) or []:
                entry = {
                    "host": host,
                    "path": path.get("path") or "/",
                    "service": dig(path, "backend", "service", "name", default=""),
                    "tls": host in secured,
                }
                rows = out.setdefault(ns, [])
                if entry not in rows:
                    rows.append(entry)
    return out


# ------------------------------------------------------------ state objects

def read_objects():
    """MinIO's filesystem backend stores each object as a directory of parts."""
    raw = sh("docker", "exec", "jit-minio", "find", "/data/jit-state",
             "-name", "xl.meta", "-maxdepth", "6")
    keys = []
    for line in raw.splitlines():
        key = line.replace("/data/jit-state/", "").rsplit("/", 1)[0]
        if key and key not in keys:
            keys.append(key)
    return sorted(keys)


# ------------------------------------------------------------------- main

def build():
    claims = read_claims()
    blocks = read_blocks()
    containers = read_containers()
    ingresses = read_ingresses()

    names = sorted(set(claims) | set(ingresses))
    namespaces = [{
        "name": ns,
        "block": blocks.get(ns),
        "claims": claims.get(ns, []),
        "ingresses": ingresses.get(ns, []),
    } for ns in names]

    return {
        "up": bool(namespaces) or any(c["running"] for c in containers),
        "ingressPorts": read_ingress_ports(),
        "generatedAt": datetime.datetime.now(datetime.timezone.utc)
                          .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "namespaces": namespaces,
        "containers": containers,
        "stateObjects": read_objects() if containers else [],
    }


if __name__ == "__main__":
    try:
        state = build()
    except Exception as e:            # never fail - the page polls this
        state = {"up": False, "generatedAt": None, "namespaces": [],
                 "containers": [], "stateObjects": [], "error": str(e)}
    json.dump(state, sys.stdout, indent=2)
    sys.stdout.write("\n")
