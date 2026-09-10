#!/usr/bin/env bash
#
# Checkpoint S2 - MinIO state backend.
# Verifies the `jit-state` bucket exists by listing buckets over the S3 API with an
# AWS Signature v4 request. Uses python3 stdlib only: `mc` is not installed and the
# `aws` CLI here is a broken Python 2 wrapper (missing its awscli module).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
MINIO_IP="172.19.0.11"
BUCKET="jit-state"

# Load fixed root credentials from deploy/.env (gitignored). Parsed with grep.
if [[ -f "$SCRIPT_DIR/deploy/.env" ]]; then
  MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
  MINIO_ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
fi
: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER in deploy/.env}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD in deploy/.env}"

if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 not installed"
  exit 1
fi

AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" \
AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
BUCKET="$BUCKET" \
MINIO_ENDPOINT="${MINIO_ENDPOINT:-http://127.0.0.1:9000}" \
MINIO_HOST="${MINIO_HOST:-127.0.0.1:9000}" \
python3 - <<'PY'
import hashlib, hmac, os, sys, urllib.error, urllib.request
import datetime

endpoint = os.environ["MINIO_ENDPOINT"]
bucket = os.environ["BUCKET"]
region = "us-east-1"
service = "s3"
access = os.environ["AWS_ACCESS_KEY_ID"]
secret = os.environ["AWS_SECRET_ACCESS_KEY"]
host = os.environ["MINIO_HOST"]

now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y%m%dT%H%M%SZ")
date = now.strftime("%Y%m%d")

def sign(key, msg):
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()

canonical_headers = "host:%s\nx-amz-date:%s\n" % (host, ts)
signed_headers = "host;x-amz-date"
payload_hash = hashlib.sha256(b"").hexdigest()
canonical_request = "GET\n/\n\n%s\n%s\n%s" % (canonical_headers, signed_headers, payload_hash)
scope = "%s/%s/%s/aws4_request" % (date, region, service)
string_to_sign = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (
    ts, scope, hashlib.sha256(canonical_request.encode("utf-8")).hexdigest())

k = ("AWS4" + secret).encode("utf-8")
k_date = sign(k, date)
k_region = sign(k_date, region)
k_service = sign(k_region, service)
k_signing = sign(k_service, "aws4_request")
signature = hmac.new(k_signing, string_to_sign.encode("utf-8"), hashlib.sha256).hexdigest()
authorization = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (
    access, scope, signed_headers, signature)

req = urllib.request.Request(endpoint + "/", method="GET")
req.add_header("Host", host)
req.add_header("x-amz-date", ts)
req.add_header("x-amz-content-sha256", payload_hash)
req.add_header("Authorization", authorization)
try:
    body = urllib.request.urlopen(req, timeout=10).read().decode("utf-8", "replace")
except urllib.error.HTTPError as e:
    body = e.read().decode("utf-8", "replace")
except Exception as e:
    print("FAIL: could not reach MinIO at %s: %s" % (endpoint, e))
    sys.exit(1)

if "<Name>%s</Name>" % bucket in body:
    print("PASS: bucket '%s' present at %s" % (bucket, endpoint))
else:
    print("FAIL: bucket '%s' not listed by %s" % (bucket, endpoint))
    print("response:\n%s" % body[:500])
    sys.exit(1)
PY
