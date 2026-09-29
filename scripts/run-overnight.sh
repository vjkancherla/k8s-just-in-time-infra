#!/usr/bin/env bash
# run-overnight.sh - autonomous orchestrator for the Stage-H build plan.
#
# EXPERIMENTAL. This REMOVES every human gate the RUNBOOK describes: the manual review
# tick, the "do not start the next step" stop, the S23 design-fork approval, and the
# three-BLOCKED stop. Git history is the rollback.
#
# The ONE protocol retained is the frozen-checkpoint ADR path (docs/decisions/0000-template.md):
# a checkpoint edit is only accepted if an ADR rides in the same commit range, and the
# reviewer's CLEAR on that range is the approval. That is not a gate the loop can skip.
#
# The orchestrator is a shell script, not an LLM, on purpose: it gates on the artefact
# (a PASS in docs/evidence/S<NN>.log, a CLEAR in docs/reviews/S<NN>-findings.md), never on
# a model's claim. The two agents only implement and review.
#
# Usage:
#   scripts/run-overnight.sh
#   STEPS="23 24 25 26 27 28 29" scripts/run-overnight.sh
#   MAX_ATTEMPTS=5 ON_EXHAUST=continue scripts/run-overnight.sh
#
# Models: exactly two, for every step. No per-step exceptions.
#   implementer  opencode-go/deepseek-v4.1-flash
#   reviewer     opencode-go/mimo-v2.6-flash
#
# The machine stays awake for the whole run: the script re-execs itself under
# caffeinate on macOS, so no wrapper is needed. Optionally still run it in tmux:
#   tmux new -s night 'scripts/run-overnight.sh'
#
# Human directives: set IMPL_EXTRA to a sentence appended to every implementer prompt
# (e.g. a design decision the human has made), so a step does not fork on its own.
#
# Output: docs/evidence/overnight-<stamp>.log (full transcript) and .md (the morning report).
set -uo pipefail

# Keep the machine awake (macOS). Re-exec once under caffeinate; -dimsu prevents
# display, idle, disk and system sleep for as long as this script lives.
if [ "${BASH_SOURCE[0]}" = "$0" ] \
   && [ "${OVERNIGHT_CAFFEINATED:-}" != "1" ] \
   && command -v caffeinate >/dev/null 2>&1; then
  export OVERNIGHT_CAFFEINATED=1
  exec caffeinate -dimsu "$0" "$@"
fi

cd "$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "FATAL: not inside a git repo"; exit 1; }

command -v opencode >/dev/null 2>&1 || { echo "FATAL: opencode not on PATH"; exit 1; }

STEPS=${STEPS:-"23 24 25 26 27 28 29"}
IMPL_MODEL=opencode-go/deepseek-v4.1-flash
REVIEW_MODEL=opencode-go/mimo-v2.6-flash
MAX_ATTEMPTS=${MAX_ATTEMPTS:-3}
ON_EXHAUST=${ON_EXHAUST:-halt}          # halt | continue  (continue = push past an uncleared step)
IMPL_EXTRA=${IMPL_EXTRA:-}              # optional human directive appended to every implementer prompt

EVIDENCE=docs/evidence
REVIEWS=docs/reviews
DECISIONS=docs/decisions
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_LOG="$EVIDENCE/overnight-$STAMP.log"
REPORT="$EVIDENCE/overnight-$STAMP.md"

mkdir -p "$EVIDENCE"
: >"$RUN_LOG"

