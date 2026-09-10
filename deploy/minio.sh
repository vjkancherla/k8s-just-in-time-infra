#!/usr/bin/env bash
#
# S2 - MinIO as the Terraform state backend.
#
# Runs MinIO on the k3d-voting-app network at the static IP 172.19.0.11, with the
# console published to a host port (never 5000 - AirPlay claims it on macOS). Fixed
# root credentials live in deploy/.env (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Load fixed root credentials from deploy/.env (gitignored). Parsed with grep
# rather than sourced: sourcing fails under the tool's shell for this file.
if [[ -f .env ]]; then
  MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' .env | head -n1 | cut -d= -f2-)"
  MINIO_ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' .env | head -n1 | cut -d= -f2-)"
fi

# Fixed root credentials (see deploy/.env).
: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER in deploy/.env}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD in deploy/.env}"

NET="k3d-voting-app"
MINIO_IP="172.19.0.11"
API_PORT=9000
API_HOST_PORT=9000
CONSOLE_HOST_PORT=9001
BUCKET="jit-state"

MINIO_ENDPOINT="http://127.0.0.1:${API_HOST_PORT}"

export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_DEFAULT_REGION="us-east-1"

# Recreate so the IP is pinned and state is clean per run.
docker rm -f minio >/dev/null 2>&1 || true

docker run -d --name minio \
  --network "$NET" --ip "$MINIO_IP" \
  -v minio-data:/data \
  -e "MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
  -e "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
  -p "${API_HOST_PORT}:${API_PORT}" \
  -p "${CONSOLE_HOST_PORT}:9001" \
  minio/minio server /data \
  --address ":${API_PORT}" --console-address ":9001" >/dev/null

# Wait for the API to become ready.
for _ in $(seq 1 30); do
  if curl -fsS "${MINIO_ENDPOINT}/minio/health/ready" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

# Create the state bucket via an AWS Signature v4 PUT (the aws CLI here is broken).
AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" \
AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" \
BUCKET="$BUCKET" \
MINIO_HOST="127.0.0.1:${API_HOST_PORT}" \
python3 - <<'PY'
import hashlib, hmac, os, sys, urllib.error, urllib.request
import datetime

endpoint = "http://127.0.0.1:%d" % 9000
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
canonical_request = "PUT\n/%s\n\n%s\n%s\n%s" % (bucket, canonical_headers, signed_headers, payload_hash)
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

req = urllib.request.Request("%s/%s" % (endpoint, bucket), method="PUT", data=b"")
req.add_header("Host", host)
req.add_header("x-amz-date", ts)
req.add_header("x-amz-content-sha256", payload_hash)
req.add_header("Authorization", authorization)
try:
    code = urllib.request.urlopen(req, timeout=10).getcode()
except urllib.error.HTTPError as e:
    code = e.code
    detail = e.read().decode("utf-8", "replace")
    # 409 BucketAlreadyOwnedByYou is success: the bucket exists and is ours. The
    # named volume survives `docker rm -f minio` above, so this is the normal case
    # on a second run - and `make jit-up` has to be re-runnable (S17).
    if code == 409 and "BucketAlreadyOwnedByYou" in detail:
        code = 200
    elif code in (200, 201, 204):
        pass
    else:
        print("FAIL: create-bucket returned HTTP %s: %s" % (code, detail[:500]))
        sys.exit(1)
except Exception as e:
    print("FAIL: could not create bucket %s: %s" % (bucket, e))
    sys.exit(1)

if code not in (200, 201, 204):
    print("FAIL: create-bucket returned HTTP %s" % code)
    sys.exit(1)
print("OK: bucket '%s' created" % bucket)
PY

echo "MinIO up at ${MINIO_ENDPOINT} (console http://localhost:${CONSOLE_HOST_PORT}); bucket ${BUCKET} ready"
