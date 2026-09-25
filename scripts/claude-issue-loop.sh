#!/usr/bin/env bash
#
# claude-issue-loop.sh — take ONE GitHub issue from "open" to "PR under review", unattended.
#
#   ./scripts/claude-issue-loop.sh 19
#   ./scripts/claude-issue-loop.sh 19 --dry-run
#   ./scripts/claude-issue-loop.sh 19 --from implement
#
# One issue, one branch, one PR, start to finish, with nobody watching. It is
# written to ADOPT whatever already exists rather than assume it is starting
# from nothing: by the time you reach for this you often already have a branch,
# and sometimes a half-written spec, and losing either to a `checkout -B` is the
# failure mode that matters.
#
# What it does, in order:
#   0. preflight   — tools, auth, clean tree, branch-independent ignores, disk
#   1. resolve     — issue facts; find the branch and spec that already exist,
#                    by convention first and by cheap-model fallback second
#   2. sync        — fetch, adopt-or-create the branch, fast-forward, report drift
#   3. spec        — /spec-from-issue, deriving fresh or iterating on what is there
#   4. spec-review — non-interactive critique passes over the spec (default 1)
#   5. implement   — /implement-spec, test-first, slice by slice
#   6. techdebt    — /techdebt over the whole branch
#   7. review      — /branch-review ⇄ fix, ending on a review so the count is honest
#   8. context     — /update-context against the local branch diff
#   9. pr          — push, write a description from the final diff, open the PR
#
# Every stage is a separate `claude -p` or `codex exec` process with a clean
# context window. State moves between them through git and files on disk.
#
# Detached:  tmux new -d -s issue19 './scripts/claude-issue-loop.sh 19'
#            tail -f .loops/latest/run.log
#
# Exit codes are load-bearing:
#   0  selected stages complete; review clean if one ran
#   2  preflight or usage error — nothing was touched
#   3  needs a human: the spec BLOCKED, or findings remain after the fix rounds
#   4  account spend/usage limit — resume with --from once it resets
#   5  a stage failed; the branch is pushed and recoverable, see the resume hint
#
# Config, the measured machine budget, and stage() live in loops-lib.sh.
# Anything project-specific — how to build, how to test — goes in .loop-notes.md.

set -uo pipefail
# Codex sources this workflow so both entrypoints run the same stages and prompts.
LOOP_CLI="${LOOP_CLI:-claude}"
LOOP_SCRIPT="${LOOP_CLI}-issue-loop.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./loops-lib.sh
source "$SCRIPT_DIR/loops-lib.sh" || {
  echo "cannot source loops-lib.sh — it must sit next to this script." >&2
  echo "if you keep these scripts untracked, they must be listed in" >&2
  echo ".git/info/exclude (branch-independent), not just .gitignore." >&2
  exit 2
}

# If these scripts are untracked in your repo, `git add -A` in commit_leftovers
# would otherwise commit them into the PR being built. preflight_common skips
# this check for a path you have committed to your own repo.
MUST_IGNORE+=("scripts/claude-issue-loop.sh")
[[ -f "$SCRIPT_DIR/codex-issue-loop.sh" ]] && MUST_IGNORE+=("scripts/codex-issue-loop.sh")

# Report the number of blocking findings that survive the LAST fix, not the one
# the review before it counted. Worth one extra review pass here: a single-issue
# run has no queue to get through, and a wrong needs-human label on the issue
# misrepresents the whole output of the run. Its own env var because the lib
# has already defaulted FINAL_VERIFY_REVIEW to 0 by the time this line runs.
FINAL_VERIFY_REVIEW="${ISSUE_LOOP_FINAL_VERIFY:-1}"

STAGE_ORDER=(spec spec-review implement techdebt review context pr)

# The fallback matcher selects existing branches and specs from lists of names.
# Claude uses Sonnet here; Codex uses its default model, both at medium effort.
ADOPT_MODEL="${ADOPT_MODEL:-$DEFAULT_ADOPT_MODEL}"
ADOPT_EFFORT="${ADOPT_EFFORT:-medium}"

usage() {
  cat <<EOF
usage: ./scripts/${LOOP_SCRIPT} <issue-number> [options]

  --dry-run           resolve everything, print the plan, change nothing
  --from <stage>      run this stage and every stage after it
  --stages a,b,c      run exactly these stages
  --skip a,b          drop these stages from whatever else selected
  --spec-rounds N     spec critique passes after derivation (default 1, 0 = off)
  --fresh-spec        re-derive the spec even though one already exists
  --type <t>          bugfix | feature | perf | ... (default: inferred)
  --version <v>       path segment under specs/ and in the branch (default: v0)
  --base <branch>     branch to base the PR on (default: main)
  --branch <name>     use this branch instead of the inferred one
  --spec <path>       use this spec path instead of the inferred one
  --merge-base        merge origin/<base> into the branch if it has fallen behind
  --no-push           never push and never open a PR (implies --skip pr)
  --no-adopt          skip the fallback matcher; if the naming convention was not
                      followed, just create the conventional branch and spec

stages: spec, spec-review, implement, techdebt, review, context, pr
EOF
}

# ── arguments ─────────────────────────────────────────────────────────────
ISSUE=""; DRY_RUN=0; FRESH_SPEC=0; NO_PUSH=0; MERGE_BASE=0; ADOPT_AGENT=1
TYPE_FLAG=""; VERSION_FLAG=""; BRANCH_FLAG=""; SPEC_FLAG=""
SPEC_REVIEW_ROUNDS="${SPEC_REVIEW_ROUNDS:-1}"
STAGES=""; SKIP=""

