# Git hooks in this repository

This repo uses two Git hooks:

| Hook           | Installed by | Trigger                | Blocks? | What it does                                             |
| -------------- | ------------ | ---------------------- | ------- | -------------------------------------------------------- |
| `post-commit`  | graphify     | after every commit     | no      | rebuilds the knowledge graph (code only, detached)       |
| `post-checkout`| graphify     | on a branch switch     | no      | full knowledge-graph rebuild (detached)                  |
| `pre-push`     | hand-written | before `git push`      | only if you say no | runs the ponytail over-engineering review on the changeset |

**Important:** hooks live in `.git/hooks/` and are **never tracked by Git**. A fresh
clone has only the `.sample` files, so both hooks must be reinstalled after cloning
elsewhere. This document is the record of how to do that.

This repo does **not** set `core.hooksPath`; hooks are read from the default
`.git/hooks/` directory. If you ever set `core.hooksPath`, Git stops reading
`.git/hooks/` entirely and these hooks silently stop firing.

---

## 1. graphify hooks (`post-commit`, `post-checkout`)

Installed and managed by the `graphify` CLI. They keep `graphify-out/graph.json`
in sync with the code so graph queries stay accurate.

- **`post-commit`** — after each commit, launches a **detached background** rebuild of
  changed code files. It never blocks the commit.
- **`post-checkout`** — on an actual branch switch, launches a detached full rebuild.
- Both skip automatically during rebase/merge/cherry-pick, in linked worktrees, when
  only `graphify-out/` changed, and when no tracked code files changed.
- Rebuild activity is logged to `~/.cache/graphify-rebuild.log`.
- `graphify hook install` also configures the **merge driver** referenced by the
  tracked `.gitattributes` line `graphify-out/graph.json merge=graphify`
  (`git config merge.graphify.driver`). That config is local, not committed.

### Manage

```sh
graphify hook status      # are the hooks installed?
graphify hook install     # (re)install post-commit + post-checkout + merge driver
graphify hook uninstall   # remove them
```

### Environment knobs

| Variable                   | Effect                                                        |
| -------------------------- | ------------------------------------------------------------- |
| `GRAPHIFY_SKIP_HOOK=1`     | skip the rebuild for one command                              |
| `GRAPHIFY_REBUILD_TIMEOUT` | watchdog seconds (default `600`)                              |
| `GRAPHIFY_FORCE=1`         | force a rebuild even when the node count would drop           |
| `GRAPHIFY_OUT`             | output directory (default `graphify-out`)                     |
| `GRAPHIFY_MAX_WORKERS`     | parallelism for the rebuild                                   |

> The rebuild runs detached, so a failure appears only in
> `~/.cache/graphify-rebuild.log`, never as a failed commit.

---

## 2. ponytail `pre-push` review (confirm-on-findings)

A hand-written hook that runs the changeset about to be pushed through the
**ponytail** "lazy senior dev" review for over-engineering tips. It is read-only
and never edits files.

**Requirements:** `opencode` on `PATH`, and this repo's `.opencode/opencode.json`
lists the ponytail plugin (`@dietrichgebert/ponytail`). If `opencode` is missing the
hook exits quietly.

### Behaviour

- Reviews exactly the commits being pushed (`remote_sha..local_sha`; for a brand-new
  branch it diffs against `origin/main` or `origin/master`).
- **No findings** → prints "no over-engineering found" and the push continues.
- **Findings** → prints them and asks `Push anyway? [y/N]` on your terminal; anything
  other than `y` **aborts the push** (exit 1).
- **No terminal** (GUI client, CI, piped output) → prints findings and continues
  (advisory) so a push can never hang.
- **Agent error / timeout / unclear verdict** → continues (advisory).
- Uses the read-only `plan` agent under a portable `perl` timeout that kills the whole
  process group, so a stuck agent cannot wedge your push.

### Controls

```sh
PONYTAIL_SKIP_PREPUSH=1 git push          # skip the review for one push
PONYTAIL_PREPUSH_TIMEOUT=180 git push     # override the 120s default
```

### Reinstall after a re-clone

