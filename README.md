# GioZaarour Agent Skills & Loops 

This repository contains a set of agent skills I use to engineer software with AI coding tools like Claude Code and Codex. They can be installed and used with any agentic harness that supports the agentskills.io standard.

It also contains scripts for loop engineering -- scripts that automate the workflow of prompting the coding agents and starting new sessions that build off of past ones. You need to be careful with such loops because they can eat up tokens and usage credits. When writing your engineering specs for a loop, it's **VERY IMPORTANT** that you define the scope of your task (and work out of scope), acceptance criteria, and testing approach/cases. Agents need end-to-end verifiable goals so they know when to stop. You don't want to ever over-spend tokens or come back to an agent loop that entered schizophrenia mode on your codebase.

These skills and loops are all embracing the paradigm of spec-based, test-driven development. Based off a GitHub issue (or equivalent engineering ticket from a project management tool e.g. Jira, Linear, or GH Projects), there are skills for planning a detailed implementation spec, reviewing the spec, and implementing the spec by writing code tests first, and then implementing the code to pass the tests. 
Spec-based engineering is best for tasks that can be split into chunks/slices and have verifiable end-states. These skills or loops may not be useful for ad-hoc UI iterations, small bugfixes that don't need testing, documentation updates, etc. It's moreso for features and fixes that can be planned out with specs and have their code verified and tested. 

For the engineering loops, human-in-the-loop requirements are stripped away so that decisions are delegated to the AI model. So, rather than planning out an implementation spec based on a GH issue with the human, the model will just plan the spec for itself, based on that same GH issue, then pass on that spec to the next agentic coding session.

It's *highly recommended* to use the human-in-the-loop path rather than the automated loop path for **big features** that significantly impact your architecture or system design. Design decisions are always best instilled from the human, or else your codebase will drift from what you expect it to be. 

## Assumed Conventions

Parts of these skills and scripts assume conventions, which come from my own habits. You can change them however you want to fit your own liking. Here they are:

- Branch naming: I name branches like `[version]/[gitflow-category]/[Issue#]-[name]`. Example: `v0/feature/56-chatbot-conversation-history`. You can change those assumptions in the skills/scripts.
- Issues and PRs: The skills assume you're use GitHub to track issues, making PRs to close those issues (linking them together through PR descriptions such as "Closes #56"), and merging directly to `main`.
- Specs: The skills assume a `./specs` folder in the codebase, where it would write/read from specs with a matching naming convention to branch naming (e.g. `specs/v0/feature/56-chatbot-conversation-history.md`)
- CI/CD: The skills/scripts assume nothing about any existing CI/CD *or* deployment environments. You can add changes on your own, if you have them.
- Git and GH CLI: The scripts assume you have GH CLI and git installed, and that you use git at all (some people use Codeberg etc.)
- AGENTS.md: Assume you have one AGENTS.md file at the repo root, with all relevant context. You might need to symlink CLAUDE.md to this file, or change the convention to your own preference. 

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


### Using Worktrees

You can spin up git worktrees if you want to work on multiple tickets/features at a time, on the same machine. I would recommend not doing this for two tasks that have a lot of overlapping surface area in the codebase. It can be great for parallelizable work, though.

e.g. I'm in codebase root and want to make a worktree in the same folder and immediately get onto a new branch to do parallel PRs:
```bash
git worktree add ../bugfix/49-fix-race-condition -b bugfix/49-fix-race-condition
cd ../bugfix/49-fix-race-condition && claude
```