join_stages() { local IFS=,; echo "$*"; }

# Returns 1 rather than exiting: it is called inside $( ), where `exit` ends the
# subshell and nothing else. That hole made `--from bogus` set STAGES to the
# empty string, fall through to the "no --stages given" default, and quietly
# start a full unattended run — the opposite of what a typo should do.
stages_from() {
  local want="$1" out=() hit=0 s
  for s in "${STAGE_ORDER[@]}"; do
    [[ "$s" == "$want" ]] && hit=1
    (( hit )) && out+=("$s")
  done
  (( hit )) || { echo "unknown stage: $want (stages: ${STAGE_ORDER[*]})" >&2; return 1; }
  join_stages "${out[@]}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --from)         STAGES=$(stages_from "$2") || exit 2; shift 2 ;;
    --from=*)       STAGES=$(stages_from "${1#*=}") || exit 2; shift ;;
    --stages)       STAGES="$2"; shift 2 ;;
    --stages=*)     STAGES="${1#*=}"; shift ;;
    --skip)         SKIP="$2"; shift 2 ;;
    --skip=*)       SKIP="${1#*=}"; shift ;;
    --spec-rounds)  SPEC_REVIEW_ROUNDS="$2"; shift 2 ;;
    --fresh-spec)   FRESH_SPEC=1; shift ;;
    --type)         TYPE_FLAG="$2"; shift 2 ;;
    --version)      VERSION_FLAG="$2"; shift 2 ;;
    --base)         BASE_BRANCH="$2"; shift 2 ;;
    --branch)       BRANCH_FLAG="$2"; shift 2 ;;
    --spec)         SPEC_FLAG="$2"; shift 2 ;;
    --merge-base)   MERGE_BASE=1; shift ;;
    --no-push)      NO_PUSH=1; shift ;;
    --no-adopt)     ADOPT_AGENT=0; shift ;;
    -h|--help)      usage; exit 0 ;;
    -*)             echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
    *)              [[ -n "$ISSUE" ]] && { echo "one issue at a time" >&2; exit 2; }
                    ISSUE="$1"; shift ;;
  esac
done

