# Agent Skills & Loops

This repository contains a set of agent skills I use to engineer software with AI coding tools like Claude Code and Codex. They can be installed and used with any agentic harness that supports the agentskills.io standard.

It also contains scripts for loop engineering -- scripts that automate the workflow of prompting the coding agents and starting new sessions that build off of past ones. You need to be careful with such loops because they can eat up tokens and usage credits. When writing your engineering specs for a loop, it's **VERY IMPORTANT** that you define the scope of your task (and work out of scope), acceptance criteria, and testing approach/cases. Agents need end-to-end verifiable goals so they know when to stop. You don't want to ever over-spend tokens or come back to an agent loop that entered schizophrenia mode on your codebase.

These skills and loops are all embracing the paradigm of spec-based, test-driven development. Based off a GitHub issue (or equivalent engineering ticket from a project management tool e.g. Jira, Linear, or GH Projects), there are skills for planning a detailed implementation spec, reviewing the spec, and implementing the spec by writing code tests first, and then implementing the code to pass the tests. 
Spec-based engineering is best for tasks that can be split into chunks/slices and have verifiable end-states. These skills or loops may not be useful for ad-hoc UI iterations, small bugfixes that don't need testing, documentation updates, etc. It's moreso for features and fixes that can be planned out with specs and have their code verified and tested. 

For the engineering loops, human-in-the-loop requirements are stripped away so that decisions are delegated to the AI model. So, rather than planning out an implementation spec based on a GH issue with the human, the model will just plan the spec for itself, based on that same GH issue, then pass on that spec to the next agentic coding session.

It's *highly recommended* to use the human-in-the-loop path rather than the automated loop path for **big features** that significantly impact your architecture or system design. Design decisions are always best instilled from the human, or else your codebase will drift from what you expect it to be. 

## Installing the skills

The skills stand on their own. The loop scripts are optional — the human-in-the-loop path below is nothing but these skills, run by hand, one session each.

```bash
git clone https://github.com/GioZaarour/agentic-engineering-skills.git
cd agentic-engineering-skills
./install.sh
```

`install.sh` symlinks every directory under `skills/` into both `~/.claude/skills/` (Claude Code) and `~/.agents/skills/` (Codex and anything else following the agentskills.io layout). Because they are symlinks and not copies, `git pull` in this repo updates the installed skills — nothing to re-run. Anything already sitting at one of those paths that is *not* a symlink is skipped rather than overwritten, so it will not eat a skill of yours that happens to share a name.

They install globally, for every project on the machine. To scope them to one repo instead, symlink (or copy) just the ones you want into that repo's `.claude/skills/`:

```bash
ln -s ~/path/to/agentic-engineering-skills/skills/implement-spec .claude/skills/implement-spec
```

Then invoke them by name in a session — `/spec-planning`, `/review-spec`, `/implement-spec`, `/techdebt`, `/branch-review`, `/pr-review`, `/update-context`, `/document-code`, `/spec-from-issue`, `/clear-technical-writing`. A session that was already open when you installed them won't see them; start a new one.

`/clear-technical-writing` is a shared writing layer for human-facing engineering text. The spec, code-documentation, branch-review, PR-review, and context-update skills invoke it automatically. You can also invoke it directly for PR descriptions, review comments, repository documentation, and engineering reports.

## Assumed Conventions

Parts of these skills and scripts assume conventions, which come from my own habits. You can change them however you want to fit your own liking. Here they are:

- Branch naming: I name branches like `[version]/[gitflow-category]/[Issue#]-[name]`. Example: `v0/feature/56-chatbot-conversation-history`. You can change those assumptions in the skills/scripts.
- Issues and PRs: The skills assume you're use GitHub to track issues, making PRs to close those issues (linking them together through PR descriptions such as "Closes #56"), and merging directly to `main`.
- Specs: The skills assume a `./specs` folder in the codebase, where it would write/read from specs with a matching naming convention to branch naming (e.g. `specs/v0/feature/56-chatbot-conversation-history.md`)
- CI/CD: The skills/scripts assume nothing about any existing CI/CD *or* deployment environments. You can add changes on your own, if you have them.
- Git and GH CLI: The scripts assume you have GH CLI and git installed, and that you use git at all (some people use Codeberg etc.)
- AGENTS.md: Assume you have one AGENTS.md file at the repo root, with all relevant context. You might need to symlink CLAUDE.md to this file, or change the convention to your own preference.
- Loop artifacts: the loop scripts write every run's logs and raw model output to `.loops/` in your repo, and add that one line to `.git/info/exclude` the first time they run.

