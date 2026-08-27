# GioZaarour Agent Skills & Loops 

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

Then invoke them by name in a session — `/spec-planning`, `/review-spec`, `/implement-spec`, `/techdebt`, `/pr-review`, `/update-context`, `/document-code`, `/spec-from-issue`, `/clear-technical-writing`. A session that was already open when you installed them won't see them; start a new one.

`/clear-technical-writing` is a shared writing layer for human-facing engineering text. The spec, code-documentation, PR-review, and context-update skills invoke it automatically. You can also invoke it directly for PR descriptions, review comments, repository documentation, and engineering reports.

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
- Make a PR (generate description from main implementation session, or write it yourself)
- Run `/pr-review` (separate session, with strong model) then iterate on requested changes if needed
- `/update-context` to keep `AGENTS.md` and `README.md` up-to-date (in the main session, with cheaper model)

### Loop Engineering path

`scripts/issue-loop.sh` takes **one** GitHub issue from "open" to "PR under review", unattended. It is the same path as above with the human taken out: every step is a skill you can run by hand, and the script's only job is to run them in order, in separate processes, and to stop in a recoverable way when something needs you.

```
preflight → resolve → sync → spec → spec-review → implement → techdebt → pr → review ⇄ fix → context
```

Each stage is its own `claude -p` process with a clean context window. State moves between them through git and files on disk, never through a shared context — so a stage that goes wrong is bounded, and any stage can be re-run on its own.

| Stage | What runs | Model |
|---|---|---|
| `spec` | `/spec-from-issue` — derives the spec, or iterates on one that already exists | `PLAN_MODEL` (xhigh) |
| `spec-review` | a non-interactive critique of the spec against the actual code | `PLAN_MODEL` (xhigh) |
| `implement` | `/implement-spec` — test-first, slice by slice | `CODE_MODEL` (xhigh) |
| `techdebt` | `/techdebt` over the whole branch diff | `CODE_MODEL` (high) |
| `pr` | pushes, writes a PR description from the diff and the spec, opens the PR | `CODE_MODEL` (high) |
| `review` | `/pr-review` ⇄ fix, up to `MAX_REVIEW_ROUNDS`, ending on a review so the count is honest | `PLAN_MODEL` / `CODE_MODEL` |
| `context` | `/update-context` against the PR | `CODE_MODEL` (high) |

The `spec-review` stage does not call `/review-spec`. That skill is an interview — it stops and asks you things — and under `claude -p` an interview is not a slow run, it is a dead one. The critique is inlined in the script with the questions removed and the standards kept.

#### Setup

1. Install the skills — `./install.sh`, as above. The loop calls `/spec-from-issue`, `/implement-spec`, `/techdebt`, `/pr-review`, and `/update-context`. Those skills and the inline PR-writing stages use `/clear-technical-writing` for human-facing text. Preflight checks for all six skills and warns (it does not block) if it cannot find one, so a missing skill shows up in the first ten seconds instead of an hour into a run.
2. Copy `scripts/issue-loop.sh` and `scripts/loops-lib.sh` into your own repo, under `scripts/`. They must sit next to each other. Committing them to your repo is the simplest thing to do; if you would rather keep them untracked, add both paths to `.git/info/exclude` — **not** `.gitignore`. `.gitignore` is tracked and therefore branch-scoped, so a rule you add on `main` does not exist on the feature branch the loop is about to `git add -A` on. Preflight refuses to start unless one of the two is true.
3. On your PATH: `claude`, `gh`, `jq`, `git`, and bash **4.2 or newer**. macOS ships bash 3.2 as `/bin/bash` — `brew install bash` and make sure it comes first, or the scripts will die on a syntax error. macOS also has no `timeout`; `brew install coreutils` gives you `gtimeout`, which the scripts find on their own. Without it a wedged stage hangs forever instead of being killed at `STAGE_TIMEOUT`.
4. `gh auth login`, once, on the machine that will run the loop.
5. Optional but worth ten minutes: copy `scripts/loop-notes.example.md` to `.loop-notes.md` at your repo root and rewrite it for your project — how to build, how to run tests, which suites cannot run on this host, which toolchain is not on PATH. Every stage gets that text appended to its prompt. Without it, each stage works your build and test commands out from the repo, over and over, and sometimes gets them wrong.
6. Start from a **clean working tree**. Preflight refuses to run dirty, and refuses to run with extra worktrees present. Which branch you are standing on does not matter — it checks out the issue's branch, or creates it from `BASE_BRANCH`; the one thing it will not do is resolve the issue's branch *to* the base branch and commit there.

