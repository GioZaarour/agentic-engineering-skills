#!/usr/bin/env bash
#
# loops-lib.sh — shared core for the unattended issue loop.
#
# Sourced by:
#   issue-loop.sh   one GitHub issue, spec → implement → PR → review → context
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
if (( BASH_VERSINFO[0] < 4 )); then
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
#   BASE_BRANCH=v0/feature/56-history ./scripts/issue-loop.sh 57
BASE_BRANCH="${BASE_BRANCH:-main}"

PLAN_MODEL="${PLAN_MODEL:-claude-opus-5}"    # spec derivation, spec review, PR review
CODE_MODEL="${CODE_MODEL:-claude-sonnet-5}"  # implementation, tech debt, fixes, context

XHIGH="${XHIGH:-xhigh}"        # verified against `claude --help`:
HIGH="${HIGH:-high}"           #   --effort accepts low|medium|high|xhigh|max

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
# the one the review found BEFORE that fix ran — a PR can be labelled "2
# blocking" when the last fix round already addressed both. Set this to 1 to
# spend one more review pass and report a number that describes the code as it
# actually stands. Off by default here; issue-loop.sh turns it on, because a
# single-issue run has no queue to get through and a wrong needs-human label on
# the only PR is the whole output of the run.
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
DISK_FREE_GB=$(detect_disk_gb "$REPO_ROOT"); [[ "$DISK_FREE_GB" =~ ^[0-9]+$ ]] || DISK_FREE_GB=0

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
BUILD_JOBS=${BUILD_JOBS:-$(( MEM_TOTAL_MB / MB_PER_JOB ))}
(( BUILD_JOBS > CORES )) && BUILD_JOBS=$CORES
(( BUILD_JOBS < 1 ))     && BUILD_JOBS=1

# Concurrent subagents, and whether a stage may cut its own worktree. A
# worktree that builds needs its own copy of every build artifact, so disk —
# not RAM — is what gates it.
WORKTREE_DISK_GB="${WORKTREE_DISK_GB:-20}"
MIN_DISK_GB="${MIN_DISK_GB:-5}"

if (( CORES < 4 || MEM_TOTAL_MB < 8192 )); then
  SUBAGENT_CAP=1
else
  SUBAGENT_CAP=2
fi
SUBAGENT_CAP=${SUBAGENT_CAP_OVERRIDE:-$SUBAGENT_CAP}

if (( SUBAGENT_CAP > 1 && DISK_FREE_GB >= WORKTREE_DISK_GB )); then
  ALLOW_WORKTREES=yes
else
  ALLOW_WORKTREES=no
fi
ALLOW_WORKTREES=${ALLOW_WORKTREES_OVERRIDE:-$ALLOW_WORKTREES}

# ── the budget every stage is told about ──────────────────────────────────
read -r -d '' RESOURCE_NOTE <<EOF || true
## Machine budget — unattended run, this is a hard constraint

Host: ${CORES} cores, ${MEM_TOTAL_MB} MB RAM$([[ "$MEM_MEASURED" == no ]] && echo " (assumed — could not measure)"), ${SWAP_TOTAL_MB} MB swap, ${DISK_FREE_GB} GB free disk.
No one is watching. If you exhaust RAM or disk, the OOM killer takes this
process down mid-edit and the work is lost, not merely slowed.

- **Run at most ${SUBAGENT_CAP} subagent(s) at a time.** If a skill tells you to fan out
  across independent slices or review surfaces, cap the fan-out at ${SUBAGENT_CAP}.
- **Creating git worktrees is ${ALLOW_WORKTREES} on this host.** If it is "no", work in the
  current tree, one slice at a time — a second worktree needs its own full set
  of build artifacts and there is not room for one.