## Instructions

First, start off by describing your task/issue to the maximum degree of detail and explainability. Try to leave no unknowns. You can structure it as a GitHub issue with sections like Description, Acceptance Criteria, Implementation Approach, and Testing Approach.

**Write down everything you have in your head about the engineering task. Leave no stone unturned. AI needs your context**

### Human-in-the-loop path

- Write spec/descriptive engineering ticket
- Plan/interview (`/spec-planning` with strong model like `Fable 5` or `GPT 5.6 Sol`)
- Review the plan (`/review-spec` in a separate session with strong model)
- Do the test-driven development (`/implement-spec` with a strong coding model like `Opus 5 xhigh`. You can also use a weaker model for simpler coding features. )
- QA/testing: Manually test feature and run tests. Iterate on any bugs, if need be.
- Run `/techdebt` to clean up code in the current branch diff from `main` (separate session, Opus or Sonnet-grade model)
- Run `/branch-review` (separate session, with strong model) then iterate on requested changes if needed
- `/update-context` to keep `AGENTS.md` and `README.md` up-to-date (in the main session, with cheaper model)
- Make a PR — generate the description from the main implementation session and use `/clear-technical-writing`, or write it yourself

`/pr-review` remains available for one-off reviews of existing pull requests, including pull requests opened by other contributors.

### Loop Engineering path

`scripts/claude-issue-loop.sh` and `scripts/codex-issue-loop.sh` each take **one** GitHub issue from "open" to "PR under review", unattended. It is the same path as above with the human taken out: every step is a skill you can run by hand, and the script's only job is to run them in order, in separate processes, and to stop in a recoverable way when something needs you.

```
preflight → resolve → sync → spec → spec-review → implement → techdebt → review ⇄ fix → context → pr
```

Both entrypoints share the workflow in `claude-issue-loop.sh` and the runner in `loops-lib.sh`. Each stage is its own `claude -p` or `codex exec` process with a clean context window. State moves between them through git and files on disk, never through a shared context — so a stage that goes wrong is bounded, and any stage can be re-run on its own.

| Stage | What runs | Model |
|---|---|---|
| `spec` | `/spec-from-issue` — derives the spec, or iterates on one that already exists | `PLAN_MODEL` (high) |
| `spec-review` | a non-interactive critique of the spec against the actual code | `PLAN_MODEL` (high) |
| `implement` | `/implement-spec` — test-first, slice by slice | `CODE_MODEL` (medium) |
| `techdebt` | `/techdebt` over the whole branch diff | `CODE_MODEL` (medium) |
| `review` | `/branch-review` ⇄ fix against the local branch, up to `MAX_REVIEW_ROUNDS`, ending on a review so the count is honest | `PLAN_MODEL` (high) / `CODE_MODEL` (medium) |
| `context` | `/update-context` against the local branch diff | `CODE_MODEL` (medium) |
| `pr` | pushes the finished branch, writes a PR description from the final diff and the spec, and opens the PR | `CODE_MODEL` (medium) |

The default loop does not open a pull request until the branch review is clean and the context update succeeds. If either step needs a human, the loop can push the branch for recovery, but it stops before creating the pull request.

The `spec-review` stage does not call `/review-spec`. That skill is an interview — it stops and asks you things — and in an unattended CLI process an interview is not a slow run, it is a dead one. The critique is inlined in the script with the questions removed and the standards kept.

#### Setup

