---
description: Given a GitHub issue number, derive a complete implementation spec with no human interview — answering from precedent, code, and the parent spec — and write it to the conventional spec path.
argument-hint: [issue-number] [spec-file-path]
---

# /spec-from-issue $1

Derive a complete, implementable spec for GitHub issue **#$1** and write it to **$2**.

This is the unattended sibling of `/spec-planning`. The reasoning is identical; only the source of answers changes. In `/spec-planning`, a question closes one of three ways: the user answers it, the code answers it, or it's recorded OPEN. Here the user is not available, so a question closes one of four ways:

- **CODE** — the codebase answers it. Go read it. Always prefer this.
- **PRECEDENT** — a decision the user already made answers it: the parent spec this issue descends from, sibling specs under `./specs/`, `AGENTS.md`, or an unwritten convention the code consistently enforces. This is the replacement for the interview. The user's taste is not gone; it is recorded in what they already built and already specced. Go find it.
- **DERIVED** — neither covers it, but the decision is low blast radius and cheap to reverse. Decide it yourself, and log it.
- **BLOCKED** — neither covers it, and the decision is expensive or product-facing. Stop. See *The blocking bar*.

## Operating mode — non-negotiable

- **Never ask the user anything.** Do not use `AskUserQuestion`. Do not end your turn with a question, a confirmation request, or "let me know if you'd like me to proceed." No one is reading. A turn that ends in a question is a failed run: the pipeline will continue without a spec.
- **Never expand scope.** The spec covers issue #$1 and nothing else. Anything else you find goes in **Deferred**, not in the work.
- You must finish by either writing a complete spec to `$2`, or writing a spec to `$2` whose very first section is `## BLOCKED`. There is no third outcome.

## Step 0 — Gather the record

Before analysis, collect the inputs in parallel:

- `gh issue view $1 --json number,title,body,labels,comments` — read the comments, not just the body. Follow-up issues often carry the real scope in a comment.
- The **parent spec**: this issue almost certainly descends from a previous PR that had a full `/spec-planning` spec under `./specs/`. Find it — check the issue body and comments for a PR or issue reference, check `git log` for the commit that introduced the code this issue touches, check `./specs/` for the spec whose scope contains this one. **This document is your primary source of the user's taste. Read all of it, not the section that seems relevant.**
- `AGENTS.md` as the entry point to the codebase, then the areas the issue touches. Split the scan across parallel subagents.
- Two or three **sibling specs** under `./specs/` for issues of the same type. You are reading these for *form and standard*, not content: how much detail the user expects, how slices are cut, how acceptance criteria are phrased.

## Step 1 — Known knowns

State the request as you understand it and the facts the code pins down, with `file:line` citations. Separate what is locked by the issue and the code from what you are assuming. In the interactive version this exists so the user can correct a wrong framing before you go deep; here it exists so *you* catch a wrong framing, and so the reviewer of the eventual PR can catch it in ten seconds. Be concrete enough that a wrong assumption is visibly wrong.

If the issue's stated diagnosis conflicts with what the code shows — the issue says the bug is in the cache layer, the code says it's in the serializer — trust the code, say so explicitly and prominently, and fix the actual root cause **if the fix stays inside the issue's scope**. If fixing the real cause requires changes outside that scope, that is a BLOCK.

## Step 2 — Known unknowns

Enumerate the questions `/spec-planning` would have asked, ordered by architectural blast radius, highest first. Then close every one. For each, record which of CODE / PRECEDENT / DERIVED / BLOCKED closed it and what the evidence was.

Do not skip the enumeration because you can't ask anyone. Naming the question is what surfaces the blast radius; a question you never wrote down is a decision you made without noticing. But keep them real: never enumerate a question the code answers trivially, and never enumerate one a competent engineer would simply decide.

## Step 3 — Unknown knowns: precedent instead of interview

This is the quadrant that mattered most in the interactive version and it is the one that degrades most without a human. Do not skip it — mine it.

The user's tacit decisions are recoverable from four places. Work them deliberately:

1. **The parent spec.** Every preference recorded there for the feature this issue belongs to still applies to this issue unless the issue overrides it. Carry those decisions forward into this spec *verbatim enough that the implementer inherits the decision, not just the outcome* — the same standard `/spec-planning` sets.
2. **The code as built.** The parent PR's actual implementation shows which way ambiguous calls went. Where the code and the parent spec disagree, the code is the later decision; note the divergence.
3. **Convention the code enforces silently.** Error-handling shape, logging, naming, module boundaries, test structure, what gets exported. Match it. An implementation that is technically correct and stylistically foreign is a defect here.
4. **Sibling specs.** What "done" looks like to this user, at what granularity.

