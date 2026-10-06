#!/usr/bin/env bash
# scripts/checks/lib.sh. Every checkpoint sources it.
#
# It is what makes a checkpoint explain itself: what the step proves, one line per check
# as it runs, and - on a failure - what was expected, what was found, and where to look.
#
# A checkpoint has this shape:
#
#     #!/usr/bin/env bash
#     . "$(dirname "$0")/lib.sh"
#
#     describe "Reconciler ignores a duplicate request" <<'EOF'
#     Proves: a second identical request creates nothing new.
#     How:    sends the same request twice to the stub and counts the objects.
#     Needs:  the stub from CI05 running on :8080.
#     EOF
#
#     require  "stub answers on :8080"  "start it: make stub"  curl -fsS localhost:8080/healthz
#     check_eq "first request creates one object"  "src/reconciler.py, reconcile()"  1 "$(count)"
#     check_eq "second request creates nothing"    "reconcile(), the existence test"  1 "$(count)"
#
#     finish
#
#   describe "<title>" <<'EOF' ... EOF     the summary. Plain English, for the human.
#   check    "<what>" "<where to look>" cmd [args...]     passes if cmd exits 0
#   check_eq "<what>" "<where to look>" expected actual   passes if the two are equal
#   require / require_eq                    the same, but stop if it fails - for a
#                                           precondition every later check depends on
#   note "<text>"                           a line of explanation between checks
#   finish                                  mandatory last line; prints the verdict
#
# For a pipeline or anything with a redirect, wrap it in a function and pass its name.
#
# The first argument of every check is on the same line as the check and in double
# quotes. `scripts/ci-checkpoint.sh CI<NN> --explain` lists them by reading the script.
set -Eeuo pipefail

_cp_step="$(basename "${0:-S??}" .sh)"
_cp_n=0
_cp_failed=0
_cp_last=ok
_cp_stopped=""
_cp_done=0
_cp_err=""

trap '_cp_err="line ${LINENO}: ${BASH_COMMAND}"' ERR
trap '_cp_on_exit $?' EXIT

_cp_on_exit() {
  # Reached only when the script ended without finish: a command outside any check
  # failed, or the last line was forgotten. Either way, say so instead of going quiet.
  [ "$_cp_done" -eq 1 ] && return 0
  echo
  if [ "$1" -ne 0 ]; then
    echo "FAIL: ${_cp_step} - the script stopped before its verdict (exit $1)"
    if [ -n "$_cp_err" ]; then echo "        at ${_cp_err}"; fi
    echo "        a command outside any check failed - usually setup, not your change"
  else
    echo "FAIL: ${_cp_step} - ended without calling finish, so it reached no verdict"
    trap - EXIT
    exit 1
  fi
}

describe() {
  echo "== ${_cp_step}  $1"
  if [ ! -t 0 ]; then sed 's/^/   /'; fi
  echo
  if [ "${CHECKPOINT_EXPLAIN:-0}" = "1" ]; then
    _cp_done=1
    exit 0
  fi
}

note() { echo "  -- $1"; }

_cp_report() {  # desc hint rc detail
  _cp_n=$((_cp_n + 1))
  if [ "$3" -eq 0 ]; then
    _cp_last=ok
    printf '  [%d] ok    %s\n' "$_cp_n" "$1"
    return 0
  fi
  _cp_last=fail
  _cp_failed=$((_cp_failed + 1))
  printf '  [%d] FAIL  %s\n' "$_cp_n" "$1"
  printf '%s\n' "$4" | sed 's/^/        /'
  printf '        look at:  %s\n' "$2"
}

check() {
  local desc="$1" hint="$2" out rc=0 detail
  shift 2
  out="$("$@" 2>&1)" || rc=$?
  detail="ran:      $*"$'\n'"exit:     ${rc}"
  if [ -n "$out" ]; then
    detail="${detail}"$'\n'"$(printf '%s\n' "$out" | tail -n 10 | sed 's/^/| /')"
  fi
  _cp_report "$desc" "$hint" "$rc" "$detail"
}

check_eq() {
  local rc=0
  [ "$3" = "$4" ] || rc=1
  _cp_report "$1" "$2" "$rc" "expected: $3"$'\n'"found:    $4"
}

_cp_stop_if_failed() {
  [ "$_cp_last" = ok ] && return 0
  echo "        stopping here - every later check depends on this one"
  _cp_stopped=" (stopped early)"
  finish
}

require()    { check "$@";    _cp_stop_if_failed; }
require_eq() { check_eq "$@"; _cp_stop_if_failed; }

finish() {
  _cp_done=1
  echo
  if [ "$_cp_n" -eq 0 ]; then
    echo "FAIL: ${_cp_step} - no checks ran. A checkpoint that asserts nothing proves nothing."
    exit 1
  fi
  if [ "$_cp_failed" -gt 0 ]; then
    echo "FAIL: ${_cp_step} - ${_cp_failed} of ${_cp_n} checks failed${_cp_stopped}"
    exit 1
  fi
  echo "PASS: ${_cp_step} - ${_cp_n} of ${_cp_n} checks passed"
}