1. Install the skills — `./install.sh`, as above. The loop calls `/spec-from-issue`, `/implement-spec`, `/techdebt`, `/branch-review`, and `/update-context`. Those skills and the inline PR-writing stages use `/clear-technical-writing` for human-facing text. Preflight checks for all six skills and warns (it does not block) if it cannot find one, so a missing skill shows up in the first ten seconds instead of an hour into a run.
2. Copy `scripts/claude-issue-loop.sh`, `scripts/codex-issue-loop.sh`, `scripts/loops-lib.sh`, and `scripts/loops` into your own repo, under `scripts/`. They must sit next to each other. Committing them to your repo is the simplest thing to do; if you would rather keep them untracked, add all four paths to `.git/info/exclude` — **not** `.gitignore`. `.gitignore` is tracked and therefore branch-scoped, so a rule you add on `main` does not exist on the feature branch the loop is about to `git add -A` on. Preflight refuses to start unless one of the two is true.
3. On your PATH: `claude` or `codex` for your chosen entrypoint, plus `gh`, `jq`, `git`, and bash **4.2 or newer**. macOS ships bash 3.2 as `/bin/bash` — `brew install bash` and make sure it comes first, or the scripts will die on a syntax error. macOS also has no `timeout`; `brew install coreutils` gives you `gtimeout`, which the scripts find on their own. Without it a wedged stage hangs forever instead of being killed at `STAGE_TIMEOUT`.
4. Run `gh auth login` and either `claude auth login` or `codex login` on the machine that will run the loop. Codex uses its existing CLI login and checks it with `codex login status`.
5. Optional but worth ten minutes: copy `scripts/loop-notes.example.md` to `.loop-notes.md` at your repo root and rewrite it for your project — how to build, how to run tests, which suites cannot run on this host, which toolchain is not on PATH. Every stage gets that text appended to its prompt. Without it, each stage works your build and test commands out from the repo, over and over, and sometimes gets them wrong.
6. Start from a **clean working tree**. Preflight refuses to run dirty, and refuses to run with a git worktree nested inside the checkout. Sibling worktrees, such as other loops running in parallel, are fine. Which branch you are standing on does not matter — it checks out the issue's branch, or creates it from `BASE_BRANCH`; the one thing it will not do is resolve the issue's branch *to* the base branch and commit there.

#### First run: always dry-run first

The examples use Claude. Substitute `codex-issue-loop.sh` for `claude-issue-loop.sh` to use Codex; all flags and stages are identical. Codex prompts invoke the same installed skills with `$skill-name`.

```bash
./scripts/claude-issue-loop.sh <issue-number> --dry-run
```

This resolves the issue, works out the branch, spec path and type, prints the plan, and changes nothing — no commits, no pushes, no comments. Read it before anything real, especially to check whether it correctly found an **existing** branch and spec instead of planning to create new ones. Add `--no-adopt` if you want the dry run to be strictly free: without it, when no branch or spec matches the naming convention, one read-only model call goes looking for one under a different name.

#### The real run

```bash
./scripts/claude-issue-loop.sh <issue-number>
```

It runs in the foreground and can take hours. For anything real, detach it — tmux is strongly recommended, and non-optional on a VPS or a cloud container, where a dropped terminal otherwise kills the loop mid-edit:

```bash
tmux new -d -s issue<N> './scripts/claude-issue-loop.sh <N>'
tmux attach -t issue<N>     # watch it live; Ctrl-b d to detach again
```

> [!WARNING]
> **This is not a sandbox.** Claude stages run with `--permission-mode bypassPermissions`; Codex stages use `--sandbox danger-full-access` and `approval_policy="never"`, which means no tool call will ever stop and ask you. The loop will push branches, open real PRs, label the real issue, and — in the fix rounds — file or comment on real techdebt issues in your repo. It does not merge anything, and that is the only thing it will not do. Once the dry run looks right, treat the issue number you pass it as a commitment. Run it on a machine and a repo where an agent acting on its own for a few hours is acceptable.

#### Watching it run

```bash
tail -f .loops/latest/run.log
```

`.loops/latest` is a symlink to the current run's directory (`.loops/<timestamp>-issue-<N>/`). The log carries a timestamped line per stage transition and every warning. For a stage's full output rather than its log line, read the per-issue subdirectory `.loops/latest/<N>/`:

| File | What it is |
|---|---|
| `issue.json` | the issue as `gh` returned it |
| `adopt.json` / `adopt.md` | the off-convention branch/spec matcher's answer |
| `spec.json` | the `spec-from-issue` stage's raw output |
| `spec-review-1.json` / `.md` | spec critique round 1 |
| `impl.json` | the implement stage |
| `debt.json` | the techdebt stage |
| `review-1.md`, `fix-1.json` | review round 1 and the fix that answered it |
| `review-verify.md` | the final verification review, when one ran |
| `ctx.json` | the `update-context` stage |
| `pr.md` | PR title (line 1) + body |

