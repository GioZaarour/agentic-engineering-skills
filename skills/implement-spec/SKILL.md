---
description: Implement a spec to completion in reviewable slices, test-driven. For each slice — write failing tests, implement to green, document the code, clean techdebt, then commit. Independent slices run in parallel. Small specs are a single slice.
argument-hint: [spec-file-path]
---

# /implement-spec $1

Build the active spec (@$1 if given) to completion, one reviewable slice at a time, test-first. The spec is the source of truth — but if the code teaches you the plan is stale, improve the architecture and update the spec to match (note what changed and why).

Read the repo's AGENTS.md, then the spec. If the spec has a **Slices** section, that's your plan and dependency graph. If it doesn't, treat the whole spec as a **single slice** — do not invent slices for work that's really one commit.

Run to completion: finishing a slice means starting the next, not handing back. Only stop for a genuine blocker that needs a decision only the user can make.

## The per-slice loop

Every slice — including a single-slice spec — runs this loop before its commit:

1. **Write the failing tests** from the slice's acceptance criteria. TDD is mandatory wherever the code is unit-testable (Rust logic, pure functions, FFI contracts): red first, then green. For code where a failing-first unit test is impractical (e.g. DSP/audio/realtime), pin the contract with a characterization or integration test instead (rendered-output assertions, buffer invariants, golden files) — the slice is not done until *some* automated test covers it. Never skip a test because it's hard, and never weaken an existing test to pass.
2. **Implement** the slice to make the tests pass. Keep the diff scoped to this slice.
3. **Document** the slice's new and changed code inline using `/document-code`. That skill invokes `/clear-technical-writing`, so the comments define internal terms and explain the code for an engineer who is new to the codebase.
4. **Clean techdebt** with a fresh, un-primed subagent. Spawn a subagent scoped to *only this slice's uncommitted changes* (`git diff HEAD` plus untracked files — explicitly not the whole branch against main), and have it run the `techdebt` skill on that diff, apply fixes to the working tree, and **not** commit (you own the single slice commit in step 5). It's un-primed on purpose — it catches cruft the author is blind to. Apply its fixes.
5. **Commit.** Requirement: the slice's new tests and the tests in the areas it touched must be green (full-suite regression is checked once at the end of the run, not per slice). Write a focused commit whose message starts with `feat:`, `bugfix:`, `chore:`, `docs:`, or `tests:`. Then check the slice off in the spec's Slices section. **Do not push** — the user pushes.

## Parallelism

Read the slice dependency graph as a wavefront. Whenever two or more slices have no unmet dependency on each other, hand them to **subagents that run concurrently** (spawn them in one message) — you orchestrate and integrate. Give **each parallel subagent its own git worktree** so their diffs don't collide. Each subagent owns its full per-slice loop (tests → implement → document → techdebt → commit). Serialize only slices that genuinely depend on prior work; never idle a lane waiting on an unrelated one. After parallel slices land, integrate them, resolve conflicts, and rerun the affected tests on the merged tree.

Follow any machine budget your caller supplies. It overrides the fan-out above: run no more subagents at once than its cap, and when it says worktrees are not allowed, give no subagent its own worktree. Work the slices one at a time in the current tree instead. A worktree that builds needs its own copy of every build artifact, and each concurrent build needs its own share of RAM.

## Done

A **slice** is done when its tests are green, the code is documented, techdebt is clean, and a focused commit has landed.

The **spec** is done when every slice is checked off and the **full test suite passes** on the merged tree. Before you report what was built, invoke `/clear-technical-writing` and apply it to the report. Leave pushing to the user.
