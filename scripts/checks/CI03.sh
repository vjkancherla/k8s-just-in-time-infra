#!/usr/bin/env bash
# CI03: the repo builds and the R-suite can pass on amd64.
. "$(dirname "$0")/lib.sh"

describe "The repo builds and the R-suite can pass on amd64" <<'EOF'
Proves: the tofu download, the app image build and the R15 gate no longer
        assume arm64, while a native Mac build still yields arm64 and the
        J-suite's bar is unchanged.
How:    expands the Dockerfile's arch expression on both chips in debian
        containers, builds one app image natively, syntax-checks the edited
        scripts, and runs the shipped R15 block against stub docker/kubectl
        answers for four scenarios.
Needs:  docker with both-platform image pulls, jq, no cluster.
EOF

check "tofu URL takes the chip from dpkg, hardcodes none" "jit-runner/Dockerfile:7" \
  bash -c 'grep -q "dpkg --print-architecture" jit-runner/Dockerfile && ! grep -E "tofu_1\.8\.1_linux_(arm64|amd64)" jit-runner/Dockerfile'

check_eq "the URL expands to linux_amd64 on amd64" "jit-runner/Dockerfile:7, expanded in debian:bookworm-slim" \
  "tofu_1.8.1_linux_amd64.zip" "$(docker run --rm --platform linux/amd64 debian:bookworm-slim bash -c 'echo "tofu_1.8.1_linux_$(dpkg --print-architecture).zip"')"

check_eq "the URL expands to linux_arm64 on arm64" "jit-runner/Dockerfile:7, expanded in debian:bookworm-slim" \
  "tofu_1.8.1_linux_arm64.zip" "$(docker run --rm --platform linux/arm64 debian:bookworm-slim bash -c 'echo "tofu_1.8.1_linux_$(dpkg --print-architecture).zip"')"

require "vote builds natively" "app/scripts/build.sh, non-registry branch" \
  bash -c 'cd app && docker build -q -t vote:ci03-check ./vote >/dev/null'

check_eq "the native build is arm64, as before" "docker inspect vote:ci03-check" \
  "arm64" "$(docker inspect vote:ci03-check --format '{{.Architecture}}'; docker rmi -f vote:ci03-check >/dev/null 2>&1 || true)"

check "bash -n is clean on build.sh" "app/scripts/build.sh" bash -n app/scripts/build.sh
check "bash -n is clean on verify.sh" "app/scripts/verify.sh" bash -n app/scripts/verify.sh

TMPD="$(mktemp -d)"
cat >"$TMPD/bin-docker" <<'EOF'
#!/usr/bin/env bash
echo "$STUB_ARCH"
EOF
cat >"$TMPD/bin-kubectl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *"deploy"* ]]; then
  case "$STUB_MODE" in
    registry-ok) echo '{"items":[{"spec":{"template":{"spec":{"containers":[{"image":"k3d-voting-app-registry.localhost:5000/vote:latest"},{"image":"k3d-voting-app-registry.localhost:5000/worker:latest"},{"image":"k3d-voting-app-registry.localhost:5000/result:latest"}]}}}}]}' ;;
    *) echo '{"items":[{"spec":{"template":{"spec":{"containers":[{"image":"vote:latest"}]}}}}]}' ;;
  esac
else
  case "$STUB_MODE" in
    pods-backoff) echo '{"items":[{"status":{"containerStatuses":[{"state":{"waiting":{"reason":"ImagePullBackOff"}}}]}}]}' ;;
    *) echo '{"items":[{"status":{"containerStatuses":[{"state":{"running":{}}}]}}]}' ;;
  esac
fi
EOF
chmod +x "$TMPD/bin-docker" "$TMPD/bin-kubectl"
sed -n '/---- R15/,/---- R16/p' app/scripts/verify.sh >"$TMPD/r15.sh"

r15() { # REGISTRY STUB_ARCH STUB_MODE -> prints PASS or FAIL per the shipped gate
  local res="$TMPD/result-$1-$2-$3"
  rm -f "$res"
  REGISTRY="$1" STUB_ARCH="$2" STUB_MODE="$3" NS=dummy R15_SRC="$TMPD/r15.sh" R15_RES="$res" \
    PATH="$TMPD:$PATH" bash -c '
      docker() { bin-docker "$@"; }
      kubectl() { bin-kubectl "$@"; }
      rdctl() { echo missing; }
      pass() { echo PASS >"$R15_RES"; }
      fail() { echo FAIL >"$R15_RES"; }
      source "$R15_SRC"
    '
  cat "$res"
}

check_eq "R15 passes on amd64 with 3 registry refs" "app/scripts/verify.sh R15, registry branch" \
  "PASS" "$(r15 1 amd64 registry-ok)"

check_eq "R15 still fails on amd64 with no registry ref" "app/scripts/verify.sh R15, registry branch" \
  "FAIL" "$(r15 1 amd64 registry-missing)"

check_eq "R15 passes on amd64 with no ImagePullBackOff" "app/scripts/verify.sh R15, local branch" \
  "PASS" "$(r15 0 amd64 pods-clean)"

check_eq "R15 still fails on ImagePullBackOff" "app/scripts/verify.sh R15, local branch" \
  "FAIL" "$(r15 0 amd64 pods-backoff)"

rm -rf "$TMPD"

check "J2 still demands the 17 PASS literal" "scripts/verify-jit.sh:208" \
  bash -c 'grep -q "===== 17 PASS, 0 FAIL =====" scripts/verify-jit.sh'

finish