#### First run: always dry-run first

```bash
./scripts/issue-loop.sh <issue-number> --dry-run
```

This resolves the issue, works out the branch, spec path and type, prints the plan, and changes nothing — no commits, no pushes, no comments. Read it before anything real, especially to check whether it correctly found an **existing** branch and spec instead of planning to create new ones. Add `--no-adopt` if you want the dry run to be strictly free: without it, when no branch or spec matches the naming convention, one cheap read-only model call goes looking for one under a different name.

#### The real run

```bash
./scripts/issue-loop.sh <issue-number>
```

It runs in the foreground and can take hours. For anything real, detach it — tmux is strongly recommended, and non-optional on a VPS or a cloud container, where a dropped terminal otherwise kills the loop mid-edit:

```bash
tmux new -d -s issue<N> './scripts/issue-loop.sh <N>'
tmux attach -t issue<N>     # watch it live; Ctrl-b d to detach again
```

> [!WARNING]
> **This is not a sandbox.** Stages run with `--permission-mode bypassPermissions`, which means no tool call will ever stop and ask you. The loop will push branches, open real PRs, label the real issue, and — in the fix rounds — file or comment on real techdebt issues in your repo. It does not merge anything, and that is the only thing it will not do. Once the dry run looks right, treat the issue number you pass it as a commitment. Run it on a machine and a repo where an agent acting on its own for a few hours is acceptable.

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
| `pr.md` | PR title (line 1) + body |
| `review-1.md`, `fix-1.json` | review round 1 and the fix that answered it |
| `review-verify.md` | the final verification review, when one ran |
| `ctx.json` | the `update-context` stage |

The `.json` files are raw `claude -p --output-format json` results — `.result`, `.total_cost_usd`, `.session_id`. The `.md` files are the readable text, pre-extracted for the spec reviews and PR reviews.

Cost so far, at any time, without waiting for the run to finish:

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
| `0` | Done; the review came back clean — or no review stage was selected, in which case the summary says so in as many words | Read the PR, starting with the "Decided without human input" section |
| `2` | Preflight or usage error; nothing was touched | Fix what it reported and run again |
| `3` | Needs a human: the spec `BLOCKED`, or findings survived the fix rounds (or the review never returned a verdict) | Read the file it names — `.loops/latest/<N>/review-verify.md`, or the spec's `## BLOCKED` section — resolve it, then resume |
| `4` | Hit an account spend/usage limit mid-run | The branch is pushed and safe to leave; resume once the limit resets |
| `5` | A stage failed outright | The branch is pushed as a WIP commit; the summary names the exact resume command |

Every stop prints a summary block with the resume command already filled in, e.g.:

```bash
./scripts/issue-loop.sh 19 --from implement
```

`--from <stage>` re-runs that stage and everything after it, reusing whatever branch and spec already exist instead of starting over. Stages: `spec`, `spec-review`, `implement`, `techdebt`, `pr`, `review`, `context`.

Whenever it stops in a way that needs you — a blocked spec, a failed stage, an exhausted account — the issue is labelled `needs-human`, and so is the PR when the review left findings behind. A clean review clears it again. Both that label and the `techdebt` label are created in your repo on the first run if they don't exist, because `gh --add-label` on a missing label is a silent no-op, and a silent no-op here is exactly the signal you'd be looking for.

#### Flags worth knowing