Claude `.json` files are raw `claude -p --output-format json` results. Codex results are normalized to the same `.result` and `.is_error` fields, with `.usage` for token counts and `.session_id` for the thread ID. Codex also keeps each stage's `.events.jsonl`, `.last.txt`, and `.stderr.log` files. See the [Codex non-interactive documentation](https://developers.openai.com/codex/noninteractive/) for the event format. The `.md` files contain the extracted review text.

Claude cost so far, without waiting for the run to finish (Codex does not report dollar costs):

```bash
jq -s 'map(.total_cost_usd // 0) | add' .loops/latest/*.json .loops/latest/*/*.json
```

#### Stopping it

`pkill -f 'issue-loop.sh'` matches its own invocation, so use:

```bash
pkill -f 'issue-[l]oop'      # or just kill the tmux session
```

Killing it mid-stage leaves the tree mid-edit. That is safe to resume from (below), but it is **not** safe to re-run from scratch on top of — check `git status` first.

#### When it stops

The exit code determines how you resume the run:

| Exit | Meaning | What to do |
|---|---|---|
| `0` | Done; the review came back clean — or no review stage was selected, in which case the summary says so in as many words | Read the PR if one was opened, starting with the "Decided without human input" section |
| `2` | Preflight or usage error; nothing was touched | Fix what it reported and run again |
| `3` | Needs a human: the spec `BLOCKED`, or findings survived the fix rounds (or the review never returned a verdict) | Read the file it names — `.loops/latest/<N>/review-verify.md`, or the spec's `## BLOCKED` section — resolve it, then resume |
| `4` | Hit an account spend/usage limit mid-run | The branch is pushed and safe to leave; resume once the limit resets |
| `5` | A stage failed outright, git refused to commit a stage's edits (for example, a pre-commit hook rejected them), or a push failed | Normally the branch is pushed as a WIP commit and the summary names the exact resume command. If the summary reports a refused commit, the edits are still uncommitted in the worktree; if it reports a failed push, the latest commits exist only locally. Commit or push them by hand before you resume |

Every stop prints a summary block with the resume command already filled in, e.g.:

```bash
./scripts/claude-issue-loop.sh 19 --from implement
```

`--from <stage>` re-runs that stage and everything after it, reusing whatever branch and spec already exist instead of starting over. Stages: `spec`, `spec-review`, `implement`, `techdebt`, `review`, `context`, `pr`.

Whenever it stops in a way that needs you — a blocked spec, a failed stage, an exhausted account, or unresolved review findings — the issue is labelled `needs-human`. A clean branch review clears it again. Both that label and the `techdebt` label are created in your repo on the first run if they don't exist, because `gh --add-label` on a missing label is a silent no-op, and a silent no-op here is exactly the signal you'd be looking for.

#### Flags worth knowing

| Flag | Effect |
|---|---|
| `--dry-run` | Resolve everything, print the plan, change nothing. Always first. |
| `--from <stage>` | Run this stage and every stage after it |
| `--stages a,b,c` / `--skip a,b` | Run exactly these / drop these |
| `--fresh-spec` | Re-derive the spec instead of iterating on the existing one |
| `--spec-rounds N` | Spec critique passes after derivation (default 1, `0` = off) |
| `--no-push` | Never push and never open a PR (implies skipping only `pr`); review and context updates still run locally |
| `--type <t>` / `--version <v>` / `--branch <name>` / `--spec <path>` / `--base <branch>` | Override the inference when it guesses wrong — check the `--dry-run` output first |
| `--merge-base` | Merge `origin/<base>` into the branch if it has fallen behind |
| `--no-adopt` | Skip the off-convention matcher; if the naming convention was not followed, just create the conventional branch and spec |

#### Configuration

Everything is an environment variable with a sane default; there is no config file. The ones people actually change:

