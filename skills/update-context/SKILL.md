---
description: Update AGENTS.md with high-level context from recent changes in PR \#$1 (includes linked issues and diff analysis).
argument-hint: [pr-number]
globs: AGENTS.md
allowed-tools: Bash(gh pr checkout:*), Bash(gh diff:*), Bash(gh pr view:*), Bash(gh issue view:*)  
---

# Update Context from PR #$1

You are tasked with updating the `AGENTS.md` file in the root of the codebase. This file serves as the primary source of truth for high-level context, architecture, and structural knowledge for AI agents working on this project.

## Step 1: Gather Information

1. **Fetch PR Details**:
   Use the GitHub CLI to check out the PR branch and view its details (title, body, and base branch).
   ```bash
   gh pr checkout $1
   # Get PR details specifically looking for the base branch name
   gh pr view $1 --json title,body,baseRefName,url
   ```

2. **Fetch Diff**:
   Identify the **base branch** from the previous step (e.g., `dev` or `main`). Use `git diff` to find changes relative to that base branch.
   ```bash
   # Example if base branch is 'dev'
   git diff origin/dev...HEAD
   ```

3. **Identify Linked Issues**:
   - Parse the PR description (from step 1) for linked issues (e.g., "Fixes #123", "Closes #456", or just mentions of #123).
   - If an issue number is found, fetch its description:
     ```bash
     gh issue view <issue-number>
     ```

## Step 2: Analyze and Update

Base your updates on the collected information (PR Description, Issue Context, and Diff).

## What to Update

Your goal is to capture **implicit, high-level, and structural** knowledge that is not immediately obvious from reading the code itself.

### ✅ DO Include:
- **Infrastructure Changes**: Updates to Docker, Terraform, Nginx, CI/CD, deployment workflows, or environment variables.
- **New Services & Components**: New backend services (Rust), frontend pages (Next.js), or major architectural components.
- **Integrations**: New integrations to external services (such as Stripe, Loops, Privy) that need special consideration like secrets in .env and CI.
- **End-to-End Flows**: How new features connect across the stack (e.g., "The new billing flow uses a Stripe webhook to update the `credits` table via `BillingService`").
- **Product Context**: High-level explanations of what the product does, new user-facing features, and how they fit into the platform.
- **New Utilities & Helpers**: Shared libraries or patterns that establish *how* code should be written (e.g., "Added a `verify_signature` middleware for all webhooks").
- **Structural Relationships**: How different modules, services, and folders glue together to form a cohesive system.

### ❌ DO NOT Include:
- **Function-Level Details**: Do not describe what specific functions do (e.g., "The function `x` takes `y` and returns `z`"). The AI can read the code.
- **Explicit Code Facts**: Avoid stating things that are obvious from file names or signatures.
- **Minor Implementation Details**: Bug fixes, variable renames, or logic changes that don't alter the system architecture.

## Step 3: Update README.md

README.md is a human developer-facing file that serves as the entry point to the repository. If, and ONLY if, there are any significant changes in the recent PR that warrant a change to README.md, also update it.

README.md should have a high level overview of the project and it's end-to-end function and purpose. It should have an architecture overview section. It should have a dependencies and prerequisites section. It should have development instructions for how to run the code. Make sure these aspects are present and up-to-date.

Keep it high-level in the README.md and don't go into nitty gritty details about the code infrastructure, components, services, files and folders, etc.

## Execution Steps

1. **Read `AGENTS.md`**: Familiarize yourself with the current structure, tone, and categories.
2. **Synthesize Changes**: Analyze the PR info and Diff to identify *structural* and *architectural* shifts.
3. **Edit `AGENTS.md`**:
   - **Add** new sections for entirely new domains or features.
   - **Update** existing sections (e.g., "Project overview", "Services and integrations", "Infrastructure") with new details.
   - **Remove** or mark as deprecated any outdated information.
   - **Refine** descriptions to glue new parts into the existing system.
   - **Maintain** the existing markdown formatting and style.
4. **Read `README.md` and update if necessary**

**Final Output**: A modified `AGENTS.md` file that acts as a high-level "brain" for the codebase, helping future agents understand *why* and *how* the system works as a whole. An up-to-date README.md.

