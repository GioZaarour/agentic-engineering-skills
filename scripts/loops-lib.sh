#!/usr/bin/env bash
#
# loops-lib.sh — shared core for the unattended issue loop.
#
# Sourced by:
#   claude-issue-loop.sh / codex-issue-loop.sh: spec → implement → review → context → PR
#
# Everything the loop must not get wrong twice lives here: the model/effort
# choices, the measured machine budget injected into every prompt, and the
# `stage()` process runner with its failure taxonomy. If you write a second
# entrypoint (a queue, a resume-only tail), source this rather than copying it —
# two copies drift, and the drift is invisible until an unattended run behaves
# differently from the one you tested.
#
# Nothing in this file is project-specific. Everything is env-overridable, and
# anything your project needs the agent to know (build commands, test commands,
# toolchain setup) goes in the notes file — see LOOP_NOTES below.

set -uo pipefail   # deliberately NOT -e: stage failures are handled, not fatal

# Associative arrays and globstar are bash 4 features and both are load-bearing.
# macOS still ships bash 3.2 as /bin/bash, so this is a real failure mode and
# not a theoretical one — and its symptom without this check is a cryptic
# syntax error a hundred lines from the cause.
if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 2) )); then
  echo "these scripts need bash 4.2 or newer; this is bash ${BASH_VERSION}" >&2
  echo "macOS ships bash 3.2 — install a newer one (brew install bash) and run" >&2
  echo "the script with it, or put it earlier on PATH than /bin/bash." >&2
  exit 2
fi

# ══════════════════════════════════════════════════════════════════════════
# CONFIG — every value here is env-overridable
# ══════════════════════════════════════════════════════════════════════════

VERSION_SEGMENT="${VERSION_SEGMENT:-v0}"   # branch/spec prefix: v0/bugfix/91-...
DEFAULT_TYPE="${DEFAULT_TYPE:-bugfix}"     # when labels and title are inconclusive

# Your repo's label taxonomy, as regexes over lowercased label names. Check
# yours with `gh label list` and override if it differs — a label set that
# matches nothing here is not an error, it just means the type falls through to
# the title heuristic and then to DEFAULT_TYPE.
BUGFIX_LABELS="${BUGFIX_LABELS:-^(bug|bugfix|fix|defect|techdebt)$}"
FEATURE_LABELS="${FEATURE_LABELS:-^(feature|enhancement|feat)$}"

# The branch the PR is opened against, and the branch new work is cut from.
# Override to stack a branch on top of an unmerged one:
#   BASE_BRANCH=v0/feature/56-history ./scripts/claude-issue-loop.sh 57
BASE_BRANCH="${BASE_BRANCH:-main}"

# Entrypoints choose the CLI; each phase can still override its model and effort.
LOOP_CLI="${LOOP_CLI:-claude}"
case "$LOOP_CLI" in
  claude)
    DEFAULT_MODEL=claude-opus-5-5
    DEFAULT_ADOPT_MODEL=claude-haiku-4-5-20251001
    # Prefer the subscription even when a shell profile exports an API key.
    LOOP_AUTH="${LOOP_AUTH:-subscription}"
    case "$LOOP_AUTH" in
      subscription) unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ;;
      api-key) ;;
      *) echo "LOOP_AUTH must be 'subscription' or 'api-key', not '$LOOP_AUTH'" >&2; exit 2 ;;
    esac
    ;;
  codex)
    DEFAULT_MODEL=gpt-6-sol
    DEFAULT_ADOPT_MODEL=gpt-6-luna
    ;;
  *) echo "unknown loop CLI: $LOOP_CLI" >&2; exit 2 ;;
esac
PLAN_MODEL="${PLAN_MODEL:-$DEFAULT_MODEL}"
CODE_MODEL="${CODE_MODEL:-$DEFAULT_MODEL}"
PLAN_EFFORT="${PLAN_EFFORT:-high}"
CODE_EFFORT="${CODE_EFFORT:-medium}"

# Where this run's artifacts go, relative to the repo root. It must be ignored
# by git on every branch; preflight_common takes care of that for you.
RUN_ROOT="${RUN_ROOT:-.loops}"

# Paths that must be ignored on EVERY branch (see preflight_common for why).
# Entrypoints append their own script path before calling preflight_common.
MUST_IGNORE=("$RUN_ROOT" "scripts/loops-lib.sh")

# Project-specific instructions appended to the machine budget in every prompt:
# how to build, how to run tests, which suites cannot run headless, which
# toolchain to source first. This is the one file you are expected to write —
# see scripts/loop-notes.example.md. Missing is fine; the agent then works out
# build and test commands from the repo itself.
LOOP_NOTES="${LOOP_NOTES:-.loop-notes.md}"

# Labels the loop signals through. Both are created if missing (preflight), and
# `gh --add-label` on a label that does not exist is a silent no-op into the
# log — exactly the signal you would be looking for.
NEEDS_HUMAN_LABEL="${NEEDS_HUMAN_LABEL:-needs-human}"
TECHDEBT_LABEL="${TECHDEBT_LABEL:-techdebt}"

MAX_REVIEW_ROUNDS="${MAX_REVIEW_ROUNDS:-2}"

# review_fix_cycle's loop exits right after a FIX, so the count it reports is
# the one the review found BEFORE that fix ran — a branch can be reported as
# having two blocking findings when the last fix round already addressed both.
# Set this to 1 to spend one more review pass and report a number that describes
# the code as it actually stands. Off by default here; the issue entrypoint turns it on,
# because a single-issue run has no queue to get through and a wrong needs-human
# label on the issue misrepresents the whole output of the run.
FINAL_VERIFY_REVIEW="${FINAL_VERIFY_REVIEW:-0}"
STAGE_TIMEOUT="${STAGE_TIMEOUT:-14400}"      # 4h/stage. A wedge detector, not a pace target.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"            # NOT used for timeouts or account limits
BACKOFF=(0 180 900)                          # seconds before attempt 2 and 3
DEADLINE_HOURS="${DEADLINE_HOURS:-168}"      # effectively off; a runaway backstop

