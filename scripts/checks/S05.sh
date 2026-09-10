#!/usr/bin/env bash
#
# Checkpoint S5 - modules/pgadmin reachable, connects to Postgres.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$SCRIPT_DIR"

CLUSTER_NET="k3d-voting-app"
PGADMIN_IP="172.19.0.52"
POSTGRES_IP="172.19.0.53"
TEST_NAME="s5-check"
BUCKET="jit-state"
STATE_KEY="ns/s5-test/pgadmin/terraform.tfstate"
TEST_DIR=$(mktemp -d)

if [[ -f "$SCRIPT_DIR/deploy/.env" ]]; then
  MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
  MINIO_ROOT_PASSWORD="$(grep -E '^MINIO_ROOT_PASSWORD=' "$SCRIPT_DIR/deploy/.env" | head -n1 | cut -d= -f2-)"
fi
: "${MINIO_ROOT_USER:?set MINIO_ROOT_USER in deploy/.env}"
: "${MINIO_ROOT_PASSWORD:?set MINIO_ROOT_PASSWORD in deploy/.env}"

export AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER"
export AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD"
export AWS_DEFAULT_REGION="us-east-1"

DOCKER_HOST="${DOCKER_HOST:-}"
if ! docker -H unix:///var/run/docker.sock ps >/dev/null 2>&1; then
  DOCKER_HOST="unix:///Users/vkancherla/.rd/docker.sock"
fi
export DOCKER_HOST

fail() { echo "FAIL: $1"; exit 1; }

cleanup() {
  kubectl delete pod probe-pgadmin --ignore-not-found --timeout=10s >/dev/null 2>&1 || true
  rm -rf "$TEST_DIR"
}
trap cleanup EXIT

cat > "$TEST_DIR/main.tf" <<TFEOF
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
  backend "s3" {
    bucket                      = "$BUCKET"
    key                         = "$STATE_KEY"
    region                      = "us-east-1"
    endpoint                    = "http://127.0.0.1:9000"
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    force_path_style            = true
  }
}

module "postgres" {
  source  = "$SCRIPT_DIR/jit-modules/modules/postgres"
  name    = "$TEST_NAME"
  ip      = "$POSTGRES_IP"
  network = "$CLUSTER_NET"
  postgres_password = "s5-check-password-2026"
  postgres_db       = "voting"
}

module "pgadmin" {
  source  = "$SCRIPT_DIR/jit-modules/modules/pgadmin"
  name       = "$TEST_NAME"
  ip         = "$PGADMIN_IP"
  network    = "$CLUSTER_NET"
  http_port  = 5050
  postgres_url = "${POSTGRES_IP}:5432"
  postgres_port = 5432
  postgres_user = "postgres"
  postgres_password = "s5-check-password-2026"
  pgadmin_email    = "admin@example.com"
  pgadmin_password = "admin"
}
TFEOF

cd "$TEST_DIR"
rm -rf "$TEST_DIR/.terraform"
tofu init -upgrade >/dev/null 2>&1 || fail "tofu init failed"
tofu apply -auto-approve >/dev/null 2>&1 || fail "tofu apply failed"

# 1. Verify pgadmin container has the correct static IP
CONTAINER_IP=$(docker -H "$DOCKER_HOST" inspect "${TEST_NAME}-pgadmin" --format '{{json .NetworkSettings.Networks}}' | python3 -c "import json,sys; print(json.load(sys.stdin)['${CLUSTER_NET}']['IPAddress'])" 2>/dev/null)
[[ "$CONTAINER_IP" == "$PGADMIN_IP" ]] || fail "pgadmin container IP is $CONTAINER_IP, expected $PGADMIN_IP"

# 2. Verify HTTP 200 on the published port (pgAdmin web UI)
for _ in $(seq 1 30); do
  if curl -s -L -o /dev/null -w "%{http_code}" "http://localhost:5050/" 2>/dev/null | grep -q "200"; then
    break
  fi
  sleep 2
done
HTTP_CODE=$(curl -s -L -o /dev/null -w "%{http_code}" "http://localhost:5050/" 2>/dev/null || echo "000")
[[ "$HTTP_CODE" == "200" ]] || fail "pgadmin HTTP returned $HTTP_CODE on $PGADMIN_IP:5050"