| Flag | Effect |
|---|---|
| `--dry-run` | Resolve everything, print the plan, change nothing. Always first. |
| `--from <stage>` | Run this stage and every stage after it |
| `--stages a,b,c` / `--skip a,b` | Run exactly these / drop these |
| `--fresh-spec` | Re-derive the spec instead of iterating on the existing one |
| `--spec-rounds N` | Spec critique passes after derivation (default 1, `0` = off) |
| `--no-push` | Never push, never open a PR (implies skipping `pr`, `review`, `context`) — a local-only run of spec + implement |
| `--type <t>` / `--version <v>` / `--branch <name>` / `--spec <path>` / `--base <branch>` | Override the inference when it guesses wrong — check the `--dry-run` output first |
| `--merge-base` | Merge `origin/<base>` into the branch if it has fallen behind |
| `--no-adopt` | Skip the off-convention matcher; if the naming convention was not followed, just create the conventional branch and spec |

#### Configuration

Everything is an environment variable with a sane default; there is no config file. The ones people actually change:

| Variable | Default | What it does |
|---|---|---|
| `PLAN_MODEL` | `claude-opus-5` | Spec derivation, spec review, PR review |
| `CODE_MODEL` | `claude-sonnet-5` | Implementation, techdebt, fixes, context |
| `BASE_BRANCH` | `main` | What the PR targets, and what new branches are cut from. Set it to an unmerged branch to stack work on top of it. |
| `VERSION_SEGMENT` | `v0` | The first path segment in branch and spec names |
| `DEFAULT_TYPE` | `bugfix` | Used when labels and the title say nothing |
| `BUGFIX_LABELS` / `FEATURE_LABELS` | see script | Regexes over your `gh label list` |
| `MAX_REVIEW_ROUNDS` | `2` | Review ⇄ fix rounds before it gives up and asks for a human |
| `STAGE_TIMEOUT` | `14400` | Seconds per stage; a wedge detector, not a pace target |
| `MB_PER_JOB` | `2048` | RAM per build job — raise it for a heavy C++ toolchain, lower it for a light one |
| `SUBAGENT_CAP_OVERRIDE` | measured | Concurrent subagents a stage may fan out to |
| `STAGE_BUDGET_USD` / `TOTAL_BUDGET_USD` | `0` (off) | Cost ceilings, in dollars: per stage (passed to `claude` as `--max-budget-usd`) and per run (checked between stages, so a stage is never killed mid-edit — the run stops recoverably at exit `5`). Off by design; set them if you are on metered API billing. |
| `PERMISSION_MODE` | `bypassPermissions` | Read the warning above before changing this to something stricter, and expect stages to stall if you do |
| `RUN_ROOT` | `.loops` | Where run artifacts go |

The machine budget is **measured, not assumed**: cores, RAM, swap and free disk are read at startup, and the subagent cap, the build parallelism and whether worktrees are allowed are derived from them and injected into every prompt. The same script yields `-j1` and one subagent on a 4 GB VPS and more on a 32 GB workstation, with no edit.

#### What it decides without you

This is the part to be deliberate about. With no human in the loop, `/spec-from-issue` closes every open question from **code**, **precedent**, or — where neither answers and the decision is cheap to reverse — **derives** it and logs it. Anything expensive or product-facing is a hard `BLOCK`: the spec's first section becomes `## BLOCKED`, the run stops at exit `3`, and nothing is implemented.

So the PR description's **"Decided without human input"** section is not boilerplate. It is the complete list of places where the loop made your call for you. Read it first, every time. If the list is long, or the spec has no `Derived decisions` section at all (the script warns when it doesn't), that is the signal the issue was underspecified — which is a problem with the issue, not the loop.

Two more places the loop guesses, both of which the `--dry-run` shows you: the **type** (from labels, then the title, then `DEFAULT_TYPE`) and, when nothing matching the issue number exists, whether an off-convention branch or spec is really this issue's. The matcher for that second one is a cheap model with read-only tools, it may only return a name that is already on the list it was given, and the shell re-checks the answer against git and the filesystem before using it — a hallucinated branch name is discarded, not checked out.

### Using Worktrees

You can spin up git worktrees if you want to work on multiple tickets/features at a time, on the same machine. I would recommend not doing this for two tasks that have a lot of overlapping surface area in the codebase. It can be great for parallelizable work, though.

e.g. I'm in codebase root and want to make a worktree in the same folder and immediately get onto a new branch to do parallel PRs:
```bash
git worktree add ../bugfix/49-fix-race-condition -b bugfix/49-fix-race-condition
cd ../bugfix/49-fix-race-condition && claude
```