| Variable | Default | What it does |
|---|---|---|
| `PLAN_MODEL` | Claude: `claude-opus-5-5`; Codex: `gpt-6-sol` | Spec derivation, spec review, branch review |
| `CODE_MODEL` | Claude: `claude-opus-5-5`; Codex: `gpt-6-sol` | Implementation, techdebt, fixes, context |
| `PLAN_EFFORT` / `CODE_EFFORT` | `high` / `medium` | Planning and review effort / implementation, fixes, cleanup, context, and PR-writing effort |
| `ADOPT_MODEL` / `ADOPT_EFFORT` | Claude: `claude-haiku-4-5-20251001` / unset; Codex: `gpt-6-luna` / `medium` | Read-only fallback for branches and specs with unconventional names. Haiku does not support the effort flag. |
| `LOOP_AUTH` | `subscription` | Claude only: which credentials every stage bills to. `subscription` unsets `ANTHROPIC_API_KEY`/`ANTHROPIC_AUTH_TOKEN` for the run, because `claude` prefers an exported key over your claude.ai login, and preflight then stops the run unless `claude auth status` reports subscription billing. That catches an `apiKeyHelper`, a Console login, and no login at all. Set `api-key` to bill the API key instead. |
| `BASE_BRANCH` | `main` | What the PR targets, and what new branches are cut from. Set it to an unmerged branch to stack work on top of it. |
| `VERSION_SEGMENT` | `v0` | The first path segment in branch and spec names |
| `DEFAULT_TYPE` | `bugfix` | Used when labels and the title say nothing |
| `BUGFIX_LABELS` / `FEATURE_LABELS` | see script | Regexes over your `gh label list` |
| `MAX_REVIEW_ROUNDS` | `2` | Review ⇄ fix rounds before it gives up and asks for a human |
| `STAGE_TIMEOUT` | `14400` | Seconds per stage; a wedge detector, not a pace target |
| `MB_PER_JOB` | `2048` | RAM per build job — raise it for a heavy C++ toolchain, lower it for a light one |
| `SUBAGENT_CAP_OVERRIDE` | measured | Concurrent subagents a stage may fan out to |
| `STAGE_BUDGET_USD` / `TOTAL_BUDGET_USD` | `0` (off) | Cost ceilings, in dollars: per stage (passed to `claude` as `--max-budget-usd`) and per run (checked between stages, so a stage is never killed mid-edit — the run stops recoverably at exit `5`). Claude only. Codex rejects nonzero ceilings because it cannot enforce or report dollar costs. |
| `PERMISSION_MODE` | `bypassPermissions` | Claude only. Codex uses `danger-full-access` with approvals disabled, except the adoption matcher, which uses `read-only`. |
| `RUN_ROOT` | `.loops` | Where run artifacts go |

The machine budget is **measured, not assumed**: cores, RAM, swap and free disk are read at startup, and the subagent cap, the build parallelism and whether worktrees are allowed are derived from them and injected into every prompt. The same script yields `-j1` and one subagent on a 4 GB VPS and more on a 32 GB workstation, with no edit.

#### What it decides without you

This is the part to be deliberate about. With no human in the loop, `/spec-from-issue` closes every open question from **code**, **precedent**, or — where neither answers and the decision is cheap to reverse — **derives** it and logs it. Anything expensive or product-facing is a hard `BLOCK`: the spec's first section becomes `## BLOCKED`, the run stops at exit `3`, and nothing is implemented.

So the PR description's **"Decided without human input"** section is not boilerplate. It is the complete list of places where the loop made your call for you. Read it first, every time. If the list is long, or the spec has no `Derived decisions` section at all (the script warns when it doesn't), that is the signal the issue was underspecified — which is a problem with the issue, not the loop.

Two more places the loop guesses, both of which the `--dry-run` shows you: the **type** (from labels, then the title, then `DEFAULT_TYPE`) and, when nothing matching the issue number exists, whether an off-convention branch or spec is really this issue's. The matcher for that second one is a model with read-only tools or a read-only sandbox, it may only return a name that is already on the list it was given, and the shell re-checks the answer against git and the filesystem before using it — a hallucinated branch name is discarded, not checked out.

### Running loops in parallel

`scripts/loops` runs several issue loops at the same time on one machine. It uses the invoking checkout when its branch name contains the issue number as a path segment prefix, such as `v1/bugfix/19-fix-race`; otherwise it uses a dedicated worktree for that issue. Each run gets its own tmux session, and the command reports the state of every loop run in the repository.

The loops do not coordinate with each other. Choose issues that change separate parts of the codebase. Two loops that edit the same files each produce a PR, and those PRs conflict.

#### Requirements