# 3. Verify pgadmin container can pg_isready against the Postgres IP
PGADMIN_CONTAINER="${TEST_NAME}-pgadmin"
PGADMIN_HAS_PG=$(docker -H "$DOCKER_HOST" exec "$PGADMIN_CONTAINER" which pg_isready 2>/dev/null || echo "")
if [[ -n "$PGADMIN_HAS_PG" ]]; then
  for _ in $(seq 1 30); do
    if docker -H "$DOCKER_HOST" exec "$PGADMIN_CONTAINER" pg_isready -h "$POSTGRES_IP" -U postgres >/dev/null 2>&1; then
      break
    fi
    sleep 2
  done
  docker -H "$DOCKER_HOST" exec "$PGADMIN_CONTAINER" pg_isready -h "$POSTGRES_IP" -U postgres >/dev/null 2>&1 || \
    fail "pgadmin container could not pg_isready against Postgres at $POSTGRES_IP"
else
  kubectl run probe-pgadmin --restart=Never --image=postgres:16-alpine \
    --env=PGPASSWORD=s5-check-password-2026 \
    -- psql -h "$POSTGRES_IP" -U postgres -d voting -c "SELECT 1;" >/dev/null 2>&1 || \
    fail "cluster probe could not connect to Postgres at $POSTGRES_IP"
fi

# 4. Verify state is in MinIO
AWS_ACCESS_KEY_ID="$MINIO_ROOT_USER" AWS_SECRET_ACCESS_KEY="$MINIO_ROOT_PASSWORD" BUCKET="$BUCKET" STATE_KEY="$STATE_KEY" MINIO_ENDPOINT="http://127.0.0.1:9000" MINIO_HOST="127.0.0.1:9000" python3 - <<'PY'
import hashlib, hmac, os, sys, urllib.error, urllib.request, datetime
endpoint = os.environ["MINIO_ENDPOINT"]
key = os.environ["STATE_KEY"]
access = os.environ["AWS_ACCESS_KEY_ID"]
secret = os.environ["AWS_SECRET_ACCESS_KEY"]
host = os.environ["MINIO_HOST"]
now = datetime.datetime.now(datetime.timezone.utc)
ts = now.strftime("%Y%m%dT%H%M%SZ")
date = now.strftime("%Y%m%d")
def sign(k, msg):
    return hmac.new(k, msg.encode("utf-8"), hashlib.sha256).digest()
ch = "host:%s\nx-amz-date:%s\n" % (host, ts)
sh = "host;x-amz-date"
ph = hashlib.sha256(b"").hexdigest()
cr = "GET\n/%s/%s\n\n%s\n%s\n%s" % (os.environ["BUCKET"], key, ch, sh, ph)
scope = "%s/%s/%s/aws4_request" % (date, "us-east-1", "s3")
sts = "AWS4-HMAC-SHA256\n%s\n%s\n%s" % (ts, scope, hashlib.sha256(cr.encode("utf-8")).hexdigest())
k = ("AWS4" + secret).encode("utf-8")
kd = sign(k, date)
kr = sign(kd, "us-east-1")
ks = sign(kr, "s3")
ksig = sign(ks, "aws4_request")
sig = hmac.new(ksig, sts.encode("utf-8"), hashlib.sha256).hexdigest()
auth = "AWS4-HMAC-SHA256 Credential=%s/%s, SignedHeaders=%s, Signature=%s" % (access, scope, sh, sig)
req = urllib.request.Request("%s/%s/%s" % (endpoint, os.environ["BUCKET"], key), method="GET")
req.add_header("Host", host)
req.add_header("x-amz-date", ts)
req.add_header("x-amz-content-sha256", ph)
req.add_header("Authorization", auth)
try:
    urllib.request.urlopen(req, timeout=10).read()
except urllib.error.HTTPError as e:
    print("FAIL: state object not in MinIO (HTTP %s)" % e.code)
    sys.exit(1)
PY

# 5. Destroy clean
tofu destroy -auto-approve >/dev/null 2>&1 || fail "tofu destroy failed"

docker -H "$DOCKER_HOST" ps -a --filter "name=${TEST_NAME}-pgadmin" --format '{{.Names}}' 2>/dev/null | grep -q "$TEST_NAME" && \
  fail "pgadmin container still exists after destroy"

result=$(tofu destroy -auto-approve 2>&1) || fail "second destroy failed"
echo "$result" | grep -q "Resources: 0 destroyed" || fail "second destroy did not report 0 resources destroyed"

echo "PASS: modules/pgadmin reachable at $PGADMIN_IP:5050, connects to Postgres at $POSTGRES_IP, state in MinIO, destroy clean"
