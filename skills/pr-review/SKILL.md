---
description: Review pull request \#$1 from the perspective of a senior software engineer
allowed-tools: Bash(gh pr checkout:*), Bash(gh pr view:*), Bash(gh issue view:*), Bash(git diff:*)
argument-hint: [pr-number]
---

# /pr-review $1

You are a senior software engineer doing a deep review of PR # $1 in this repository.

Before you write the review report or any review comment, invoke `/clear-technical-writing`. Write for a competent engineer who is new to the codebase. Define internal components before you describe their interactions, and make each finding concrete and actionable.

## Steps to follow

1. Use the GitHub CLI to check out the PR branch and view its details (title, body, and base branch):
   ```bash
   gh pr checkout $1
   # Get PR details specifically looking for the base branch name
   gh pr view $1 --json title,body,baseRefName,url
   ```

2. Identify the **base branch** from the previous step (usually `dev` or `main`). Use `git diff` to find changes relative to that base branch:

   ```bash
   # Example if base branch is 'dev'
   git diff origin/dev...HEAD
   ```

   * Ignore non-code changes such as `.sqlx` offline query data files, dependencies, build targets, etc.

3. **Identify Linked Issues & Requirements:**
   - Parse the PR description (from step 1) for linked issues (e.g., "Fixes #123", "Closes #456", or just mentions of #123).
   - If an issue number is found, fetch its description to understand the requirements:
     ```bash
     gh issue view <issue-number>
     ```
   - **CRITICAL:** If an issue is linked, your review must focus on whether the PR strictly fulfills the requirements laid out in that issue.
   - If no issue is linked, rely on the PR description for context.

4. **Identify linked implementation spec in the codebase**
   - Implementation specs are located under `./specs`, and conventionally are named similarly to the branch of the PR. Both usually have the issue number at the beginning of the slug.
     - e.g. if this is branch `v0/feature/22-plugin-hosting`, the spec is under `./specs/v0/feature/22-plugin-hosting.md`, and this PR is linked to close issue #22
   - Sometimes the spec is not named exactly according to the convention above, but is still identifiable by reading the diff of the PR, as the spec will be a new or edited file related to the PR scope.
   - **Instructions**: read the spec, if any, and ingest the context on how it was implemented
     - are there planned *slices* that build a dependency graph of the code?
     - were the slices implemented as commits? one slice, one commit?
     - what were the implementation notes left in the file? where should this PR review look for bugs? what issues did the implementor run into during coding?

5. Traverse the changed files and review them for the following dimensions:

   Start with AGENTS.md as an entry point if available — it should point you to the right places to look; otherwise explore the codebase.

   * **Correctness:** Does the logic implement the feature/bug-fix as described? **Does it satisfy the linked issue's requirements?** Are edge cases handled? Are error conditions, concurrency, lifetimes (in Rust) or promise/async/callbacks (in JS/TS) properly managed?
   * **Security & robustness:** Are there vulnerabilities (injection, unvalidated input, misuse of unsafe in Rust, unchecked unwraps, unchecked `Result`/`Option`, race conditions, missing authentication/authorization)?
   * **Performance & resource usage:** Are large allocations or unnecessary copies being made? Are there inefficient loops or blocking operations on critical paths? For Rust, any unnecessary cloning or expensive operations in hot paths?
   * **Code style & readability:** Is the code clear, maintainable? Does it follow our project standards (naming, modularization, layering, separation of concerns)? Are comments or doc-strings missing where helpful?
   * **Test coverage & quality:** Are there corresponding tests for the new behavior or bug fix? Are negative/error cases tested? Is mocking/fakes used correctly?
   * **Integration & side-effects:** Are new dependencies introduced? Are migrations/data/DB schema changes handled? Are changes backward-compatible? Is state correctly managed?
   * **Frontend/back-end interactions (for full-stack):** If this PR touches React or UI code, does it respect UX/flow, error states, loading states, communication with backend, correct data shapes, etc?
   * **Documentation & release readiness:** Is the PR description clear? Are any user-facing changes documented? Are there migration or deployment considerations mentioned?

   *Parallelism*: if there are parts of the code diff that do not overlap eachother significantly and warrant parallel reviewer sub-agents -- e.g. entirely different code surfaces that don't interact and have no unmet dependency on each other -- hand them to *subagents that run concurrently*. A helpful place to know if there are indpendent code surfaces is to look at the planned *slices* from the implementation spec, if any were found in step 4 of this review. Run no more than 4 subagents at a time. After parallel reviews land, integrate their findings and consolidate any findings that should relate to eachother. 

6. Summarize your findings in a structured report:

   * What is done well / strong points.
   * What to improve — list issues by severity (Critical / Major / Minor) and reference specific files/lines (if possible).
   * Suggested fixes or mitigations where applicable.
   * If everything is acceptable: indicate “✅ Approved” and note any remaining minor follow-up tasks (e.g., refactor in next iteration).

7. Provide your final recommendation: Approve, Request changes, or Comment with suggestions.
8. If you request changes: leave a set of actionable comments to the author and optionally specify sample code snippets or references to our coding standards.
9.  If approved: optionally note any “nice-to-haves” that could be addressed in future PRs (non-blocking).

---

**Important:** Use the GitHub CLI (`gh`) and local `git` commands for all repository-interactions (checkout, diff, view) and reference the actual codebase rather than using GitHub UI.

---

End of command.
