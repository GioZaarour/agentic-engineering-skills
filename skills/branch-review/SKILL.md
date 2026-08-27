---
description: Review the work done on this branch from the perspective of a senior software engineer
allowed-tools: Bash(git status:*), Bash(git branch:*), Bash(git rev-parse:*), Bash(git merge-base:*), Bash(git log:*), Bash(git diff:*), Bash(git show:*), Bash(gh issue view:*)
argument-hint: [base-branch]
---

# /branch-review

You are a senior software engineer doing a deep review of the current checked out branch in this repository.

Before you write the review report or any review comment, invoke `/clear-technical-writing`. Write for a competent engineer who is new to the codebase. Define internal components before you describe their interactions, and make each finding concrete and actionable.

## Steps to follow

1. Stay on the current branch and inspect its status. Review committed local work even when the branch has no upstream or is ahead of its remote. Do not fetch, push, or check out another branch.


2. Resolve the **base branch** (argument `$1` if given, otherwise `main`). Find the fork point, the commit list, and the merge-base diff:

   ```bash
   git merge-base origin/<base> HEAD
   git log --oneline origin/<base>..HEAD
   git diff origin/<base>...HEAD
   ```

   Ignore non-code changes such as `.sqlx` offline query data files, dependencies, build targets, etc.

3. **Identify Linked Issues & Requirements:**
   - Parse the current branch name for an issue number. Convention: `[version]/[type]/[issue]-[slug]`, e.g. `v0/feature/22-plugin-hosting` → issue #22.
   - The issue (if it exists) can also be inferred from a spec file in the branch diff, if any. Spec file naming conventions: `specs/[version]/[type]/[issue]-[slug].md` — similar to the branch name convention.
   - If an issue number is found, fetch its description:
     ```bash
     gh issue view <issue-number>
     ```
   - **CRITICAL:** If an issue is linked, your review must focus on whether the branch strictly fulfills the requirements laid out in that issue.
   - If no issue is linked, rely on the spec (step 4) and/or the commits for context.

4. **Identify linked implementation spec in the codebase**
   - Implementation specs are located under `./specs`, and conventionally are named similarly to the current branch. Both usually have the issue number at the beginning of the slug.
     - e.g. if this is branch `v0/feature/22-plugin-hosting`, the spec is under `./specs/v0/feature/22-plugin-hosting.md`, and the branch is meant to close issue #22
   - Sometimes the spec is not named exactly according to the convention above, but is still identifiable by reading the branch diff, as the spec will be a new or edited file related to the branch scope.
   - **Instructions**: read the spec, if any, and ingest the context on how it was implemented
     - are there planned *slices* that build a dependency graph of the code?
     - were the slices implemented as commits? one slice, one commit?
     - what were the implementation notes left in the file? where should this review look for bugs? what issues did the implementor run into during coding?

5. Traverse the changed files and review them for the following dimensions:

   Start with AGENTS.md as an entry point if available — it should point you to the right places to look; otherwise explore the codebase.

   * **Correctness:** Does the logic implement the feature/bug-fix as described? **Does it satisfy the linked issue's requirements?** Are edge cases handled? Are error conditions, concurrency, lifetimes (in Rust) or promise/async/callbacks (in JS/TS) properly managed?
   * **Security & robustness:** Are there vulnerabilities (injection, unvalidated input, misuse of unsafe in Rust, unchecked unwraps, unchecked `Result`/`Option`, race conditions, missing authentication/authorization)?
   * **Performance & resource usage:** Are large allocations or unnecessary copies being made? Are there inefficient loops or blocking operations on critical paths? For Rust, any unnecessary cloning or expensive operations in hot paths?
   * **Code style & readability:** Is the code clear, maintainable? Does it follow our project standards (naming, modularization, layering, separation of concerns)? Are comments or doc-strings missing where helpful?
   * **Test coverage & quality:** Are there corresponding tests for the new behavior or bug fix? Are negative/error cases tested? Is mocking/fakes used correctly?
   * **Integration & side-effects:** Are new dependencies introduced? Are migrations/data/DB schema changes handled? Are changes backward-compatible? Is state correctly managed?
   * **Frontend/back-end interactions (for full-stack):** If this branch touches React or UI code, does it respect UX/flow, error states, loading states, communication with backend, correct data shapes, etc?
   * **Documentation & release readiness:** Are any user-facing changes documented? Are there migration or deployment considerations that a later PR description must mention?

   *Parallelism*: if parts of the code diff do not overlap significantly and warrant parallel reviewer subagents — for example, independent code surfaces with no unmet dependency on each other — hand them to subagents that run concurrently. The implementation spec's planned slices can help identify independent surfaces. Follow any lower subagent cap supplied by the caller's machine budget; otherwise, run no more than 4 subagents at a time. After the parallel reviews finish, integrate their findings and consolidate related findings.

6. Summarize your findings in a structured report:

   * What is done well / strong points.
   * What to improve — list issues by severity (Critical / Major / Minor) and reference specific files/lines (if possible).
   * Suggested fixes or mitigations where applicable.
   * If everything is acceptable: indicate “✅ Approved” and note any remaining minor follow-up tasks (e.g., refactor in next iteration).

7. Provide your final recommendation: Approve, Request changes, or Comment with suggestions.
8. If you request changes: leave a set of actionable comments to the author and optionally specify sample code snippets or references to our coding standards.
9.  If approved: optionally note any “nice-to-haves” that could be addressed in future PRs (non-blocking).

---

**Important:** Stay on the current branch. Use local `git` for status, log, diff, and show. Use `gh issue view` only for the linked issue. Reference the actual codebase rather than the GitHub UI.

---

End of command.