- Complete the loop [Setup](#setup) first. The parallel command uses the same scripts, logins, and skills.
- Copy `scripts/loops` next to the other three scripts.
- Install tmux 3.2 or newer and git 2.31 or newer. The launcher checks the tmux version before starting any runs.

#### Start loops

```bash
./scripts/loops run 19 21 24                 # three Claude loops
./scripts/loops run --cli codex 27           # one Codex loop
PLAN_MODEL=claude-fable-5-1 ./scripts/loops run 30 31   # settings apply to every loop
./scripts/loops run 19 -- --merge-base       # arguments after -- go to every loop
```

For each issue number, `loops run` does the following:

1. It names the tmux session `<repo>-<N>`, for example `myapp-19`. If a session with that name exists, it skips the issue and prints the `tmux attach` command.
2. It checks the branch in the invoking checkout. If it matches the issue number, the loop runs there. Otherwise it uses `../<repo>-loops/issue-<N>`, reusing that dedicated worktree if it exists or creating it detached at `origin/<BASE_BRANCH>`. Earlier status records do not select a checkout. Set `LOOPS_WORKTREE_ROOT` to put dedicated worktrees somewhere else.
3. It starts `<cli>-issue-loop.sh <N>` in the new session, inside the selected checkout. The loop then creates or adopts the issue's branch, exactly as a single run does.

Some details affect how you call it:

- `--cli` and the arguments after `--` apply to every issue in the command. To give issues different flags or different CLIs, run `loops run` once for each group.
- `loops run` starts the loop scripts from the directory that contains `scripts/loops`, not from the worktree's copy. So untracked scripts work, and every loop runs the same version of the scripts.
- A new tmux session receives the tmux server's environment, not your shell's. `loops run` therefore forwards `PATH` and each loop setting from [Configuration](#configuration) that is set in your shell.
- Always do a dry run of a new issue first, as described in [First run](#first-run-always-dry-run-first). `loops run 19 -- --dry-run` works, but its output disappears when the session exits.

#### Check progress

```bash
./scripts/loops status         # the latest run of each issue
./scripts/loops status --all   # every recorded run, oldest first
```

The command works from the main checkout and from any worktree:

```
ISSUE  CLI     STAGE        STATE        COMMITS  UPDATED  NEXT
#19    claude  review       limit        7        2h       ./scripts/loops run 19 -- --from review
       ↳ account usage limit · /…/myapp-loops/issue-19/.loops/20260928-101500-issue-19/run.log
#21    claude  implement    running      3        4m       tmux attach -t myapp-21
#24    codex   pr           done         11       40m      https://github.com/…/pull/88
#27    codex   techdebt     died         5        3h       ./scripts/loops run --cli codex 27 -- --from techdebt
       ↳ the process exited without recording an outcome · /…/run.log
```

| Column | Meaning |
|---|---|
| `STAGE` | The last stage the loop started. Before the issue's stages, this is `preflight` or `sync`. |
| `STATE` | The outcome. See the next table. |
| `COMMITS` | The number of commits on the issue's branch that are not on `origin/<base>`. It is counted when you run `status`, not read from the record. |
| `UPDATED` | Time since the loop last wrote its record. |
| `NEXT` | The command to run next: attach to a running session, open the PR, or resume. A loop that stopped also gets a second line with the reason and its log path. |

| State | Meaning | Next action |
|---|---|---|
| `running` | The loop is running, and its process exists. | Attach to its session, or wait. |
| `done` | The loop exited with code `0`. | Read the PR. |
| `needs-human` | Exit `3`. The spec is `BLOCKED`, or review findings remain. | Fix it in the worktree (see [Resume a stopped loop](#resume-a-stopped-loop)). |
| `limit` | Exit `4`. The account reached its usage limit. | Resume after the limit resets. |
| `failed` | Exit `2` or `5`. Preflight, git, or a stage failed. | Read the reason and the log, fix the cause, then resume. |
| `killed` | The loop received `SIGHUP`, `SIGINT`, or `SIGTERM`, for example because its tmux session was closed. | Resume. |
| `died` | The record says `running`, but the process no longer exists. The loop was killed with `SIGKILL`, or the machine went down. No trap could run to record the outcome. | Run `git status` in the worktree, then resume. |

Each loop writes two kinds of files:

- The status record, at `.git/loops/<run-id>.json`. The run ID is `<timestamp>-issue-<N>`. The `.git/loops/` directory is in the repository's common git directory, which every worktree shares, so `status` finds every loop without needing to know where the worktrees are. Each loop writes only its own record, so parallel loops never write to the same file. The loop writes the record at start, at each stage, and at exit.
- The full log and model output, in the worktree's own `.loops/` directory, as described in [Watching it run](#watching-it-run). To follow one loop, run `tail -f .loops/latest/run.log` inside its worktree.

Status records are never deleted automatically. When you remove a worktree, its records remain, but the log paths in them no longer exist.

#### Resume a stopped loop

Run the command in the `NEXT` column. It uses the invoking checkout if you are on the issue branch; otherwise it uses the issue's dedicated worktree. It starts a new session and passes `--from <stage>` to the loop. The command includes `--cli codex` when the stopped run used Codex.

For `needs-human`, fix the problem before you resume:

1. Change to the issue's worktree. Its path is in the log path on the `↳` line.
2. Read the file that the summary names in the log, such as the spec's `## BLOCKED` section or `review-verify.md`.
3. Make the fix on the issue's branch and commit it. The loop's preflight refuses to start on a dirty worktree.
4. Run the `NEXT` command.

#### Stop a loop

```bash
tmux kill-session -t myapp-19
```

The loop script receives `SIGHUP` and records `killed`, but only after the current stage process exits. When `timeout` or `gtimeout` is installed, as [Setup](#setup) recommends, it runs the stage's `claude` or `codex` process in a separate process group. Closing the session then does not stop that process. It continues until it finishes or reaches `STAGE_TIMEOUT`, and until then `status` shows the loop as `running`.

#### Clean up

After an issue's PR is merged, remove its worktree:

```bash
git worktree remove ../myapp-loops/issue-19
rm .git/loops/*-issue-19.json    # Optional: forget the issue's status records
```

`git worktree remove` accepts the worktree's `.loops/` directory because the loop adds `.loops` to `.git/info/exclude`, so git ignores it.

#### Plan for shared resources

Parallel loops share the machine, the git repository, and your accounts. The loops do not account for each other.

- **CPU and RAM:** Each loop measures the whole machine and sets its build parallelism and subagent count as if it were the only loop (see [Configuration](#configuration)). Three loops on one machine therefore ask for three times the machine's capacity. Divide the budget yourself, for example `BUILD_JOBS=2 SUBAGENT_CAP_OVERRIDE=1 ./scripts/loops run 19 21 24`.
- **Disk:** Each worktree holds its own build artifacts. Each loop checks `MIN_DISK_GB` once, at its own start, against the free disk at that time. Stages that create their own worktrees multiply the disk use again. Set `ALLOW_WORKTREES_OVERRIDE=no` when disk is limited.
- **Usage limits:** All Claude loops draw on the same subscription. All Codex loops draw on the same Codex account. When one loop reaches the limit, the others usually reach it soon after. When the limit resets, resume each `limit` loop from `status`.
- **Branches:** git checks out a branch in only one worktree at a time. If the issue branch is checked out in another checkout, run `loops` from that checkout or switch it to another branch before starting the dedicated worktree.
- **Worktree location:** Preflight refuses to start when a worktree is nested inside the loop's checkout, because `git add -A` would commit it as an embedded repository. The default location, `../<repo>-loops/`, is outside the checkout. Keep `LOOPS_WORKTREE_ROOT` outside it too.
- **Fetches:** Every loop runs `git fetch` in the same repository. Two fetches at the same moment can fail to lock a ref. The loop logs the error and continues with the refs it already has.

### Using Worktrees

You can spin up git worktrees if you want to work on multiple tickets/features at a time, on the same machine. I would recommend not doing this for two tasks that have a lot of overlapping surface area in the codebase. It can be great for parallelizable work, though.

To run the issue loop on several issues in parallel worktrees, use `scripts/loops` instead (see [Running loops in parallel](#running-loops-in-parallel)).

e.g. I'm in codebase root and want to make a worktree in the same folder and immediately get onto a new branch to do parallel PRs:
```bash
git worktree add ../bugfix/49-fix-race-condition -b bugfix/49-fix-race-condition
cd ../bugfix/49-fix-race-condition && claude
```