- **Cap build and test parallelism at ${BUILD_JOBS} job(s)** — \`-j${BUILD_JOBS}\`, \`--jobs ${BUILD_JOBS}\`,
  \`maxWorkers=${BUILD_JOBS}\`, whatever this toolchain calls it. Most build tools default
  to cores or cores+2 and will OOM this machine. If the repo's own docs
  recommend a higher number, **do not "fix" the docs** — that number is right
  for the machine it documents; only this run is constrained.
- Run the tests. A stage that reports success without a green suite has not
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

log()  { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"; }
warn() { printf '%s  !! %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG" >&2; }

# ── stage <label> <model> <effort> <prompt> <outfile> [extra claude args...] ──
# Runs one claude -p process. Retries with backoff on fast failures. Three
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
    ${runner[@]+"${runner[@]}"} claude -p "$prompt" \
      --model "$model" ${effort:+--effort "$effort"} \
      --permission-mode "$PERMISSION_MODE" \
      --allowedTools "$TOOLS" \
      "${BUDGET_ARGS[@]}" \
      --output-format json \
      "$@" > "$out" 2>>"$LOG"
    rc=$?
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
    # stage. Stop the run instead, with the branch left recoverable.
    if jq -e '(.api_error_status == 429)
              and ((.result // "") | test("spend limit|usage limit|rate limit"; "i"))' \
         "$out" >/dev/null 2>&1; then
      warn "$label: $(jq -r '.result' "$out" 2>/dev/null | head -1)"
      warn "ACCOUNT LIMIT REACHED — aborting; remaining work is untouched"
      USAGE_LIMIT_HIT=1
      return 1
    fi
    jq -r '.subtype // .error // empty' "$out" 2>/dev/null | head -1 \
      | grep -q . && warn "$label: $(jq -r '.subtype // .error' "$out" 2>/dev/null | head -1)"
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
# branch. Returns 0 whether or not there was anything.
commit_leftovers() {
  if [[ -n "$(git status --porcelain)" ]]; then
    git add -A && git commit -qm "$1" >>"$LOG" 2>&1
    log "   captured uncommitted leftovers"
  fi
  return 0
}

# ── preflight_common ──────────────────────────────────────────────────────
# Everything an entrypoint must verify before it touches anything. Exits 2 on a
# hard stop; warns and continues where a human would.
preflight_common() {
  log "preflight"
  log "   host: ${CORES} cores, ${MEM_TOTAL_MB} MB RAM, ${SWAP_TOTAL_MB} MB swap, ${DISK_FREE_GB} GB free"
  log "   budget: -j${BUILD_JOBS} builds, ${SUBAGENT_CAP} subagent(s), worktrees=${ALLOW_WORKTREES}"

  local bin
  for bin in claude gh jq git awk sed df; do
    command -v "$bin" >/dev/null || { warn "missing: $bin"; exit 2; }
  done
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

  git worktree prune
  if [[ $(git worktree list | wc -l) -gt 1 ]]; then
    warn "extra git worktrees present — remove them first:"; git worktree list | tee -a "$LOG"; exit 2
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
  for cmd in spec-from-issue implement-spec techdebt pr-review update-context clear-technical-writing; do
    found=0
    for d in .claude/commands "$HOME/.claude/commands"; do
      [[ -f "$d/${cmd}.md" ]] && { found=1; break; }
    done
    if (( ! found )); then
      for d in .claude/skills "$HOME/.claude/skills" .agents/skills "$HOME/.agents/skills"; do
        [[ -f "$d/${cmd}/SKILL.md" ]] && { found=1; break; }
      done
    fi
    (( found )) || warn "no skill or command found for /$cmd — the run will fail at that stage (run ./install.sh)"
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
  cat <<EOF
/pr-review ${1}

/clear-technical-writing

Review in full, in prose, exactly as you normally would. Do not compress your
findings into a list for a machine.

${RESOURCE_NOTE}

Then, as the very last line of your final message, on its own line, in exactly
this form and nothing else:

BLOCKING: <count of findings you rated critical or major>
EOF
}

# ── review_fix_cycle <issue> <dir> <spec> <pr-num> ────────────────────────
# The reviewer/fixer ping-pong. Sets BLOCKING:
#   0   clean
#   >0  findings remain after MAX_REVIEW_ROUNDS
#   -1  a stage failed, or the reviewer emitted no sentinel — unverified
# Pushes after each fix round. Does not touch labels; the caller owns that.
review_fix_cycle() {
  local issue="$1" dir="$2" spec="$3" prnum="$4" round
  BLOCKING=0
  for round in $(seq 1 "$MAX_REVIEW_ROUNDS"); do
    stage "review r$round" "$PLAN_MODEL" "$XHIGH" \
      "$(review_prompt "$prnum")" "$dir/review-$round.json" || { BLOCKING=-1; break; }

    jq -r '.result' "$dir/review-$round.json" > "$dir/review-$round.md"
    BLOCKING=$(grep -oE '^BLOCKING:[[:space:]]*[0-9]+' "$dir/review-$round.md" \
                 | tail -1 | grep -oE '[0-9]+')
    if [[ -z "$BLOCKING" ]]; then
      warn "review r$round emitted no BLOCKING line — treating as unresolved"
      BLOCKING=-1; break
    fi
    log "   review r$round: $BLOCKING blocking"
    (( BLOCKING == 0 )) && break

    stage "fix r$round" "$CODE_MODEL" "$XHIGH" "$(cat <<EOF
The full PR review for this branch is at ${dir}/review-${round}.md. Read it.

Fix every finding the review rates critical or major.

You are a fresh reader, not the reviewer. If a finding is wrong — it
contradicts the spec at ${spec}, or it misreads the code — do NOT implement
it. Say so plainly in your final message and leave the code alone. Fixing a
false positive is worse than leaving the finding open.

Tests stay green. A fix without a test that would have caught the finding is
not done.

Do NOT fix medium or minor findings. Collect them into ONE issue for this PR —
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

    commit_leftovers "fix(#$issue): review round $round leftovers"
    git push >>"$LOG" 2>&1
  done

  # Falling out of the loop with BLOCKING > 0 means the last thing that ran was
  # a FIX, so that number describes the code as it was before the fix. Re-review
  # once and report what is actually left. -1 (a failed stage) is not re-reviewed
  # — the tree is in an unknown state and a clean verdict would be a lie.
  if (( FINAL_VERIFY_REVIEW )) && (( BLOCKING > 0 )); then
    if stage "review verify" "$PLAN_MODEL" "$XHIGH" \
         "$(review_prompt "$prnum")" "$dir/review-verify.json"; then
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

# ── run_update_context <issue> <pr-num> <dir> ─────────────────────────────
# The skill is `# Update Context from PR #$1` and opens with `gh pr checkout $1`
# — it needs the number, not a branch.
run_update_context() {
  local issue="$1" prnum="$2" dir="$3"
  stage "update-context" "$CODE_MODEL" "$HIGH" "$(cat <<EOF
/update-context ${prnum}

/clear-technical-writing

${RESOURCE_NOTE}
EOF
)" "$dir/ctx.json" || { warn "#$issue: update-context failed (the PR itself is fine)"; return 1; }
  commit_leftovers "docs(#$issue): update AGENTS.md context"
  git push >>"$LOG" 2>&1
  return 0
}