For each taste-bearing decision in this spec, cite where the precedent came from. A decision with no precedent citation is a DERIVED decision and must be logged as one.

## Step 4 — Unknown unknowns

Unchanged from `/spec-planning` — this quadrant never needed a human. Sweep the files the task will touch, state what you covered, and report each landmine as a card: evidence with `file:line`, why it bites, what it changes about the task.

Look specifically for: wrong-by-default data, unwritten conventions, and half-built or reverted prior attempts at this same job. A previous attempt that died is the highest-value find on this list, and the reason it died is usually the landmine.

A landmine that only needs awareness goes into the spec as a sharp edge. One that forces a decision closes like a Step 2 question — including, if it qualifies, as a BLOCK.

## The blocking bar

Blocking stops the pipeline and costs the user a round trip, so the bar is high and specific.

**BLOCK when:**
- The decision changes user-facing or API-facing behavior in a way neither the issue nor the parent spec specifies.
- The decision is expensive to reverse: a schema or data migration, a public interface shape, a new runtime dependency, a change to an auth or permissions boundary.
- The issue materially contradicts the parent spec or the code, and resolving the contradiction requires knowing which one the user currently wants.
- The issue is underspecified enough that two reasonable readings produce **different acceptance tests**. This is the sharpest form of the test — if you cannot tell what the tests should prove, you cannot TDD it, and guessing wastes an entire implementation cycle.
- Fixing the actual root cause requires work outside the issue's stated scope.

**Do not block for:** naming, internal structure, file placement, error message wording, test granularity, refactor-vs-patch judgment, anything precedent covers, or anything a single follow-up commit could reverse. Decide, log, move on.

When you block, write to `$2` a document whose **first section is `## BLOCKED`**, containing: the specific decision needed, the two or three options with your recommendation and reasoning, what evidence you looked for and where, and exactly what one answer from the user would unblock it. Then write everything you *did* establish below it — a blocked spec should still be 90% finished work. End your final message with `SPEC_STATUS: BLOCKED`.

## Output

Write the spec to `$2`, creating parent directories as needed. The path follows the repo convention `./specs/<version>/<type>/<issue-number>-<slug>.md` and matches the branch name `<version>/<type>/<issue-number>-<slug>` — use exactly the path given in `$2`; do not invent a different one.

The spec must contain, in this order:

- **Scope** — what this issue covers, and an explicit line on what it does not.
- **Known knowns** — settled ground with citations, per Step 1.
- **Implementation** — the actual spec. Architecture, interfaces, data flow, UX where relevant, edge cases, and the taste decisions carried forward from precedent with their citations.
- **Sharp edges** — the landmine cards from Step 4.
- **Derived decisions** — every DERIVED close from Steps 2 and 3, as a table: the question, the answer you chose, why, and how to reverse it. This is the section the human reads first when reviewing the PR, so write it for that reader. It is the audit trail that replaces the interview; if it is thin, you did not enumerate honestly.
- **Deferred** — everything in scope-adjacent territory you found and deliberately did not do, one line each, phrased so it can be filed as a follow-up issue verbatim.
- **Slices** — per `/spec-planning`: break at API/module boundaries, each one reviewable commit, each with acceptance criteria stated as *what the tests must prove* (not test code) and its dependencies on other slices so the implementer can parallelize independent ones. Checkbox per slice.

`/implement-spec` builds test-first, so the acceptance criteria are load-bearing: they become the tests before any implementation exists. State the contract and the edge cases precisely enough that a test can fail on them. **For a bugfix, one acceptance criterion is always a regression test that fails against current `main` and passes after the fix** — say what it asserts.

Do not invent slices for work that is really one commit. If the issue is small, skip the Slices section and let the implementer treat it as a single slice. Most follow-up issues are one or two slices; a five-slice spec for a bug fix means you expanded scope somewhere — go back and find it.

Keep the spec tight. It is read by an implementer and a reviewer, not archived. Length is not evidence of thoroughness; citations are.

End your final message with `SPEC_STATUS: READY`.
