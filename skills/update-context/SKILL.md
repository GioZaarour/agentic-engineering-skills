---
description: Update AGENTS.md and README.md with high-level context from the current branch, its linked issue, and its diff against the base branch.
argument-hint: [base-branch]
globs: AGENTS.md, README.md
allowed-tools: Read, Edit, Write, Glob, Grep, Bash(git status:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git merge-base:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(gh issue view:*)
---

# Update Context from the Current Branch

You are tasked with updating the `AGENTS.md` file in the root of the codebase. This file serves as the primary source of truth for high-level context, architecture, and structural knowledge for AI agents working on this project.

Before you edit `AGENTS.md` or `README.md`, invoke `/clear-technical-writing`. Apply it to every addition or revision. Write for a competent engineer who is new to the codebase, and introduce each internal component before you describe how components interact.

## Step 1: Gather Information

1. **Resolve the Branch Diff**:
   Stay on the current branch. Resolve the **base branch** from argument `$1` if given, otherwise use `main`. Find the fork point, commit list, and merge-base diff:
   ```bash
   git merge-base origin/<base> HEAD
   git log --oneline origin/<base>..HEAD
   git diff origin/<base>...HEAD
   ```
   Also inspect `git status` and `git diff HEAD` so recent uncommitted edits are not missed. Do not fetch, push, check out another branch, or open a pull request.

2. **Identify Linked Issues**:
   - Parse the current branch name for an issue number. The convention is `[version]/[type]/[issue]-[slug]`, for example `v0/feature/22-plugin-hosting` links to issue #22.
   - If necessary, infer the issue from a spec file added or changed on the branch. Specs conventionally use `specs/[version]/[type]/[issue]-[slug].md`.
   - If an issue number is found, fetch its description:
     ```bash
     gh issue view <issue-number>
     ```
   - If no issue is linked, rely on the spec, commits, and diff for context.

3. **Read the Implementation Spec**:
   - Find the spec under `./specs` that corresponds to the branch or linked issue.
   - Read its scope, implementation notes, derived decisions, deferred work, and completed slices.
   - Treat the actual branch diff as authoritative when the spec and implementation differ.

## Step 2: Analyze and Update

Base your updates on the issue, implementation spec, commit history, and branch diff.

## What to Update

Your goal is to capture **implicit, high-level, and structural** knowledge that is not immediately obvious from reading the code itself.

### ✅ DO Include:
- **Infrastructure Changes**: Updates to Docker, Terraform, Nginx, CI/CD, deployment workflows, or environment variables.
- **New Services & Components**: New backend services (Rust), frontend pages (Next.js), or major architectural components.
- **Integrations**: New integrations to external services (such as Stripe, Loops, Privy) that need special consideration like secrets in .env and CI.
- **End-to-End Flows**: How new features connect across the stack (e.g., "The new billing flow uses a Stripe webhook to update the `credits` table via `BillingService`").
- **Product Context**: High-level explanations of what the product does, new user-facing features, and how they fit into the platform.
- **New Utilities & Helpers**: Shared libraries or patterns that establish *how* code should be written (e.g., "Added a `verify_signature` middleware for all webhooks").
- **Structural Relationships**: How different modules, services, and folders connect.

### ❌ DO NOT Include:
- **Function-Level Details**: Do not describe what specific functions do (e.g., "The function `x` takes `y` and returns `z`"). The AI can read the code.
- **Explicit Code Facts**: Avoid stating things that are obvious from file names or signatures.
- **Minor Implementation Details**: Bug fixes, variable renames, or logic changes that don't alter the system architecture.

## Step 3: Update README.md

README.md is a human developer-facing file that serves as the entry point to the repository. If, and ONLY if, there are significant changes on the branch that warrant a change to README.md, also update it.

README.md should have a high level overview of the project and it's end-to-end function and purpose. It should have an architecture overview section. It should have a dependencies and prerequisites section. It should have development instructions for how to run the code. Make sure these aspects are present and up-to-date.

Keep it high-level in the README.md and don't go into nitty gritty details about the code infrastructure, components, services, files and folders, etc.

## Execution Steps

1. **Read `AGENTS.md`**: Familiarize yourself with the current structure, tone, and categories.
2. **Synthesize Changes**: Analyze the issue, spec, commits, and diff to identify *structural* and *architectural* shifts.
3. **Edit `AGENTS.md`**:
   - **Add** new sections for entirely new domains or features.
   - **Update** existing sections (e.g., "Project overview", "Services and integrations", "Infrastructure") with new details.
   - **Remove** or mark as deprecated any outdated information.
   - **Refine** descriptions to explain how new parts connect to the existing system.
   - **Maintain** the existing markdown formatting and style.
4. **Read `README.md` and update if necessary**

**Final Output**: A modified `AGENTS.md` file that acts as a high-level "brain" for the codebase, helping future agents understand *why* and *how* the system works as a whole. An up-to-date README.md.
