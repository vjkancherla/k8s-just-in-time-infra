"""One AWS Signature v4 signer for the three places this repo talks to MinIO.

`deploy/minio.sh` creates the bucket, `scripts/state.sh` lists it for the console, and
J11 in `scripts/verify-jit.sh` lists it to gate the run. All three are the same request
with a different method and query string, so they share this instead of each carrying a
copy that has to be kept in step.

The aws CLI is unusable on this host (its shebang is /usr/bin/python, which does not
exist) and `mc` is not installed, so this stays in the standard library rather than
pulling in boto3.

Callers pass SIGV4_DIR (the absolute path to scripts/) on the environment and do:

    sys.path.insert(0, os.environ["SIGV4_DIR"])
    from sigv4 import signed_request

S3's canonical query string encodes "/" as %2F: signing a raw "ns/" and sending it that
way is a SignatureDoesNotMatch. So `query` is always already-encoded, and `list_keys`
below percent-encodes the prefix before building it.
"""

import datetime
import hashlib
import hmac
import urllib.parse
import urllib.request

REGION = "us-east-1"
SERVICE = "s3"


def _sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def signed_request(access, secret, host, method, path, query="",
                   endpoint="", payload=b""):
    """-> an unsigned-body urllib Request carrying a valid SigV4 Authorization header.

    `path` is the bucket, `query` an already-encoded query string, `host` the
    "127.0.0.1:9000" form the signature covers. The caller owns the timeout.
    """
    now = datetime.datetime.now(datetime.timezone.utc)
    ts = now.strftime("%Y%m%dT%H%M%SZ")
    date = now.strftime("%Y%m%d")

    canonical_headers = "host:%s\nx-amz-date:%s\n" % (host, ts)
    signed_headers = "host;x-amz-date"
    payload_hash = hashlib.sha256(payload).hexdigest()
    canonical_request = "%s\n/%s\n%s\n%s\n%s\n%s" % (
        method, path, query, canonical_headers, signed_headers, payload_hash)
    scope = "%s/%s/%s/aws4_request" % (date, REGION, SERVICE)
    string_to_sign = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (
        ts, scope, hashlib.sha256(canonical_request.encode("utf-8")).hexdigest())

    k = ("AWS4" + secret).encode("utf-8")
    k_signing = _sign(_sign(_sign(_sign(k, date), REGION), SERVICE), "aws4_request")
    signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()

    url = "%s/%s" % (endpoint, path)
    if query:
        url += "?" + query
    req = urllib.request.Request(url, method=method, data=payload or None)
    req.add_header("Host", host)
    req.add_header("x-amz-date", ts)
    req.add_header("x-amz-content-sha256", payload_hash)
    req.add_header("Authorization",
                   "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s"
                   % (access, scope, signed_headers, signature))
    return req


def list_keys(access, secret, host, bucket, prefix="", endpoint="", timeout=10):
    """-> sorted list of object keys under `prefix`, or raises urllib's HTTPError."""
    import xml.etree.ElementTree as ET

    query = "list-type=2"
    if prefix:
        query += "&prefix=" + urllib.parse.quote(prefix, safe="")
    req = signed_request(access, secret, host, "GET", bucket, query=query,
                         endpoint=endpoint)
    body = urllib.request.urlopen(req, timeout=timeout).read()
    ns = {"s3": "http://s3.amazonaws.com/doc/2006-03-01/"}
    return sorted(c.find("s3:Key", ns).text
                  for c in ET.fromstring(body).findall("s3:Contents", ns))