log()  { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*" | tee -a "$RUN_LOG" >&2; }
note() { printf '%s\n' "$*" >>"$REPORT"; }

new_commits()  { git rev-list --count "$1..HEAD" 2>/dev/null || echo 0; }

evidence_pass() {
  [ -s "$EVIDENCE/S$1.log" ] && grep -qEi '(^|[^[:alnum:]_])pass([^[:alnum:]_]|$)' "$EVIDENCE/S$1.log"
}

verdict() {
  [ -f "$REVIEWS/S$1-findings.md" ] || return 0
  grep -m1 -E '^Verdict:' "$REVIEWS/S$1-findings.md" | grep -oE 'CLEAR|CONCERNS|BLOCKED' | tail -1
}

# The pass bar is "no blockers", not the literal word CLEAR: a CONCERNS verdict whose
# Blockers section begins with "None" is accepted (the concerns become report notes).
# BLOCKED never passes. This matches the stated objective ("loop complete with no blockers").
blockers_empty() {
  local first
  first="$(awk '/^## Blockers/{f=1;next} /^## /{f=0} f' "$REVIEWS/S$1-findings.md" 2>/dev/null \
    | grep -vE '^[[:space:]]*$' | head -1)"
  printf '%s' "$first" | grep -qiE '^(none|no blockers)'
}

gate_changed() { git diff --name-only "$1..HEAD" -- scripts/checks scripts/checkpoint.sh | grep -q .; }
adr_added()    { git diff --name-only --diff-filter=A "$1..HEAD" -- docs/decisions | grep -qE '/[0-9]{4}-'; }

tick_boxes() {
  python3 - "$1" <<'PY'
import sys
n = sys.argv[1]
p = "docs/todo.md"
with open(p) as fh:
    lines = fh.readlines()
hit = False
for i, line in enumerate(lines):
    if f"**S{n}**" in line:
        new = line.replace("- [ ] check", "- [x] check", 1).replace("- [ ] review", "- [x] review", 1)
        if new != line:
            hit = True
        lines[i] = new
with open(p, "w") as fh:
    fh.writelines(lines)
sys.exit(0 if hit else 1)
PY
}

commit_paths() {  # commit_paths "<message>" <path...>
  local msg="$1"; shift
  git add -- "$@" 2>/dev/null || true
  git diff --cached --quiet && return 1
  git commit -q -m "$msg" || return 1
}

finish() {
  local rc="$1"
  note ""
  note "Run: $STAMP  ·  STEPS='$STEPS'  ·  implementer=$IMPL_MODEL  ·  reviewer=$REVIEW_MODEL"
  note ""
  note "## Outcomes"
  note ""
  cat "$REPORT.tmp" >>"$REPORT" 2>/dev/null || true
  note ""
  note "Final exit: $rc. Transcript: $RUN_LOG"
  log "overnight run finished (rc=$rc). Report: $REPORT"
  exit "$rc"
}

# --- backfill: S22's findings already exist and say CLEAR -----------------------------
backfill_review_only() {
  local n="$1"
  if [ "$n" = "22" ] && [ -f "$REVIEWS/S22-findings.md" ] && [ "$(verdict 22)" = "CLEAR" ]; then
    log "S22: findings exist and say CLEAR - committing and ticking (backfill, no re-review)"
    commit_paths "S22 review findings (autonomous backfill)" "$REVIEWS/S22-findings.md" || true
    if tick_boxes 22; then commit_paths "S22: CLEAR - tick tracker (autonomous)" docs/todo.md || true; fi
    printf -- "- S22: backfilled CLEAR (findings file was already on disk).\n" >>"$REPORT.tmp"
    return 0
  fi
  return 1
}

run_step() {
  local n="$1" attempt=0 v="" correction=""

  backfill_review_only "$n" && return 0

  log "=== S$n begin (implementer=$IMPL_MODEL, reviewer=$REVIEW_MODEL) ==="

  while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    local base; base="$(git rev-parse HEAD)"
    log "S$n attempt $attempt/$MAX_ATTEMPTS: implement"

    local prompt
    prompt="$(cat <<EOF
Do S$n from docs/build-plan.md.

This is an autonomous run. Follow docs/RUNBOOK.md step 1 and the binding rules in
.opencode/rules/s22-declarers.md, with these overrides:
- Do not tick any box in docs/todo.md; the orchestrator ticks after an independent CLEAR.
- Do not stop for any human approval. If a gate names a human decision, write the ADR /
  superseded design note that records the decision, commit it, and continue.
- Frozen checkpoints: never edit scripts/checks/** or scripts/checkpoint.sh directly. If a
  checkpoint must change, write docs/decisions/NNNN-<title>.md from
  docs/decisions/0000-template.md first, then commit the ADR and the checkpoint edit
  together BEFORE running scripts/checkpoint.sh (it refuses an uncommitted checkpoint), and
  cite the ADR in the review prompt.
- Run the checkpoint only via scripts/checkpoint.sh $n. Commit code and docs/evidence/S$n.log
  together. Emit docs/reviews/S$n-review-prompt.md from the template (six slots verbatim) and
  make scripts/review-guard.sh $n print PASS.

Human directive from the orchestrator (overrides the overrides above):
$IMPL_EXTRA

Final message: the commit SHA(s) and the checkpoint result.
EOF
)"
    [ -n "$correction" ] && prompt="$prompt

Previous attempt feedback:
$correction"

    opencode run --agent implementer -m "$IMPL_MODEL" --auto "$prompt" 2>&1 | tee -a "$RUN_LOG"

    if [ "$(new_commits "$base")" -eq 0 ]; then
      correction="You produced no commit. Do the step's Do list, commit the code and the evidence log, then stop."
      log "S$n: no commit produced"
      continue
    fi

    if gate_changed "$base" && ! adr_added "$base"; then
      correction="The range edits a frozen checkpoint but carries no ADR. Revert the checkpoint edit,
write docs/decisions/NNNN-<title>.md from docs/decisions/0000-template.md, commit the ADR with
the checkpoint edit, then run scripts/checkpoint.sh $n and commit the evidence."
      log "S$n: checkpoint changed with no ADR in range"
      continue
    fi

    if ! evidence_pass "$n"; then
      correction="docs/evidence/S$n.log does not contain a PASS. Run scripts/checkpoint.sh $n, fix what
fails, commit code + the log together, then stop."
      log "S$n: no PASS in $EVIDENCE/S$n.log"
      continue
    fi

    if ! scripts/review-guard.sh "$n" >>"$RUN_LOG" 2>&1; then
      correction="scripts/review-guard.sh $n failed. Regenerate docs/reviews/S$n-review-prompt.md from
docs/reviews/REVIEW-PROMPT-TEMPLATE.md (six slots verbatim, twelve questions) and make sure
docs/evidence/S$n.log is committed and inside the prompt's commit range."
      log "S$n: review-guard failed"
      continue
    fi

    local impl_sha; impl_sha="$(git rev-parse --short HEAD)"
    log "S$n checkpoint PASS at $impl_sha: review (reviewer=$REVIEW_MODEL)"

    opencode run --agent reviewer -m "$REVIEW_MODEL" --auto \
      "Read and follow docs/reviews/S$n-review-prompt.md. Write docs/reviews/S$n-findings.md in the template's block structure, ending with one Verdict: line. Do not modify any other file. Do not commit. Stop." \
      2>&1 | tee -a "$RUN_LOG"

    if [ -f "$REVIEWS/S$n-findings.md" ]; then
      commit_paths "S$n review findings (autonomous)" "$REVIEWS/S$n-findings.md" || true
    fi

    v="$(verdict "$n")"
    log "S$n: verdict=${v:-none}"

    # Pass on CLEAR, or on CONCERNS with an empty Blockers section (our bar is "no blockers").
    if [ "$v" = "CLEAR" ] || { [ "$v" = "CONCERNS" ] && blockers_empty "$n"; }; then
      if tick_boxes "$n"; then
        commit_paths "S$n: ${v} (no blockers) - tick tracker (autonomous)" docs/todo.md || true
      fi
      printf -- "- S$n: %s at %s (no blockers); tracker ticked. Concerns are report notes.\n" "$v" "$impl_sha" >>"$REPORT.tmp"
      log "S$n: ${v} (no blockers) - step done"
      return 0
    fi

    printf -- "- S$n: attempt %s verdict %s.\n" "$attempt" "${v:-none}" >>"$REPORT.tmp"
    correction="The reviewer returned ${v:-no verdict} with blockers. Read docs/reviews/S$n-findings.md and fix
every blocker it names, then re-run scripts/checkpoint.sh $n, commit, and regenerate the review prompt."
  done

  if [ "$ON_EXHAUST" = "continue" ]; then
    log "S$n: attempts exhausted - continuing WITHOUT a CLEAR (tracker NOT ticked)"
    printf -- "- S$n: attempts exhausted, NOT ticked (ON_EXHAUST=continue).\n" >>"$REPORT.tmp"
    return 0
  fi

  log "S$n: attempts exhausted - halting (set ON_EXHAUST=continue to push past)"
  printf -- "- S$n: attempts exhausted, halted. STOP.\n" >>"$REPORT.tmp"
  return 1
}

# --- main ----------------------------------------------------------------------------
main() {
  log "autonomous overnight run $STAMP  steps='$STEPS'  attempts=$MAX_ATTEMPTS  on_exhaust=$ON_EXHAUST"
  log "implementer=$IMPL_MODEL  reviewer=$REVIEW_MODEL"
  log "git HEAD $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"
  git status --porcelain >"$EVIDENCE/overnight-$STAMP.prestate" 2>/dev/null || true

  : >"$REPORT.tmp"
  for n in $STEPS; do
    if ! run_step "$n"; then
      printf -- "- Run halted at S%s.\n" "$n" >>"$REPORT.tmp"
      finish 1
    fi
  done

  finish 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