Copy the script below to `.git/hooks/pre-push` in the fresh clone and make it
executable:

```sh
mkdir -p .git/hooks
# paste the script from the fenced block below into .git/hooks/pre-push
chmod +x .git/hooks/pre-push
```

Verify:

```sh
printf 'refs/heads/main HEAD refs/heads/main HEAD\n' | .git/hooks/pre-push origin "$(git remote get-url origin)"
```

### Hook source (keep in sync with `.git/hooks/pre-push`)

```sh
#!/bin/sh
# ponytail pre-push review (confirm-on-findings)
#
# Before a push leaves the machine, run the changeset about to be pushed through
# the ponytail "lazy senior dev" review for over-engineering tips. The review is
# read-only and never edits files.
#
#   * no findings           -> print "no over-engineering found" and push
#   * findings              -> show them and ask "Push anyway? [y/N]"
#   * no terminal to ask on -> print the findings and push (advisory)
#
# Skip for one push:   PONYTAIL_SKIP_PREPUSH=1 git push
# Tune the timeout:    PONYTAIL_PREPUSH_TIMEOUT=180 git push
#
# Installed by hand into .git/hooks/ (local to this clone, not committed).

[ "${PONYTAIL_SKIP_PREPUSH:-0}" = "1" ] && exit 0

command -v opencode >/dev/null 2>&1 || exit 0

z40=0000000000000000000000000000000000000000
ranges=""

while read -r local_ref local_sha remote_ref remote_sha; do
  case "${local_sha:-}" in ""|"$z40") continue ;; esac
  if [ "${remote_sha:-}" = "$z40" ]; then
    # New branch on the remote: compare against the default branch if we can.
    base=$(git merge-base "$local_sha" origin/main 2>/dev/null) ||
      base=$(git merge-base "$local_sha" origin/master 2>/dev/null) || base=""
    [ -n "$base" ] && ranges="$ranges $base..$local_sha"
  else
    ranges="$ranges ${remote_sha}..${local_sha}"
  fi
done

[ -z "$ranges" ] && exit 0

diff_text=""
for r in $ranges; do
  diff_text="$diff_text
$(git diff --no-color --unified=3 "$r" 2>/dev/null)"
done
[ -z "$diff_text" ] && exit 0

# Keep the prompt (argv) size sane on very large pushes.
max=200000
if [ "${#diff_text}" -gt "$max" ]; then
  diff_text=$(printf '%s' "$diff_text" | cut -c1-"$max")
  diff_text="$diff_text

[diff truncated at $max bytes]"
fi

prompt="You are reviewing a git changeset immediately before it is pushed to the remote. Follow the ponytail-review skill exactly.

Rules of engagement:
- Review ONLY the diff text at the end of this message. Do NOT run shell commands, do NOT read files, do NOT explore the repository. Judge the diff as written.
- Hunt ONLY over-engineering: not correctness, security, or performance.
- Look for dead code, reinvented standard-library functions, dependencies or code the platform already does natively, abstractions with a single implementation, config nobody sets, layers with one caller, and anything expressible in fewer lines.

Output format:
- One line per finding: 'L<line>: <tag> <what to cut>. <replacement>.' (use '<file>:L<line>: ...' when several files are involved). Tags: delete, stdlib, native, yagni, shrink.
- After any findings, print the line 'net: -N lines possible.'
- Your very last line must be exactly one of these sentinels:
    PONYTAIL_RESULT: FINDINGS   (if you listed at least one finding)
    PONYTAIL_RESULT: CLEAN      (if there is nothing to cut; in that case the reply is just 'Lean already. Ship.' followed by the sentinel)

Do not modify any files; advice only.

The diff:

$diff_text"

# Portable timeout: use perl (present on macOS) to cap the review, killing the
# whole process group so a stuck agent cannot block the push forever.
timeout_secs="${PONYTAIL_PREPUSH_TIMEOUT:-120}"
run_review() {
  if command -v perl >/dev/null 2>&1; then
    perl -e '
      my $secs = shift @ARGV;
      my $pid = fork();
      exit 127 unless defined $pid;
      if ($pid == 0) { setpgrp(0, 0); exec @ARGV; exit 127; }
      $SIG{ALRM} = sub { kill "TERM", -$pid; waitpid($pid, 0); exit 124; };
      alarm $secs;
      waitpid($pid, 0);
      exit($? >> 8);
    ' "$timeout_secs" opencode run --agent plan "$prompt"
  else
    opencode run --agent plan "$prompt"
  fi
}

printf '\n[ponytail] review of the changeset about to be pushed (%s):\n\n' "$ranges" >&2
out=$(run_review 2>&1)
rc=$?
printf '%s\n' "$out" >&2

if [ "$rc" -ne 0 ]; then
  printf '\n[ponytail] review unavailable (agent failed or timed out) - continuing push.\n\n' >&2
  exit 0
fi

# Decide whether the review found anything. Strip ANSI colour first.
# findings: 0 = clean, 1 = findings, 2 = unparseable (treat as advisory).
clean=$(printf '%s' "$out" | perl -pe 's/\e\[[0-9;]*[A-Za-z]//g' 2>/dev/null || printf '%s' "$out")
findings=2
if printf '%s' "$clean" | grep -q 'PONYTAIL_RESULT:[[:space:]]*FINDINGS'; then
  findings=1
elif printf '%s' "$clean" | grep -q 'PONYTAIL_RESULT:[[:space:]]*CLEAN'; then
  findings=0
elif printf '%s' "$clean" | grep -q 'Lean already'; then
  findings=0
elif printf '%s' "$clean" | grep -Eq 'net:[[:space:]]*-?[0-9]+ lines'; then
  findings=1
fi

if [ "$findings" -eq 0 ]; then
  printf '\n[ponytail] no over-engineering found. Push on.\n\n' >&2
  exit 0
fi

if [ "$findings" -eq 2 ]; then
  printf '\n[ponytail] review gave no clear verdict - continuing (advisory). Re-run if you want a closer look.\n\n' >&2
  exit 0
fi

# Findings exist: confirm before letting the push through. Require an
# interactive stdout so a piped / GUI / CI push never hangs waiting for input.
if [ -t 1 ] && [ -r /dev/tty ]; then
  printf '\n[ponytail] The findings above are advisory. Push anyway? [y/N] ' >&2
  reply=""
  read -r reply < /dev/tty || reply=""
  case "$reply" in
    y|Y|yes|YES) printf '[ponytail] pushing.\n\n' >&2 ;;
    *) printf '[ponytail] push aborted. Re-run when ready, or PONYTAIL_SKIP_PREPUSH=1 git push to skip.\n\n' >&2; exit 1 ;;
  esac
else
  printf '\n[ponytail] no terminal available for confirmation; continuing (advisory).\n\n' >&2
fi

exit 0
```

---

## Setup checklist for a fresh clone (`git clone` elsewhere)

1. **graphify hooks + merge driver**
   ```sh
   graphify hook install
   graphify hook status
   ```
2. **ponytail pre-push hook**
   ```sh
   mkdir -p .git/hooks
   # copy the "Hook source" block above into .git/hooks/pre-push, then:
   chmod +x .git/hooks/pre-push
   ```
3. **Confirm** `opencode` is on `PATH` for the ponytail review (it silently skips
   otherwise), and that `.opencode/opencode.json` still lists the ponytail plugin.

## Troubleshooting

- **A hook "isn't running"** → check you haven't set `core.hooksPath`
  (`git config --get core.hooksPath`). If it is set, Git ignores `.git/hooks/`.
- **Commits stall** → the graphify hooks are detached and return immediately; if a
  commit hangs, look elsewhere. The ponytail hook only waits on `git push`.
- **Pushes block on the review** → intended when findings exist; answer `y`, or use
  `PONYTAIL_SKIP_PREPUSH=1 git push`.
- **graphify rebuild issues** → read `~/.cache/graphify-rebuild.log`.
- **Hook file drifted from this doc** → this doc is the source of truth; re-copy the
  "Hook source" block into `.git/hooks/pre-push`.