# Cost circuit breakers — BOTH OFF (0) by design. If the run is burning plan
# usage credits rather than API dollars, the CLI's dollar figures are notional
# and a cap is all downside: a per-stage limit kills a long `implement`
# mid-edit, and a run-total limit stops the run short of a PR. Cost is measured
# and reported, never enforced. Set either to a number to re-arm it — do that
# if you are on metered API billing and want a hard ceiling.
#   STAGE_BUDGET_USD  → --max-budget-usd on each claude process
#   TOTAL_BUDGET_USD  → checked by stage() before each stage starts
STAGE_BUDGET_USD="${STAGE_BUDGET_USD:-0}"
TOTAL_BUDGET_USD="${TOTAL_BUDGET_USD:-0}"

# Codex reports token usage, not dollar cost, and has no per-stage dollar cap.
if [[ "$LOOP_CLI" == codex && ( "$STAGE_BUDGET_USD" != 0 || "$TOTAL_BUDGET_USD" != 0 ) ]]; then
  echo "Codex does not support STAGE_BUDGET_USD or TOTAL_BUDGET_USD; leave both at 0." >&2
  exit 2
fi

if [[ "$STAGE_BUDGET_USD" != "0" ]]; then
  BUDGET_ARGS=(--max-budget-usd "$STAGE_BUDGET_USD")
else
  BUDGET_ARGS=()
fi

# Unattended means no one is there to answer a permission prompt. This is the
# single most dangerous line in the loop: read the README's safety section
# before you change it, and understand what the agent can reach on this machine.
PERMISSION_MODE="${PERMISSION_MODE:-bypassPermissions}"
TOOLS="${TOOLS:-Read,Edit,Write,Glob,Grep,Bash,WebFetch,Agent}"

# Set by stage() when the account spend/usage limit is hit; callers must stop.
USAGE_LIMIT_HIT=0

# ══════════════════════════════════════════════════════════════════════════

REPO_ROOT="$(git rev-parse --show-toplevel)" || exit 2
cd "$REPO_ROOT" || exit 2

# `timeout` is GNU coreutils; macOS has it only as `gtimeout` from Homebrew,
# and often not at all. Without it a wedged stage hangs the run forever, so its
# absence is a warning, not a silent downgrade.
TIMEOUT_BIN="${TIMEOUT_BIN:-}"
if [[ -z "$TIMEOUT_BIN" ]]; then
  if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN=timeout
  elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN=gtimeout
  fi
fi

# ── resource budget, measured not assumed ─────────────────────────────────
# Recomputed at runtime so the loop stays correct when it moves to a bigger
# host: a 16 GB workstation yields more build parallelism and more subagents
# than a 4 GB cloud box, from the same code and without a config edit.
detect_cores() {
  if   command -v nproc  >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu 2>/dev/null || echo 1
  else echo 1
  fi
}

detect_mem_mb() {
  if [[ -r /proc/meminfo ]]; then
    awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    local bytes; bytes=$(sysctl -n hw.memsize 2>/dev/null)
    [[ "$bytes" =~ ^[0-9]+$ ]] && echo $(( bytes / 1048576 )) || echo 0
  else echo 0
  fi
}

detect_swap_mb() {
  if [[ -r /proc/meminfo ]]; then
    awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo
  elif command -v sysctl >/dev/null 2>&1; then
    local s; s=$(sysctl -n vm.swapusage 2>/dev/null | sed -E 's/.*total = ([0-9]+)[.,]?[0-9]*M.*/\1/')
    [[ "$s" =~ ^[0-9]+$ ]] && echo "$s" || echo 0
  else echo 0
  fi
}

# -Pk, not -BG: POSIX output in 1K blocks works identically on GNU and BSD df,
# where -BG is GNU-only and --output= is GNU-only.
detect_disk_gb() {
  df -Pk "$1" 2>/dev/null | awk 'NR==2 {print int($4/1048576)}'
}

CORES=$(detect_cores);          [[ "$CORES" =~ ^[0-9]+$ && "$CORES" -gt 0 ]] || CORES=1
MEM_TOTAL_MB=$(detect_mem_mb)
SWAP_TOTAL_MB=$(detect_swap_mb); [[ "$SWAP_TOTAL_MB" =~ ^[0-9]+$ ]] || SWAP_TOTAL_MB=0

# An undetectable amount of RAM must not become "0 MB, therefore -j1 forever",
# and must not divide by zero either. Assume a modest machine and say so.
MEM_MEASURED=yes
if ! [[ "$MEM_TOTAL_MB" =~ ^[0-9]+$ ]] || (( MEM_TOTAL_MB < 512 )); then
  MEM_TOTAL_MB=8192; MEM_MEASURED=no
fi

# Compiler/test parallelism. The binding constraint is RAM per job, not cores:
# a heavy C++ translation unit peaks near 2 GB, a Rust or TypeScript build far
# less. Raise MB_PER_JOB for a heavier toolchain, lower it for a lighter one.
MB_PER_JOB="${MB_PER_JOB:-2048}"
[[ "$MB_PER_JOB" =~ ^[1-9][0-9]*$ ]] || MB_PER_JOB=2048

# A worktree that builds needs its own copy of every build artifact, so disk —
# not RAM — is what gates whether a stage may cut one.
WORKTREE_DISK_GB="${WORKTREE_DISK_GB:-20}"
MIN_DISK_GB="${MIN_DISK_GB:-5}"

# What the user pinned, kept apart from what compute_budget derives, so a
# recomputation can tell "set by hand" from "set by the last recomputation".
USER_BUILD_JOBS="${BUILD_JOBS:-}"
USER_SUBAGENT_CAP="${SUBAGENT_CAP_OVERRIDE:-}"
USER_ALLOW_WORKTREES="${ALLOW_WORKTREES_OVERRIDE:-}"