[[ "$ISSUE" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
[[ -n "$STAGES" ]] || STAGES=$(join_stages "${STAGE_ORDER[@]}")
(( NO_PUSH )) && SKIP="${SKIP:+$SKIP,}pr"

# Materialise the selection once, so `want` is a lookup and not a parse.
declare -A WANT=()
IFS=, read -ra _sel <<<"$STAGES"
for s in "${_sel[@]}"; do [[ -n "$s" ]] && WANT["$s"]=1; done
IFS=, read -ra _skip <<<"$SKIP"
for s in "${_skip[@]}"; do [[ -n "$s" ]] && unset 'WANT[$s]'; done
for s in "${!WANT[@]}"; do
  [[ " ${STAGE_ORDER[*]} " == *" $s "* ]] || { echo "unknown stage: $s" >&2; exit 2; }
done
want() { [[ -n "${WANT[$1]:-}" ]]; }

SELECTED=()
for s in "${STAGE_ORDER[@]}"; do want "$s" && SELECTED+=("$s"); done
(( ${#SELECTED[@]} )) || { echo "no stages selected" >&2; exit 2; }

# ── issue → branch, type, spec ────────────────────────────────────────────

# A branch belongs to an issue when the number is a whole path segment prefix:
# `v0/feature/19-…` matches 19, `v0/feature/190-…` does not. Substring matching
# here would silently adopt the wrong branch, and the first thing this script
# does with a branch is commit to it.
issue_branch_re() { printf '(^|/)%s[-_]' "$1"; }

find_issue_branch() {
  local cur re; re=$(issue_branch_re "$ISSUE")
  cur=$(git branch --show-current)
  # Prefer the branch you are standing on. If you checked it out by hand it is
  # the one you meant, even when its slug does not match the issue title.
  if [[ -n "$cur" && "$cur" =~ $re ]]; then printf '%s\n' "$cur"; return 0; fi
  git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
    | sed -E 's#^origin/##' | grep -vx 'HEAD' | sort -u | grep -E "$re" | head -1
}

# Bash globs, deliberately not `find`: on this host `find` is bfs, which exits 1
# when any start path is missing, and under pipefail that reads as "no spec"
# rather than "no specs/ directory". nullglob makes an unmatched pattern vanish
# instead of arriving as a literal filename.
find_issue_spec() {
  local hits=()
  shopt -s nullglob
  hits=( specs/*/*/"$ISSUE"[-_]*.md specs/*/"$ISSUE"[-_]*.md )
  shopt -u nullglob
  (( ${#hits[@]} )) && printf '%s\n' "${hits[0]}"
}

# `v0/feature/19-ui` → v0 feature. Also reads `specs/v0/feature/19-ui.md`.
path_segment() { awk -F/ -v n="$2" '{print (NF >= 3 ? $n : "")}' <<<"$1"; }

# Type from the issue's own metadata — no side effects, so it can be called
# before the branch is known and again as the last tier of the real precedence
# chain. Labels are often the WEAKEST signal available: many repos label by area
# (frontend, backend, docs) rather than by kind of work, and an area tag says
# nothing about bugfix-vs-feature. Hence the title heuristics below it, and
# hence --type when both are wrong.
infer_type_from_metadata() {
  local labels="$1"
  if   grep -qE "$BUGFIX_LABELS"  <<<"$labels";  then M_TYPE=bugfix;  M_TYPE_SRC="label"
  elif grep -qE "$FEATURE_LABELS" <<<"$labels";  then M_TYPE=feature; M_TYPE_SRC="label"
  elif grep -qiE '\b(fix|bug|broken|regression|crash|blocker|leak|hang)\b' <<<"$TITLE"; then
       M_TYPE=bugfix;  M_TYPE_SRC="title"
  elif grep -qiE '\b(add|support|introduce|improve|implement|ux|ui)\b' <<<"$TITLE"; then
       M_TYPE=feature; M_TYPE_SRC="title"
  else M_TYPE="$DEFAULT_TYPE"; M_TYPE_SRC="DEFAULT — probably wrong, pass --type"
  fi
}

# ── adopt_with_agent ──────────────────────────────────────────────────────
# The matcher above only recognises the CONVENTION. A branch called `dev/ui-fixes`
# or a spec called `ui-transparency.md` is invisible to it, and missing one costs
# a duplicate branch or a second spec that silently forks the work. So when — and
# only when — the pattern match comes up empty, a cheap model looks at the names
# the way a person would.
#
# It is a SELECTOR, not a decider, and the boundary is enforced rather than
# requested:
#   • it gets read-only tools (Claude) or a read-only sandbox (Codex);
#   • it may only return a string that already appears in the list it was given;
#   • the shell re-checks that string against git and the filesystem, and
#     discards anything invented.
# Naming a branch or spec that does NOT exist stays in the shell, because that
# is a pure function of the convention and a model can only get it wrong. So do
# the sync decisions: whether a divergence is fast-forwardable is a rule, not a
# judgement, and it is the one place an unattended run can destroy history.
adopt_with_agent() {
  local branches spec_list
  branches=$(git for-each-ref --format='%(refname:short)' refs/heads refs/remotes/origin 2>/dev/null \
             | sed -E 's#^origin/##' | grep -vx 'HEAD' | sort -u | head -300)
  shopt -s globstar nullglob
  local spec_files=( specs/**/*.md )
  shopt -u globstar nullglob
  spec_list=$( (( ${#spec_files[@]} )) && printf '%s\n' "${spec_files[@]}" | head -300 )

  local missing=()
  [[ -z "$FOUND_BRANCH" ]] && missing+=(branch)
  [[ -z "$FOUND_SPEC"   ]] && missing+=(spec)
  log "   no conventional ${missing[*]} for #$ISSUE — asking $ADOPT_MODEL whether one exists under another name"

  # Read/Glob/Grep only. The lists are in the prompt; the tools are there so it
  # can open a spec whose filename is ambiguous rather than guess from the name.
  local saved_tools="$TOOLS"
  TOOLS="Read,Glob,Grep"
  stage "adopt" "$ADOPT_MODEL" "$ADOPT_EFFORT" "$(cat <<EOF
A pipeline is about to start work on GitHub issue #${ISSUE} and needs to know
whether a branch or a spec for it ALREADY EXISTS under a name that does not
follow the repo convention.

Issue #${ISSUE}: ${TITLE}

$(jq -r '.body' "$DIR/issue.json" | head -40)

The convention, and what the pipeline will create if nothing exists:
  branch  <version>/<type>/<issue-number>-<slug>   → ${VERSION}/${M_TYPE}/${ISSUE}-${SLUG}
  spec    specs/<version>/<type>/<issue-number>-<slug>.md
                                                  → specs/${VERSION}/${M_TYPE}/${ISSUE}-${SLUG}.md

The pipeline has ALREADY searched for names containing the number ${ISSUE} and
found ${FOUND_BRANCH:-no branch} and ${FOUND_SPEC:-no spec}. Do not re-do that
search. Your job is the case it cannot do: something clearly about this issue
that never mentions its number.

Existing branches:
${branches}

Existing spec files:
${spec_list}

Open any spec whose filename is ambiguous and read enough of it to judge. Never
decide from a filename alone when the filename could go either way.

Answer conservatively. A wrong match makes the pipeline commit this issue's work
onto an unrelated branch, or rewrite a spec for a different feature. NONE is the
common and correct answer, and it is cheap: the pipeline just creates the
conventional name. A near-miss is not a match — "same area of the app" is not
"this issue".

Your entire final message must be exactly these two lines, nothing before or
after, no explanation:

ADOPT_BRANCH: <a branch name copied character-for-character from the list above, or NONE>
ADOPT_SPEC: <a path copied character-for-character from the list above, or NONE>
EOF
)" "$DIR/adopt.json"
  local rc=$?
  TOOLS="$saved_tools"
  (( rc == 0 )) || { warn "adopt matcher failed — falling back to the convention"; return 0; }

  jq -r '.result' "$DIR/adopt.json" > "$DIR/adopt.md" 2>/dev/null
  local a_branch a_spec
  a_branch=$(grep -oE '^ADOPT_BRANCH:.*'  "$DIR/adopt.md" | tail -1 | sed -E 's/^ADOPT_BRANCH:[[:space:]]*//; s/[[:space:]]+$//')
  a_spec=$(  grep -oE '^ADOPT_SPEC:.*'    "$DIR/adopt.md" | tail -1 | sed -E 's/^ADOPT_SPEC:[[:space:]]*//;   s/[[:space:]]+$//')

  # Validate against reality, not against the model's confidence. grep -qxF: a
  # whole-line literal match, so a name that was paraphrased, truncated, or
  # invented cannot slip through as a prefix.
  if [[ -z "$FOUND_BRANCH" && -n "$a_branch" && "$a_branch" != NONE ]]; then
    if [[ "$a_branch" == "$BASE_BRANCH" ]]; then
      warn "adopt: refusing '$a_branch' — that is the base branch"
    elif grep -qxF "$a_branch" <<<"$branches"; then
      FOUND_BRANCH="$a_branch"; ADOPT_BRANCH_SRC="adopt matcher"
      log "   adopting existing branch $a_branch (off-convention name)"
    else
      warn "adopt: ignoring '$a_branch' — no such branch; using the convention instead"
    fi
  fi

  if [[ -z "$FOUND_SPEC" && -n "$a_spec" && "$a_spec" != NONE ]]; then
    if [[ -f "$a_spec" ]]; then
      FOUND_SPEC="$a_spec"; ADOPT_SPEC_SRC="adopt matcher"
      log "   adopting existing spec $a_spec (off-convention name)"
    else
      warn "adopt: ignoring '$a_spec' — no such file; using the convention instead"
    fi
  fi
  return 0
}

resolve_context() {
  gh issue view "$ISSUE" --json number,title,body,labels,state,comments \
      > "$DIR/issue.json" 2>>"$LOG" || return 1
  TITLE=$(jq -r '.title' "$DIR/issue.json")
  STATE=$(jq -r '.state' "$DIR/issue.json")
  local labels; labels=$(jq -r '.labels[].name' "$DIR/issue.json" | tr '[:upper:]' '[:lower:]')
  SLUG=$(slugify "$TITLE")

  FOUND_BRANCH=$(find_issue_branch)
  FOUND_SPEC=$(find_issue_spec)
  ADOPT_BRANCH_SRC=""; ADOPT_SPEC_SRC=""

  # Provisional, so the matcher can be shown what the convention would produce.
  # The real precedence chain runs below, after it may have found something.
  infer_type_from_metadata "$labels"
  VERSION="${VERSION_FLAG:-$VERSION_SEGMENT}"

  if (( ADOPT_AGENT )) \
     && { [[ -z "$FOUND_BRANCH" && -z "$BRANCH_FLAG" ]] || [[ -z "$FOUND_SPEC" && -z "$SPEC_FLAG" ]]; }; then
    adopt_with_agent
  fi

  # Version and type come from what exists before they come from a guess.
  local b_ver b_type s_ver s_type
  b_ver=$(path_segment "${FOUND_BRANCH:-}" 1); b_type=$(path_segment "${FOUND_BRANCH:-}" 2)
  s_ver=$(path_segment "${FOUND_SPEC#specs/}" 1); s_type=$(path_segment "${FOUND_SPEC#specs/}" 2)

  if   [[ -n "$VERSION_FLAG" ]]; then VERSION="$VERSION_FLAG"; VERSION_SRC="--version"
  elif [[ -n "$b_ver" ]];        then VERSION="$b_ver";        VERSION_SRC="branch $FOUND_BRANCH"
  elif [[ -n "$s_ver" ]];        then VERSION="$s_ver";        VERSION_SRC="spec $FOUND_SPEC"
  else                                VERSION="$VERSION_SEGMENT"; VERSION_SRC="default"
  fi

  if   [[ -n "$TYPE_FLAG" ]]; then TYPE="$TYPE_FLAG"; TYPE_SRC="--type"
  elif [[ -n "$b_type" ]];    then TYPE="$b_type";    TYPE_SRC="branch $FOUND_BRANCH"
  elif [[ -n "$s_type" ]];    then TYPE="$s_type";    TYPE_SRC="spec $FOUND_SPEC"
  else TYPE="$M_TYPE";        TYPE_SRC="$M_TYPE_SRC"
       [[ "$M_TYPE_SRC" == DEFAULT* ]] \
         && warn "#$ISSUE: nothing determines the type; defaulting to $TYPE"
  fi

  BRANCH="${BRANCH_FLAG:-${FOUND_BRANCH:-${VERSION}/${TYPE}/${ISSUE}-${SLUG}}}"
  SPEC="${SPEC_FLAG:-${FOUND_SPEC:-specs/${VERSION}/${TYPE}/${ISSUE}-${SLUG}.md}}"
  return 0
}

# ── failure exit that keeps the work ──────────────────────────────────────
# A stage dying leaves the tree mid-edit. Throwing that away is worse than an
# ugly commit, so it becomes a WIP commit on a pushed branch and the run prints
# the exact command that picks up where it stopped.
bail() {
  local stage_name="$1" why="$2" code=5
  (( USAGE_LIMIT_HIT )) && code=4
  warn "#$ISSUE stopped at '$stage_name': $why"
  commit_leftovers "wip(#$ISSUE): $stage_name stopped mid-edit — see $RUN_DIR"
  if ! (( NO_PUSH )); then
    git push -u origin "$BRANCH" >>"$LOG" 2>&1 && log "   pushed $BRANCH so nothing is stranded"
  fi
  gh issue edit "$ISSUE" --add-label "$NEEDS_HUMAN_LABEL" >>"$LOG" 2>&1
  {
    echo
    echo "════════ #$ISSUE STOPPED ════════"
    echo "stage:  $stage_name — $why"
    echo "branch: $BRANCH  ($(git log --oneline -1 2>/dev/null))"
    echo "logs:   $RUN_DIR"
    report_cost
    echo
    if (( USAGE_LIMIT_HIT )); then
      echo "The account spend/usage limit stopped this, not the code. When it resets:"
    else
      echo "Read $RUN_DIR/$stage_name*.json first — then resume with:"
    fi
    echo "  ./scripts/${LOOP_SCRIPT} $ISSUE --from $stage_name"
  } | tee -a "$LOG"
  exit "$code"
}

# The spec stage has exactly two acceptable outcomes and one of them ends the
# run. Both signals are checked because either can be present alone: the skill
# writes `## BLOCKED` into the file and `SPEC_STATUS: BLOCKED` into its final
# message, and a stage that is skipped or crashes late leaves only the file.
spec_gate() {
  local msg="$1"
  touch "$msg"
  if grep -qE '^SPEC_STATUS:[[:space:]]*BLOCKED' "$msg" \
     || head -n 40 "$SPEC" | grep -q '^## BLOCKED'; then
    log "   ⏸ BLOCKED — the spec needs a decision only you can make:"
    sed -n '/^## BLOCKED/,/^## [^B]/p' "$SPEC" | head -40 | tee -a "$LOG"
    git add "$SPEC" >>"$LOG" 2>&1
    git commit -qm "spec(#$ISSUE): blocked — needs a decision" >>"$LOG" 2>&1
    (( NO_PUSH )) || git push -u origin "$BRANCH" >>"$LOG" 2>&1
    gh issue edit "$ISSUE" --add-label "$NEEDS_HUMAN_LABEL" >>"$LOG" 2>&1
    {
      echo
      echo "════════ #$ISSUE BLOCKED ════════"
      echo "spec:   $SPEC  (the ## BLOCKED section is at the top)"
      echo "branch: $BRANCH — pushed"
      echo "logs:   $RUN_DIR"
      report_cost
      echo
      echo "Answer it in the spec, commit, then:"
      echo "  ./scripts/${LOOP_SCRIPT} $ISSUE --from implement"
    } | tee -a "$LOG"
    exit 3
  fi
}

commit_spec() {
  git add "$SPEC" >>"$LOG" 2>&1
  git diff --cached --quiet -- "$SPEC" && return 0
  git commit -qm "spec(#$ISSUE): $1" >>"$LOG" 2>&1
  log "   committed $SPEC"
}

# ══════════════════════════════════════════════════════════════════════════
init_run "issue-$ISSUE"
DIR="$RUN_DIR/$ISSUE"; mkdir -p "$DIR"
log "${LOOP_CLI}-issue-loop #$ISSUE — stages: ${SELECTED[*]}"

if (( DRY_RUN )); then
  # No preflight: a dry run has to work on a dirty tree, because "what would
  # this do" is exactly the question you ask before cleaning up.
  command -v gh >/dev/null && gh auth status >/dev/null 2>&1 \
    || { warn "gh missing or not authenticated"; exit 2; }
fi

if ! (( DRY_RUN )); then
  preflight_common
  stage "smoke test (code)" "$CODE_MODEL" "$CODE_EFFORT" "Reply with the single word OK." \
    "$RUN_DIR/smoke-code.json" || { warn "CODE_MODEL '$CODE_MODEL' failed"; exit 2; }
  # PLAN_MODEL is not used until the spec stage, so a bad name here used to
  # surface a quarter of an hour into a run instead of in preflight.
  stage "smoke test (plan)" "$PLAN_MODEL" "$PLAN_EFFORT" "Reply with the single word OK." \
    "$RUN_DIR/smoke-plan.json" || { warn "PLAN_MODEL '$PLAN_MODEL' failed"; exit 2; }
  log "preflight OK"
fi

resolve_context || { warn "cannot read issue #$ISSUE"; exit 2; }
[[ "$STATE" == "OPEN" ]] || warn "#$ISSUE is $STATE, not OPEN — continuing anyway"
[[ "$BRANCH" != "$BASE_BRANCH" ]] \
  || { warn "refusing to run on $BASE_BRANCH itself"; exit 2; }

{
  echo "   issue:   #$ISSUE  $TITLE  [$STATE]"
  echo "   type:    $TYPE      (from $TYPE_SRC)"
  echo "   version: $VERSION   (from $VERSION_SRC)"
  echo "   branch:  $BRANCH    ${FOUND_BRANCH:+(exists${ADOPT_BRANCH_SRC:+, found by $ADOPT_BRANCH_SRC})}"
  echo "   spec:    $SPEC      ${FOUND_SPEC:+(exists, $(wc -l <"$FOUND_SPEC") lines${ADOPT_SPEC_SRC:+, found by $ADOPT_SPEC_SRC})}"
  echo "   base:    $BASE_BRANCH"
  echo "   models:  plan=$PLAN_MODEL/$PLAN_EFFORT  code=$CODE_MODEL/$CODE_EFFORT"
} | tee -a "$LOG"

if (( DRY_RUN )); then
  echo
  echo "dry run — nothing was changed. Stages that would run: ${SELECTED[*]}"
  if [[ -n "$FOUND_SPEC" ]] && (( ! FRESH_SPEC )); then
    echo "The spec stage would ITERATE on $FOUND_SPEC, not overwrite it."
  fi
  exit 0
fi

# ── sync: adopt or create the branch, then get it current ─────────────────
git fetch origin --prune >>"$LOG" 2>&1

CURRENT=$(git branch --show-current)
if [[ "$CURRENT" == "$BRANCH" ]]; then
  log "   already on $BRANCH"
elif git rev-parse --verify --quiet "$BRANCH" >/dev/null; then
  git checkout "$BRANCH" >>"$LOG" 2>&1 || { warn "cannot checkout $BRANCH"; exit 2; }
elif git rev-parse --verify --quiet "origin/$BRANCH" >/dev/null; then
  git checkout -b "$BRANCH" "origin/$BRANCH" >>"$LOG" 2>&1 \
    || { warn "cannot track origin/$BRANCH"; exit 2; }
else
  log "   creating $BRANCH from $BASE_BRANCH"
  git checkout "$BASE_BRANCH" >>"$LOG" 2>&1 || { warn "cannot checkout $BASE_BRANCH"; exit 2; }
  git pull --ff-only >>"$LOG" 2>&1
  git checkout -b "$BRANCH" >>"$LOG" 2>&1 || { warn "cannot create $BRANCH"; exit 2; }
fi

# Fast-forward to the remote if it moved. Divergence is a hard stop: resolving
# it means choosing which of two histories to keep, and nothing here knows which.
if git rev-parse --verify --quiet '@{u}' >/dev/null; then
  read -r BEHIND AHEAD < <(git rev-list --left-right --count '@{u}...HEAD')
  if (( BEHIND > 0 && AHEAD > 0 )); then
    warn "$BRANCH has diverged from its remote (${BEHIND} behind, ${AHEAD} ahead)."
    warn "  Reconcile it yourself — this script will not pick a side."
    exit 2
  fi
  (( BEHIND > 0 )) && { log "   fast-forwarding $BEHIND commit(s) from origin"; git pull --ff-only >>"$LOG" 2>&1; }
  (( AHEAD > 0 )) && log "   $AHEAD local commit(s) not yet pushed"
else
  log "   $BRANCH has no upstream yet"
fi

BASE_DRIFT=$(git rev-list --count "HEAD..origin/$BASE_BRANCH" 2>/dev/null || echo 0)
if (( BASE_DRIFT > 0 )); then
  if (( MERGE_BASE )); then
    log "   merging origin/$BASE_BRANCH ($BASE_DRIFT commits) into $BRANCH"
    git merge --no-edit "origin/$BASE_BRANCH" >>"$LOG" 2>&1 || {
      git merge --abort >>"$LOG" 2>&1
      warn "merging origin/$BASE_BRANCH conflicts — resolve it by hand, then rerun"; exit 2; }
  else
    warn "$BRANCH is $BASE_DRIFT commit(s) behind origin/$BASE_BRANCH (--merge-base to fold them in)"
  fi
fi
log "   head: $(git log --oneline -1)"

# ── 1. spec ───────────────────────────────────────────────────────────────
if want spec; then
  if [[ -s "$SPEC" ]] && (( ! FRESH_SPEC )); then
    log "   iterating on the existing spec at $SPEC"
    SPEC_PROMPT="$(cat <<EOF
/spec-from-issue ${ISSUE} ${SPEC}

## There is already a file at ${SPEC} — read it before anything else

Someone wrote it by hand. Treat it as the highest-authority precedent you have:
it outranks sibling specs and it outranks convention. Where it states a
decision, that decision is the user's and is not yours to re-open — carry every
one of them forward, in its own words wherever those words are already the
clearest statement of intent. If the code proves one of them impossible, say so
under Risks and constraints and, if it clears the skill's blocking bar, BLOCK. Do not
quietly substitute your own answer for one the user already gave.

Where the file is silent the skill applies unchanged: close the question from
CODE, PRECEDENT, or DERIVED, and log every DERIVED close.

Rewrite the file in place. What is in it now is INPUT, not output. When you are
done, ${SPEC} must satisfy the skill's output contract in full — Scope, Known
knowns, Implementation, Risks and constraints, Derived decisions, Deferred,
Slices. If
what is there is only a restatement of the issue, then none of those sections
exist yet and all of them are your job.

${RESOURCE_NOTE}
EOF
)"
  else
    log "   deriving a new spec at $SPEC"
    SPEC_PROMPT="$(cat <<EOF
/spec-from-issue ${ISSUE} ${SPEC}

${RESOURCE_NOTE}
EOF
)"
  fi

  stage "spec" "$PLAN_MODEL" "$PLAN_EFFORT" "$SPEC_PROMPT" "$DIR/spec.json" \
    || bail spec "the spec stage failed"
  [[ -s "$SPEC" ]] || bail spec "no spec was written to $SPEC"
  jq -r '.result' "$DIR/spec.json" > "$DIR/spec-msg.txt" 2>/dev/null
  spec_gate "$DIR/spec-msg.txt"
  commit_spec "$TITLE"
fi

# ── 2. spec-review ────────────────────────────────────────────────────────
# The skill this replaces (/review-spec) is an interview: it pauses after each
# section and asks the user questions. In an unattended run that is not a slow run,
# it is a dead one — so the critique is inlined here with the interview removed
# and the same standards kept.
if want spec-review && (( SPEC_REVIEW_ROUNDS > 0 )); then
  [[ -s "$SPEC" ]] || bail spec-review "no spec at $SPEC to review (run the spec stage first)"
  for r in $(seq 1 "$SPEC_REVIEW_ROUNDS"); do
    stage "spec-review r$r" "$PLAN_MODEL" "$PLAN_EFFORT" "$(cat <<EOF

Read the spec at ${SPEC}. Then re-read the issue it implements:
  gh issue view ${ISSUE} --json title,body,comments

Critique the spec against the actual code and sharpen it in place. Read the
files it names — a critique written from the spec alone catches nothing that
writing the spec did not already catch.

**You are not interviewing anyone.** Never ask a question, never use
AskUserQuestion, never end your turn asking whether to proceed. No one is
reading. Where an interactive reviewer would ask, you decide, and you log the
decision in **Derived decisions** with how to reverse it — or, if it clears the
blocking bar (user-facing behaviour neither the issue nor precedent specifies;
expensive to reverse; two readings that produce different acceptance tests),
you BLOCK.

Judge it on:
- **Boundaries** — component boundaries, coupling, and anything that prevents a
  reviewer from evaluating a slice on its own.
- **DRY** — flag repetition aggressively, including repetition with code that
  already exists in the repo but the spec does not mention.
- **Error handling and tracing** — every new failure path, and whether it uses
  the logging and error types the codebase already has rather than new ones.
- **Test intent** — this is essential. /implement-spec turns each
  slice's acceptance criteria into failing tests BEFORE any code exists. For
  each criterion ask: could a test be written from this sentence, and would it
  fail if the behaviour were wrong? If not, rewrite it until it would.
- **Edge cases** — prefer more handled, not fewer. Add missing ones to the
  relevant slice's criteria, not to a new section.
- **Engineered enough** — neither fragile/hacky nor prematurely abstract.
- **Scope** — anything not in issue #${ISSUE} belongs in **Deferred**, never in
  a slice. Adding scope in a review pass is the most expensive mistake here.
- **Slicing** — each slice one reviewable commit, cut at API/module boundaries,
  with its dependencies stated so independent ones can run in parallel. Do not
  manufacture slices for work that is genuinely one commit.

Route every finding into the structure /implement-spec reads, do not orphan it
in prose, and do not delete or malform the contract sections (Scope, Known
knowns, Implementation, Risks and constraints, Derived decisions, Deferred,
Slices).

Apply your edits to ${SPEC} yourself, surgically. Do not rewrite sections you
have no finding about. If your honest conclusion is that the spec is already
right, say so and change nothing — a review pass that edits for the sake of
editing makes the spec worse.

${RESOURCE_NOTE}

End your final message with SPEC_STATUS: READY, or SPEC_STATUS: BLOCKED if you
blocked (in which case ## BLOCKED must be the first section of ${SPEC}).
EOF
)" "$DIR/spec-review-$r.json" || bail spec-review "spec review round $r failed"
    jq -r '.result' "$DIR/spec-review-$r.json" > "$DIR/spec-review-$r.md" 2>/dev/null
    spec_gate "$DIR/spec-review-$r.md"
    commit_spec "review round $r"
  done
fi

if want spec || want spec-review; then
  grep -q '^## Derived decisions' "$SPEC" \
    || warn "#$ISSUE: the spec has no 'Derived decisions' section — review this branch harder"
fi

# ── 3. implement ──────────────────────────────────────────────────────────
if want implement; then
  [[ -s "$SPEC" ]] || bail implement "no spec at $SPEC"
  stage "implement" "$CODE_MODEL" "$CODE_EFFORT" "$(cat <<EOF
/implement-spec $SPEC

${RESOURCE_NOTE}
EOF
)" "$DIR/impl.json" || bail implement "the implement stage failed"
fi

# ── 4. techdebt ───────────────────────────────────────────────────────────
if want techdebt; then
  stage "techdebt" "$CODE_MODEL" "$CODE_EFFORT" "$(cat <<EOF
/techdebt

Scope: the whole branch since ${BASE_BRANCH} — \`git diff origin/${BASE_BRANCH}...HEAD\`.

${RESOURCE_NOTE}
EOF
)" "$DIR/debt.json" || bail techdebt "the techdebt stage failed"
fi

commit_leftovers "chore(#$ISSUE): stage leftovers"

# ── 5. review ⇄ fix ───────────────────────────────────────────────────────
BLOCKING=0
REVIEWED=0
if want review; then
  REVIEWED=1
  review_fix_cycle "$ISSUE" "$DIR" "$SPEC" "$BASE_BRANCH"
  if (( BLOCKING == 0 )); then
    gh issue edit "$ISSUE" --remove-label "$NEEDS_HUMAN_LABEL" >>"$LOG" 2>&1 \
      && log "   cleared $NEEDS_HUMAN_LABEL on issue #$ISSUE"
  else
    gh issue edit "$ISSUE" --add-label "$NEEDS_HUMAN_LABEL" >>"$LOG" 2>&1
    if (( BLOCKING > 0 )); then
      warn "#$ISSUE: $BLOCKING blocking finding(s) survive $MAX_REVIEW_ROUNDS fix round(s)"
    else
      warn "#$ISSUE: the review could not complete — the branch is UNVERIFIED, not necessarily wrong"
    fi
  fi
  (( USAGE_LIMIT_HIT )) && warn "account limit reached during review"
fi

# ── 6. context ────────────────────────────────────────────────────────────
# Do not document or publish a branch whose review is incomplete. A resumed
# `--from review` run will review the fixes, update context, and then open the PR.
if want context && ! (( USAGE_LIMIT_HIT )) && (( BLOCKING == 0 )); then
  run_update_context "$ISSUE" "$DIR" "$SPEC" \
    || bail context "the context update stage failed"
fi

# Capture context edits before PR generation so the published diff and
# description include the final documentation.
commit_leftovers "chore(#$ISSUE): final leftovers"

# ── 7. PR ─────────────────────────────────────────────────────────────────
PR_NUM=""; PR_URL=""; BRANCH_PUSHED=0
if want pr && ! (( USAGE_LIMIT_HIT )) && (( BLOCKING == 0 )); then
  if want implement && \
     [[ -z "$(git diff --name-only "origin/$BASE_BRANCH...HEAD" -- . ":!$SPEC")" ]]; then
    bail pr "no implementation landed — the branch is only the spec"
  fi
  git push -u origin "$BRANCH" >>"$LOG" 2>&1 || bail pr "push failed"
  BRANCH_PUSHED=1

  if ! stage "pr-body" "$CODE_MODEL" "$CODE_EFFORT" "$(cat <<EOF
/clear-technical-writing

Write a pull request description for branch ${BRANCH} against ${BASE_BRANCH},
implementing issue #${ISSUE}, spec at ${SPEC}. Base it on the actual diff
(git diff origin/${BASE_BRANCH}...${BRANCH}) and on the spec.

Write it to ${DIR}/pr.md. The FIRST LINE of that file is the PR title and
nothing else — no markdown heading, no prefix. Everything after line 1 is the
body. Do not write a "Closes" line; that is appended automatically.

Reproduce the spec's "Derived decisions" table under the heading
"## Decided without human input — check these". This is the section the
reviewer reads first. Also list the spec's Deferred items under "## Deferred".

Say plainly what a reviewer cannot verify from CI — anything that needs a
machine, an OS, or hardware this run did not have.
EOF
)" "$DIR/prbody.json"; then
    (( USAGE_LIMIT_HIT )) && bail pr "account limit reached while writing the PR description"
    warn "pr-body stage failed — falling back to a minimal PR"
  fi

  if [[ -s "$DIR/pr.md" ]]; then
    PR_TITLE=$(head -n1 "$DIR/pr.md")
    tail -n +2 "$DIR/pr.md" > "$DIR/pr-body.md"
  else
    PR_TITLE="$TYPE(#$ISSUE): $TITLE"
    printf 'Implements issue #%s. Spec: `%s`\n' "$ISSUE" "$SPEC" > "$DIR/pr-body.md"
  fi
  printf '\n\nCloses #%s\n' "$ISSUE" >> "$DIR/pr-body.md"

  # Idempotent: a resumed run lands here with the PR already open, and
  # `gh pr create` errors rather than no-opping in that case.
  if PR_NUM=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null) && [[ -n "$PR_NUM" ]]; then
    log "   PR #$PR_NUM already open for $BRANCH — reusing it"
  else
    gh pr create --base "$BASE_BRANCH" --head "$BRANCH" \
      --title "$PR_TITLE" --body-file "$DIR/pr-body.md" >>"$LOG" 2>&1 \
      || bail pr "gh pr create failed"
  fi

  # Re-read rather than trust: `gh pr create` does not hand back the number.
  PR_NUM=$(gh pr view "$BRANCH" --json number -q .number 2>/dev/null)
  [[ -n "$PR_NUM" ]] || bail pr "the PR was opened but its number could not be resolved"
  PR_URL=$(gh pr view "$BRANCH" --json url -q .url 2>/dev/null)
  log "   PR #$PR_NUM: $PR_URL"
fi

# Keep a recoverable remote branch even when review findings prevented the PR.
# `--no-push` is the explicit local-only exception.
if ! (( NO_PUSH || BRANCH_PUSHED )); then
  if git push -u origin "$BRANCH" >>"$LOG" 2>&1; then
    BRANCH_PUSHED=1
    log "   pushed $BRANCH for recovery"
  else
    warn "could not push $BRANCH — the latest branch state remains local"
  fi
fi

# ── summary ───────────────────────────────────────────────────────────────
# Deliberately no `return_to_base`: this run produced one branch and you are
# almost certainly about to look at it. Leaving you on it also keeps the
# `git clean -fd` inside reset_tree away from a tree it has no reason to touch.
{
  echo
  echo "════════ #$ISSUE complete ════════"
  echo "$TITLE"
  echo
  echo "branch: $BRANCH  ($(git log --oneline -1))"
  if (( NO_PUSH )); then
    echo "remote: not pushed (--no-push)"
  elif (( BRANCH_PUSHED )); then
    echo "remote: pushed to origin"
  else
    echo "remote: push failed; the latest branch state may exist only locally"
  fi
  echo "spec:   $SPEC"
  [[ -n "$PR_URL" ]] && echo "PR:     $PR_URL"
  echo "stages: ${SELECTED[*]}"
  report_cost
  echo "logs:   $RUN_DIR"
  echo
  if (( USAGE_LIMIT_HIT )); then
    echo "STOPPED EARLY — account spend/usage limit. Resume once it resets:"
    echo "  ./scripts/${LOOP_SCRIPT} $ISSUE --from review"
  elif (( ! REVIEWED )); then
    echo "No review ran. Nothing here has been checked by anything but the tests."
  elif (( BLOCKING > 0 )); then
    echo "NEEDS YOU — $BLOCKING blocking finding(s) remain, verified against the"
    echo "current diff. They are written out in full at:"
    echo "  $DIR/review-verify.md   (or review-$MAX_REVIEW_ROUNDS.md)"
    echo "Fix them on this branch, then resume with:"
    echo "  ./scripts/${LOOP_SCRIPT} $ISSUE --from review"
  elif (( BLOCKING < 0 )); then
    echo "UNVERIFIED — the review never returned a verdict. Read $DIR/review-*.md."
    echo "Resolve the review failure, then resume with:"
    echo "  ./scripts/${LOOP_SCRIPT} $ISSUE --from review"
  elif [[ -z "$PR_URL" ]]; then
    echo "Review came back clean. No PR was opened because the pr stage was not selected."
  else
    echo "Review came back clean. Read the PR's 'Decided without human input'"
    echo "section first — that is where an unattended run hides its guesses."
  fi
  echo
  echo "Nothing was merged."
} | tee -a "$LOG"

(( USAGE_LIMIT_HIT )) && exit 4
(( BLOCKING != 0 )) && exit 3
exit 0