# ── count_other_loops ─────────────────────────────────────────────────────
# Issue loops of this repository that are running right now, not counting this
# one. Every worktree shares the status registry (see write_status), so a loop
# in any worktree is visible here. A `running` record whose process is gone is a
# loop that was SIGKILLed; it uses nothing, so it does not count. Loops of OTHER
# repositories on the same machine are invisible — set LOOPS_SHARE for those.
count_other_loops() {
  local dir pid n=0
  dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)/loops"
  compgen -G "$dir/*.json" >/dev/null || { echo 0; return 0; }
  while read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ && "$pid" != "$$" ]] && kill -0 "$pid" 2>/dev/null && n=$(( n + 1 ))
  done < <(jq -r 'select(.state == "running") | .pid' "$dir"/*.json 2>/dev/null)
  echo "$n"
}

# ── compute_budget ────────────────────────────────────────────────────────
# Derives this loop's share of the machine and rebuilds RESOURCE_NOTE from it.
#
# The running loops of this repository divide the machine evenly: LOOPS_SHARING
# is this loop plus every other running one (or LOOPS_SHARE, when set). Within a share, build jobs
# are split again across the agents that can build at once — the stage's agent
# and each of its subagents runs its own `-j`, so a cap of 2 subagents at -j4 is
# eight compile jobs, not four.
#
# Called at source time and again at every stage boundary (mark_stage), so a
# loop started alone narrows its budget once others start, and widens it when
# they finish. A stage already running keeps the budget it started with.
compute_budget() {
  local sharing jobs
  sharing="${LOOPS_SHARE:-$(( $(count_other_loops) + 1 ))}"
  [[ "$sharing" =~ ^[1-9][0-9]*$ ]] || sharing=1
  LOOPS_SHARING=$sharing

  # Re-measured every time: other loops' builds are what consumes it.
  DISK_FREE_GB=$(detect_disk_gb "$REPO_ROOT"); [[ "$DISK_FREE_GB" =~ ^[0-9]+$ ]] || DISK_FREE_GB=0

  SHARE_MEM_MB=$(( MEM_TOTAL_MB / LOOPS_SHARING ))
  SHARE_CORES=$(( CORES / LOOPS_SHARING )); (( SHARE_CORES < 1 )) && SHARE_CORES=1
  SHARE_DISK_GB=$(( DISK_FREE_GB / LOOPS_SHARING ))

  if (( SHARE_CORES < 4 || SHARE_MEM_MB < 8192 )); then
    SUBAGENT_CAP=1
  else
    SUBAGENT_CAP=2
  fi
  SUBAGENT_CAP=${USER_SUBAGENT_CAP:-$SUBAGENT_CAP}

  jobs=$(( SHARE_MEM_MB / MB_PER_JOB ))
  (( jobs > SHARE_CORES )) && jobs=$SHARE_CORES
  [[ "$SUBAGENT_CAP" =~ ^[0-9]+$ ]] && (( SUBAGENT_CAP > 1 )) && jobs=$(( jobs / SUBAGENT_CAP ))
  (( jobs < 1 )) && jobs=1
  BUILD_JOBS=${USER_BUILD_JOBS:-$jobs}

  if [[ "$SUBAGENT_CAP" =~ ^[0-9]+$ ]] && (( SUBAGENT_CAP > 1 && SHARE_DISK_GB >= WORKTREE_DISK_GB )); then
    ALLOW_WORKTREES=yes
  else
    ALLOW_WORKTREES=no
  fi
  ALLOW_WORKTREES=${USER_ALLOW_WORKTREES:-$ALLOW_WORKTREES}

  # The floor of one job per agent is not a guarantee that one job fits. Below
  # it, the machine cannot give every loop a build of its own, and the only
  # defence left is not building at the same time.
  SHARE_BELOW_ONE_JOB=no
  (( SHARE_MEM_MB < MB_PER_JOB )) && SHARE_BELOW_ONE_JOB=yes

  build_resource_note
}

# ── the budget every stage is told about ──────────────────────────────────
build_resource_note() {
  local sharing_line="" tight_line=""
  if (( LOOPS_SHARING > 1 )); then
    sharing_line="${LOOPS_SHARING} issue loops share this host right now. This loop's share: ${SHARE_CORES} core(s), ${SHARE_MEM_MB} MB RAM, ${SHARE_DISK_GB} GB of the free disk. The numbers below are for this loop alone."
  fi
  if [[ "$SHARE_BELOW_ONE_JOB" == yes ]]; then
    tight_line="- **This loop's share of RAM is smaller than one build job (${MB_PER_JOB} MB).**
  Build and test only when the work needs it, never run two builds at once,
  and prefer the narrowest target that proves the change."
  fi
  read -r -d '' RESOURCE_NOTE <<EOF || true
## Machine budget — unattended run, this is a hard constraint

Host: ${CORES} cores, ${MEM_TOTAL_MB} MB RAM$([[ "$MEM_MEASURED" == no ]] && echo " (assumed — could not measure)"), ${SWAP_TOTAL_MB} MB swap, ${DISK_FREE_GB} GB free disk.
${sharing_line:+$sharing_line
}No one is watching. If you exhaust RAM or disk, the OOM killer takes this
process down mid-edit and the work is lost, not merely slowed.

- **Run at most ${SUBAGENT_CAP} subagent(s) at a time.** If a skill tells you to fan out
  across independent slices or review surfaces, cap the fan-out at ${SUBAGENT_CAP}.
- **Creating git worktrees is ${ALLOW_WORKTREES} on this host.** If it is "no", work in the
  current tree, one slice at a time — a second worktree needs its own full set
  of build artifacts and there is not room for one.
- **Cap build and test parallelism at ${BUILD_JOBS} job(s) per agent** — \`-j${BUILD_JOBS}\`, \`--jobs ${BUILD_JOBS}\`,
  \`maxWorkers=${BUILD_JOBS}\`, whatever this toolchain calls it. The cap applies to you
  and to each subagent separately; it is already divided between them. Most
  build tools default to cores or cores+2 and will OOM this machine. If the
  repo's own docs recommend a higher number, **do not "fix" the docs** — that
  number is right for the machine it documents; only this run is constrained.
${tight_line:+$tight_line
}- Run the tests. A stage that reports success without a green suite has not
  finished. If a suite genuinely cannot run on this host (no display, no
  browser, no device, missing hardware), say so explicitly in your final
  message instead of skipping it silently.
- Do not run \`git push\`, do not open or merge PRs, and do not run
  \`git clean\` — the orchestrating shell owns all of those.
- Do not edit anything under \`${RUN_ROOT}/\` or \`scripts/\` — that is the loop
  driving you, not the code under change.
EOF

  # Whatever the project needs said about itself, said once, in every prompt.
  if [[ -r "$LOOP_NOTES" ]]; then
    RESOURCE_NOTE+=$'\n\n## Project-specific instructions for this run\n\n'
    RESOURCE_NOTE+="$(cat "$LOOP_NOTES")"
  fi
}

compute_budget

# ── ensure_run_root_excluded ──────────────────────────────────────────────
# Put $RUN_ROOT in .git/info/exclude, which is per-clone and branch-independent
# — the only place that holds when the loop checks out a branch whose
# .gitignore predates the rule. Without it, `git add -A` sweeps every log and
# every raw model response into the PR, and `git clean -fd` deletes the log of
# the run you are trying to diagnose. This is the one file outside the run
# directory the loop writes to on its own initiative; the line is local, and
# deleting it is enough to undo.
#
# Deliberately NOT conditional on `git check-ignore`. A project that also lists
# the run directory in .gitignore — a reasonable thing to do, so it is
# discoverable to anyone reading that file — would satisfy that probe and
# suppress this line. That trade is invisible and backwards: .gitignore is
# tracked and therefore branch-scoped, and this loop is built to ADOPT branches
# that predate anything you add today. The ordering hides it further — init_run
# and preflight_common both run BEFORE the checkout, so both would be evaluated
# against a branch that is not the one the run goes on to operate on. Keying
# idempotency on the exclude file's own contents instead makes a .gitignore
# rule harmless redundancy rather than a silent downgrade.
#
# A TRACKED run directory is the one real exemption: ignore rules do not apply
# to tracked paths, so the line would be noise.
ensure_run_root_excluded() {
  git ls-files --error-unmatch "$RUN_ROOT" >/dev/null 2>&1 && return 0

  # --git-path, not "$REPO_ROOT/.git/...": in a worktree or a submodule, .git is
  # a file pointing elsewhere, and info/exclude lives in the common dir.
  local excl; excl="$(git rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [[ -n "$excl" ]] || return 0
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  [[ -e "$excl" ]] || : >"$excl" 2>/dev/null || return 0

  # -x so a longer path that merely starts with $RUN_ROOT (.loops-archive) and a
  # commented-out line (# .loops) do not read as already handled; -F so a dot in
  # the name is a literal dot and not any-character.
  grep -qxF -- "$RUN_ROOT" "$excl" 2>/dev/null && return 0

  # A last line with no trailing newline would otherwise absorb ours into it,
  # producing one concatenated rule that matches nothing.
  [[ -s "$excl" && -n "$(tail -c1 "$excl")" ]] && printf '\n' >>"$excl"
  printf '%s\n' "$RUN_ROOT" >>"$excl" \
    && echo "added $RUN_ROOT to $excl (local to this clone)"
}

# ── init_run <label> ──────────────────────────────────────────────────────
# Names this run's artifact directory and opens its log. Each entrypoint calls
# this once; the lib deliberately does not do it at source time, so separate
# entrypoints get distinct run directories.
#
# The exclude line is ensured before the mkdir below, so the run directory never
# exists while unignored.
init_run() {
  ensure_run_root_excluded
  RUN_DIR="$REPO_ROOT/$RUN_ROOT/$(date +%Y%m%d-%H%M%S)${1:+-$1}"
  mkdir -p "$RUN_DIR"
  ln -sfn "$RUN_DIR" "$REPO_ROOT/$RUN_ROOT/latest"
  LOG="$RUN_DIR/run.log"
  DEADLINE=$(( $(date +%s) + DEADLINE_HOURS * 3600 ))
}

# ── run status ────────────────────────────────────────────────────────────
# One JSON file per run in the repo's common git directory, which every
# worktree shares, so `scripts/loops status` can list parallel runs without
# knowing where their worktrees are. A run writes only its own file, through a
# rename, so a reader never sees a partial one. `from` is the stage a resume
# starts at; empty means rerun from the top.
STATUS_FILE=""; STATUS_STATE=running; STATUS_STAGE=preflight
STATUS_REASON=""; STATUS_FROM=""; STATUS_TMUX=""; STATUS_STARTED=0

write_status() {
  [[ -n "$STATUS_FILE" ]] || return 0
  local from="$STATUS_FROM"
  [[ -z "$from" && " ${STAGE_ORDER[*]} " == *" $STATUS_STAGE "* ]] && from="$STATUS_STAGE"
  jq -n --argjson issue "$ISSUE" --arg cli "$LOOP_CLI" --arg state "$STATUS_STATE" \
    --arg stage "$STATUS_STAGE" --arg reason "$STATUS_REASON" --arg from "$from" \
    --arg branch "${BRANCH:-}" --arg base "$BASE_BRANCH" --arg pr "${PR_URL:-}" \
    --arg tmux "$STATUS_TMUX" --arg worktree "$REPO_ROOT" --arg log "$LOG" \
    --argjson pid $$ --argjson started "$STATUS_STARTED" --argjson updated "$(date +%s)" \
    --argjson exit_code "${1:-null}" '$ARGS.named' >"$STATUS_FILE.tmp" \
    && mv -f "$STATUS_FILE.tmp" "$STATUS_FILE"
}

# A stage boundary is also where the machine budget is re-read: loops started
# or finished since the last stage change this loop's share. The change is
# logged because it changes what the next stage is told it may run.
mark_stage() {
  local before="$LOOPS_SHARING/$BUILD_JOBS/$SUBAGENT_CAP/$ALLOW_WORKTREES"
  compute_budget
  if [[ "$LOOPS_SHARING/$BUILD_JOBS/$SUBAGENT_CAP/$ALLOW_WORKTREES" != "$before" ]]; then
    log "   budget: ${LOOPS_SHARING} loop(s) on this host — -j${BUILD_JOBS} per agent, ${SUBAGENT_CAP} subagent(s), worktrees=${ALLOW_WORKTREES}"
  fi
  STATUS_STAGE="$1"; write_status
}

# The exit code is the outcome (see the entrypoint's header); a signal means
# someone killed the run, typically by closing its tmux session. SIGKILL runs no
# trap at all, which is why `loops status` also checks that the pid is alive.
finish_status() {
  case "$1" in
    0) STATUS_STATE=done ;;
    3) STATUS_STATE=needs-human ;;
    4) STATUS_STATE=limit ;;
    129|130|143) STATUS_STATE=killed ;;
    *) STATUS_STATE=failed ;;
  esac
  write_status "$1"
}

init_status() {
  local dir
  dir="$(git rev-parse --path-format=absolute --git-common-dir)/loops" && mkdir -p "$dir" || return 0
  STATUS_FILE="$dir/${RUN_DIR##*/}.json"
  STATUS_STARTED=$(date +%s)
  [[ -n "${TMUX:-}" ]] && STATUS_TMUX=$(tmux display-message -p '#S' 2>/dev/null)
  trap 'finish_status $?' EXIT
  trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
  write_status
}

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
warn() { printf '%s  !! %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }

# Run Codex with stage()'s timeout prefix. Preserve the event stream and final
# text, then adapt them to the result document consumed by the shared workflow.
run_codex_stage() {
  local model="$1" effort="$2" prompt="$3" out="$4"; shift 4
  local events="${out%.json}.events.jsonl" message="${out%.json}.last.txt"
  local errors="${out%.json}.stderr.log" rc
  local -a permissions=(--sandbox danger-full-access)
  [[ "$TOOLS" == "Read,Glob,Grep" ]] && permissions=(--sandbox read-only)

  # Codex explicitly invokes skills with $name rather than Claude's /name.
  prompt=$(sed -E 's#^/(spec-from-issue|implement-spec|techdebt|branch-review|update-context|clear-technical-writing)([[:space:]]|$)#$\1\2#' <<<"$prompt")
  # A failed retry must not reuse the previous attempt's final message.
  : > "$message"
  ${runner[@]+"${runner[@]}"} codex exec --model "$model" \
    -c "model_reasoning_effort=\"$effort\"" -c 'approval_policy="never"' \
    "${permissions[@]}" --json --output-last-message "$message" \
    "$@" - <<<"$prompt" > "$events" 2> "$errors"
  rc=$?
  cat "$errors" >> "$LOG"

  # Exit 0 alone is insufficient: interrupted streams and turn.failed events
  # must not let the next stage consume a partial answer as a completed review.
  if ! jq -s --argjson rc "$rc" --rawfile result "$message" --rawfile stderr "$errors" '
      (any(.[]; .type == "turn.completed") and
       (any(.[]; .type == "turn.failed") | not) and
       $rc == 0 and ($result | length) > 0) as $ok |
      {provider: "codex", is_error: ($ok | not),
       result: (if $ok then $result else
         ([.[] | select(.type == "turn.failed" or .type == "error") |
           (.error.message // .message // "Codex turn failed")] + [$stderr] | join("\n")) end),
       usage: ([.[] | select(.type == "turn.completed") | .usage] | last),
       session_id: ([.[] | select(.type == "thread.started") | .thread_id] | last)}
    ' "$events" > "$out"; then
    jq -n --rawfile stderr "$errors" \
      '{provider: "codex", is_error: true, result: ("Invalid Codex event stream\n" + $stderr)}' > "$out"
  fi
  return "$rc"
}

# ── stage <label> <model> <effort> <prompt> <outfile> [extra CLI args...] ──
# Runs one fresh CLI process. Retries with backoff on fast failures. Three
# outcomes are deliberately NOT retried, each for a different reason:
#   timeout        — attempt 2 would start on attempt 1's half-finished tree
#   account limit  — resets on the billing cycle, not in 15 minutes
#   (success)      — obviously
stage() {
  local label="$1" model="$2" effort="$3" prompt="$4" out="$5"; shift 5
  local attempt rc=1
  local -a runner=()
  # The run-total ceiling is checked BETWEEN stages, never inside one: killing a
  # stage mid-edit to save money leaves a tree no one can resume from. Refusing
  # to start the next one is recoverable — the caller bails, pushes what exists,
  # and prints the resume command.
  if [[ "$TOTAL_BUDGET_USD" != "0" ]]; then
    local spent; spent=$(spent_usd)
    if awk -v s="$spent" -v c="$TOTAL_BUDGET_USD" 'BEGIN { exit !(s + 0 >= c + 0) }'; then
      warn "$label not started: run total \$$spent reached TOTAL_BUDGET_USD=\$$TOTAL_BUDGET_USD"
      return 1
    fi
  fi
  [[ -n "$TIMEOUT_BIN" ]] && runner=("$TIMEOUT_BIN" -k 60 "$STAGE_TIMEOUT")
  for attempt in $(seq 1 "$MAX_ATTEMPTS"); do
    if (( attempt > 1 )); then
      log "     retry $attempt/$MAX_ATTEMPTS in ${BACKOFF[attempt-1]}s"
      sleep "${BACKOFF[attempt-1]}"
    fi
    log "   ▶ $label ($model${effort:+ $effort})"
    if [[ "$LOOP_CLI" == codex ]]; then
      run_codex_stage "$model" "$effort" "$prompt" "$out" "$@"
      rc=$?
    else
      ${runner[@]+"${runner[@]}"} claude -p "$prompt" \
        --model "$model" ${effort:+--effort "$effort"} \
        --permission-mode "$PERMISSION_MODE" \
        --allowedTools "$TOOLS" \
        "${BUDGET_ARGS[@]}" \
        --output-format json \
        "$@" > "$out" 2>>"$LOG"
      rc=$?
    fi
    # A result document is not success. A 429 carries subtype:"success" AND
    # is_error:true AND a .result string — gating on `.result` existing (the
    # obvious check) scores every rate-limited stage as a pass. Gate on is_error.
    if [[ $rc -eq 0 ]] && jq -e '(.is_error == false) and (.result != null)' "$out" >/dev/null 2>&1; then
      return 0
    fi
    if [[ $rc -eq 124 || $rc -eq 137 ]]; then
      warn "$label timed out after ${STAGE_TIMEOUT}s — not retrying (tree is mid-edit)"
      return 1
    fi
    # Retrying into an exhausted account burns an hour of backoff and a dozen
    # pointless API calls re-confirming the same 429 across every remaining
    # stage. Stop the run instead, with the branch left recoverable. An empty
    # API-key balance is the same situation arriving as a 400.
    if jq -e '(.is_error == true) and (.api_error_status == 429 or .api_error_status == 400 or .provider == "codex")
              and ((.result // "") | test("spend limit|usage limit|rate limit|credit balance|quota|usage_limit|rate_limit"; "i"))' \
         "$out" >/dev/null 2>&1; then
      warn "$label: $(jq -r '.result' "$out" 2>/dev/null | head -1)"
      warn "ACCOUNT LIMIT REACHED — aborting; remaining work is untouched"
      USAGE_LIMIT_HIT=1
      return 1
    fi
    # An API error still carries subtype:"success", so printing .subtype logs
    # "success" for a failure. When is_error is set, .result holds the message.
    local why
    why=$(jq -r 'if .is_error then "\(.api_error_status // "error") \(.result // "")"
                 else (.subtype // .error // empty) end' "$out" 2>/dev/null | head -1)
    [[ -n "$why" ]] && warn "$label: $why"
  done
  warn "$label failed after $MAX_ATTEMPTS attempts (exit $rc) — see $out"
  return 1
}

slugify() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-50 | sed -E 's/-+$//'
}

spent_usd() {
  # nullglob so an unmatched pattern drops out instead of reaching jq as a
  # literal filename — that makes jq exit nonzero AFTER printing, so `|| echo 0`
  # appends a second line and the total reads "$0.080385\n0".
  local files=()
  shopt -s nullglob
  files=( "$RUN_DIR"/*/*.json "$RUN_DIR"/*.json )
  shopt -u nullglob
  (( ${#files[@]} )) || { echo 0; return 0; }
  jq -s 'map(.total_cost_usd // 0)|add // 0' "${files[@]}" 2>/dev/null || echo 0
}

report_cost() {
  if [[ "$LOOP_CLI" == codex ]]; then
    echo "cost:   unavailable (Codex records token usage in stage JSON)"
  else
    printf 'cost:   $%s\n' "$(spent_usd)"
  fi
}

# Return the tree to a known-good state.
#
# `git clean -fd` obeys the .gitignore of whatever branch is checked out, and
# feature branches predate any rule added on the base branch. Anything
# untracked that must survive belongs in .git/info/exclude (per-clone,
# branch-independent), never .gitignore alone. preflight_common enforces that.
# Ignored build output (target/, build/, node_modules/) is safe from -fd —
# losing it would mean a long rebuild.
reset_tree() {
  git reset --hard >>"$LOG" 2>&1
  git clean -fd    >>"$LOG" 2>&1
  git worktree prune >>"$LOG" 2>&1
}

# Land back on the base branch, up to date. The pull is the point: a loop that
# checks out the base branch at the end of every run and never pulls leaves it
# behind origin, and the next thing you commit there lands on a stale tip.
return_to_base() {
  reset_tree
  git checkout "$BASE_BRANCH" >>"$LOG" 2>&1
  git pull --ff-only          >>"$LOG" 2>&1
}

# Capture anything a skill left uncommitted, so it cannot ride onto the next
# branch. Returns 0 when there was nothing to commit or the commit landed, and 1
# when git refused it — a pre-commit hook, a missing identity, a full disk. The
# caller must stop on 1: the stage's edits then exist only in this worktree, and
# pushing HEAD would publish the branch without them.
commit_leftovers() {
  [[ -n "$(git status --porcelain)" ]] || return 0
  if git add -A >>"$LOG" 2>&1 && git commit -qm "$1" >>"$LOG" 2>&1; then
    log "   captured uncommitted leftovers"
    return 0
  fi
  warn "could not commit leftovers ('$1') — the edits remain uncommitted in the worktree; git's error is in $LOG"
  return 1
}

# ── preflight_common ──────────────────────────────────────────────────────
# Everything an entrypoint must verify before it touches anything. Exits 2 on a
# hard stop; warns and continues where a human would.
preflight_common() {
  log "preflight"
  log "   host: ${CORES} cores, ${MEM_TOTAL_MB} MB RAM, ${SWAP_TOTAL_MB} MB swap, ${DISK_FREE_GB} GB free"
  log "   budget: ${LOOPS_SHARING} loop(s) on this host — -j${BUILD_JOBS} per agent, ${SUBAGENT_CAP} subagent(s), worktrees=${ALLOW_WORKTREES}"
  [[ "$SHARE_BELOW_ONE_JOB" == yes ]] \
    && warn "each of ${LOOPS_SHARING} loops gets ${SHARE_MEM_MB} MB, less than one ${MB_PER_JOB} MB build job — concurrent builds can exhaust RAM"
  local bin
  for bin in "$LOOP_CLI" gh jq git awk sed df; do
    command -v "$bin" >/dev/null || { warn "missing: $bin"; exit 2; }
  done
  if [[ "$LOOP_CLI" == codex ]]; then
    codex login status >>"$LOG" 2>&1 \
      || { warn "codex not authenticated — run: codex login"; exit 2; }
    log "   auth: existing Codex CLI login"
  else
    # Unsetting the key vars (see LOOP_AUTH) is not proof of subscription billing:
    # an apiKeyHelper in settings.json or a Console login still bills the API, and
    # with no login at all every stage fails rather than falling back. Ask claude
    # which credentials it will actually use, and stop before any stage runs.
    local auth
    auth=$(claude auth status 2>/dev/null || true)
    if [[ "$LOOP_AUTH" == subscription ]]; then
      if ! jq -e . >/dev/null 2>&1 <<<"$auth"; then
        warn "cannot read 'claude auth status' — billing source unverified"
      elif jq -e '.loggedIn != true or .apiKeySource != null or .subscriptionType == null' \
             >/dev/null 2>&1 <<<"$auth"; then
        warn "LOOP_AUTH=subscription, but claude would not bill a claude.ai subscription:"
        warn "   $(jq -c '{loggedIn, authMethod, apiKeySource, subscriptionType}' <<<"$auth")"
        warn "   run 'claude auth login', or set LOOP_AUTH=api-key to bill an API key"
        exit 2
      else
        log "   auth: claude.ai $(jq -r .subscriptionType <<<"$auth") subscription (API key vars unset for this run)"
      fi
    elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
      log "   auth: ANTHROPIC_API_KEY (LOOP_AUTH=api-key)"
    else
      log "   auth: LOOP_AUTH=api-key but ANTHROPIC_API_KEY is not set — falling back to claude.ai login"
    fi
  fi

  [[ -n "$TIMEOUT_BIN" ]] \
    || warn "no timeout/gtimeout on PATH — a wedged stage will hang forever (brew install coreutils)"
  gh auth status >/dev/null 2>&1 || { warn "gh not authenticated — run: gh auth login"; exit 2; }
  git ls-remote --exit-code origin >/dev/null 2>&1 \
    || { warn "cannot reach origin — check the network and your git credentials"; exit 2; }

  # These must be ignored on EVERY branch, not just the base one. .gitignore is
  # tracked and therefore branch-scoped, so a rule added on main does not exist
  # on a feature branch — and both reset_tree()'s `git clean -fd` and
  # commit_leftovers' `git add -A` obey whichever branch is checked out. Left
  # unignored, `add -A` commits the loop's own files into the PR it is
  # building, and a later `git checkout main` then deletes them outright.
  # git check-ignore consults .git/info/exclude too, so this passes only if the
  # branch-independent rule is in place. Run it on the CURRENT branch, which is
  # the one the run is about to operate on.
  #
  # A path that is TRACKED in your repo is exempt: `add -A` cannot add it
  # anew and `clean -fd` will not touch it. That is the normal case when you
  # commit these scripts into your own project rather than keeping them local.
  local must_ignore
  for must_ignore in "${MUST_IGNORE[@]}"; do
    git check-ignore -q "$must_ignore" && continue
    git ls-files --error-unmatch "$must_ignore" >/dev/null 2>&1 && continue
    warn "$must_ignore is untracked and not ignored on branch $(git branch --show-current)."
    warn "  'git add -A' will commit it into the PR and 'git clean -fd' will delete it."
    warn "  fix: printf '%s\\n' '$must_ignore' >> .git/info/exclude"
    warn "  (or commit it to your repo — a tracked path is safe from both)"
    exit 2
  done

  [[ -z "$(git status --porcelain)" ]] \
    || { warn "working tree is dirty — commit or stash first"; exit 2; }

  # Only a worktree nested inside this checkout is a hazard: `git add -A` would
  # commit it as an embedded repository. Sibling worktrees, including other
  # loops running in parallel, never touch this tree.
  git worktree prune
  local nested
  nested=$(git worktree list --porcelain | sed -n 's/^worktree //p' | grep -F "$REPO_ROOT/")
  if [[ -n "$nested" ]]; then
    warn "git worktrees inside this checkout — remove them first:"; tee -a "$LOG" <<<"$nested"; exit 2
  fi

  (( DISK_FREE_GB >= MIN_DISK_GB )) \
    || { warn "only ${DISK_FREE_GB} GB free — a build needs headroom (MIN_DISK_GB=${MIN_DISK_GB})."; exit 2; }

  [[ -r "$LOOP_NOTES" ]] \
    || log "   no $LOOP_NOTES — stages will infer build and test commands from the repo"

  # Plain -f tests, deliberately not `find ... | grep -q .`: on some hosts
  # `find` is bfs, which exits 1 when ANY starting path is missing (most of
  # these usually are), and under `set -o pipefail` that reports failure even
  # though grep matched — a false warning every time, which hides the real one.
  local cmd d found
  local -a command_dirs=() skill_dirs=(.agents/skills "$HOME/.agents/skills" "${CODEX_HOME:-$HOME/.codex}/skills")
  if [[ "$LOOP_CLI" == claude ]]; then
    command_dirs=(.claude/commands "$HOME/.claude/commands")
    skill_dirs=(.claude/skills "$HOME/.claude/skills" .agents/skills "$HOME/.agents/skills")
  fi
  for cmd in spec-from-issue implement-spec techdebt branch-review update-context clear-technical-writing; do
    found=0
    for d in ${command_dirs[@]+"${command_dirs[@]}"}; do
      [[ -f "$d/${cmd}.md" ]] && { found=1; break; }
    done
    if (( ! found )); then
      for d in "${skill_dirs[@]}"; do
        [[ -f "$d/${cmd}/SKILL.md" ]] && { found=1; break; }
      done
    fi
    (( found )) || warn "no skill or command found for $cmd — the run will fail at that stage (run ./install.sh)"
  done

  # The labels the loop signals through. Creating them is idempotent and cheap;
  # discovering they were missing after an unattended run is neither.
  gh label create "$NEEDS_HUMAN_LABEL" --color B60205 \
    --description "Unattended run stopped here; a human must look" >/dev/null 2>&1 \
    || log "   label $NEEDS_HUMAN_LABEL already exists"
  gh label create "$TECHDEBT_LABEL" --color FBCA04 \
    --description "Deferred cleanup" >/dev/null 2>&1 \
    || log "   label $TECHDEBT_LABEL already exists"
}

# The reviewer prompt, in one place so the round-N pass and the final
# verification pass cannot drift into judging by different standards.
review_prompt() {
  local base="$1"
  cat <<EOF
/branch-review ${base}

/clear-technical-writing

Review in full, in prose, exactly as you normally would. Do not compress your
findings into a list for a machine.

The feature branch is intentionally still local at this point. Review the local
merge-base diff against origin/${base}; do not require an upstream branch
or an open pull request, and do not push anything.

${RESOURCE_NOTE}

Then, as the very last line of your final message, on its own line, in exactly
this form and nothing else:

BLOCKING: <count of findings you rated critical or major>
EOF
}

# ── review_fix_cycle <issue> <dir> <spec> <base> ──────────────────────────
# The reviewer/fixer ping-pong. Sets BLOCKING:
#   0   clean
#   >0  findings remain after MAX_REVIEW_ROUNDS
#   -1  a stage failed, or the reviewer emitted no sentinel — unverified
# Returns 1 when a fix round's edits cannot be committed. The tree then holds
# changes that no commit records, so the caller must stop rather than review,
# document, or push around them.
# Keeps all fixes local. Does not touch labels; the caller owns that.
review_fix_cycle() {
  local issue="$1" dir="$2" spec="$3" base="$4" round
  BLOCKING=0
  for round in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
    stage "review r$round" "$PLAN_MODEL" "$PLAN_EFFORT" \
      "$(review_prompt "$base")" "$dir/review-$round.json" || { BLOCKING=-1; break; }

    jq -r '.result' "$dir/review-$round.json" > "$dir/review-$round.md"
    BLOCKING=$(grep -oE '^BLOCKING:[[:space:]]*[0-9]+' "$dir/review-$round.md" \
                 | tail -1 | grep -oE '[0-9]+')
    if [[ -z "$BLOCKING" ]]; then
      warn "review r$round emitted no BLOCKING line — treating as unresolved"
      BLOCKING=-1; break
    fi
    log "   review r$round: $BLOCKING blocking"
    (( BLOCKING == 0 )) && break

    stage "fix r$round" "$CODE_MODEL" "$CODE_EFFORT" "$(cat <<EOF
The full branch review is at ${dir}/review-${round}.md. Read it.

Fix every finding the review rates critical or major.

You are a fresh reader, not the reviewer. If a finding is wrong — it
contradicts the spec at ${spec}, or it misreads the code — do NOT implement
it. Say so plainly in your final message and leave the code alone. Fixing a
false positive is worse than leaving the finding open.

Tests stay green. A fix without a test that would have caught the finding is
not done.

Do NOT fix medium or minor findings. Collect them into ONE issue for this branch —
one across ALL review rounds, not one per round. You are a fresh process with
no memory of earlier rounds, so an issue may already exist. Look before you
file:

  gh issue list --state open --label ${TECHDEBT_LABEL} \\
    --search "Deferred review findings from #${issue} in:title" --json number,title

If one comes back, append to it and skip anything already listed there:
  gh issue comment <number> --body "<one bullet per NEW finding, with file:line>"

If nothing comes back, create it:
  gh issue create --label ${TECHDEBT_LABEL} \\
    --title "Deferred review findings from #${issue}" \\
    --body "<one bullet per finding, with file:line>"

Never open a second issue with that title, and never one issue per finding.
Then commit.

${RESOURCE_NOTE}
EOF
)" "$dir/fix-$round.json" || { BLOCKING=-1; break; }

    commit_leftovers "fix(#$issue): review round $round leftovers" || return 1
  done

  # Falling out of the loop with BLOCKING > 0 means the last thing that ran was
  # a FIX, so that number describes the code as it was before the fix. Re-review
  # once and report what is actually left. -1 (a failed stage) is not re-reviewed
  # — the tree is in an unknown state and a clean verdict would be a lie.
  if (( FINAL_VERIFY_REVIEW )) && (( BLOCKING > 0 )); then
    if stage "review verify" "$PLAN_MODEL" "$PLAN_EFFORT" \
         "$(review_prompt "$base")" "$dir/review-verify.json"; then
      jq -r '.result' "$dir/review-verify.json" > "$dir/review-verify.md"
      local verified
      verified=$(grep -oE '^BLOCKING:[[:space:]]*[0-9]+' "$dir/review-verify.md" \
                   | tail -1 | grep -oE '[0-9]+')
      if [[ -n "$verified" ]]; then
        log "   review verify: $verified blocking (was $BLOCKING before the last fix)"
        BLOCKING="$verified"
      else
        warn "review verify emitted no BLOCKING line — keeping the pre-fix count"
      fi
    else
      warn "review verify failed — reporting the pre-fix count, which may be stale"
    fi
  fi
  return 0
}

# ── run_update_context <issue> <dir> <spec> ───────────────────────────────
# Context is derived from the local branch diff so the documentation is
# complete before the branch is pushed and the PR is opened.
run_update_context() {
  local issue="$1" dir="$2" spec="$3"
  stage "update-context" "$CODE_MODEL" "$CODE_EFFORT" "$(cat <<EOF
/update-context ${BASE_BRANCH}

/clear-technical-writing

Use issue #${issue}, the implementation spec at ${spec}, and the local
merge-base diff against origin/${BASE_BRANCH}. Do not fetch, push, check out
another branch, or open a pull request.

${RESOURCE_NOTE}
EOF
)" "$dir/ctx.json" || { warn "#$issue: update-context failed"; return 1; }
  commit_leftovers "docs(#$issue): update AGENTS.md context" || return 1
  return 0
}
