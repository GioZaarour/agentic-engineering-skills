---
description: Given a technical specification file \#$1 or task description, enhance the spec by mapping its unknowns and interviewing the user in depth, then write the changes to the same file.
argument-hint: [spec-file-path]  
---

# /spec-planning $1

Before you interview the user or edit the spec, invoke `/clear-technical-writing`. Apply it to questions and the ecommendations. Define project-specific components before you ask the user to compare or choose between them.

Read the file @$1, then study the codebase in the areas the spec touches. Start with AGENTS.md as an entry point if available — it should point you to the right places to look; otherwise explore. Use parallel subagents to split the scan so it lands fast. The goal is to make no implicit assumptions or incorrect framings before interviewing me.

Your main task is to **interview me in detail** to fill in everything the spec is missing — technical implementation, architecture, UI & UX, concerns, tradeoffs, edge cases — and continue until the spec is complete. Keep the questions non-obvious: never ask me what the code can tell you, and never ask what a competent engineer would just decide. Above all, **capture my taste and design decisions** — the choices that aren't derivable from the code and would otherwise be lost. This is the point of the exercise.

Structure the interview as a walk through the four quadrants of what's unknown. Work them in order, but disclose any finding that bears on a decision in flight the moment you have it — don't hold it for its turn.

1. **Known knowns — reflect back the settled ground.** Open by stating the request as you understand it plus the facts the codebase pins down, with file citations. Separate what's locked from what you're assuming ("settled unless you say otherwise") so I can correct a wrong framing before we go deep.

2. **Known unknowns — the questions you can name.** Interview me one question at a time, starting with the decision that affects the most components or public behavior. Give your recommended answer as lettered options I can pick in a few characters. Close every question one of three ways: I answer it, the *code* answers it (go read it instead of asking, then show me the question and what you found), or it's recorded as OPEN with what would unblock it. Never dump a wall of questions.

3. **Unknown knowns — extract my taste and tacit decisions.** This is where the design decisions live, and it's the part that matters most to me. Probe deliberately for what I wouldn't think to volunteer: who consumes this, where it runs, what "done" looks like to whoever inherits it, and the aesthetic/design/API choices I have opinions on but haven't stated. When you can, hand me something concrete to react to rather than asking me to describe it in the abstract — reacting surfaces taste that a "what do you want?" never will. Every preference I express goes into the spec verbatim enough that an implementer inherits the decision, not just the outcome.

4. **Unknown unknowns — find hidden risks.** Sweep the files the task will touch and state what you covered. Look for wrong-by-default data, unwritten conventions the code enforces, and incomplete or reverted prior attempts at this work. A prior attempt can show which constraint stopped the work. Report each risk with `file:line` evidence, its effect, and the required spec change. A finding that needs my decision closes like a stage-2 question; one that only needs awareness goes into the spec as a risk or constraint.

Be very in-depth and keep interviewing me continually until every named question is closed, my taste and design decisions are captured, and the sweep is done. Then write the enhanced spec back to @$1 — including an **Open questions** section for anything left OPEN, each with what would unblock it.

## Slicing the spec for implementation

The spec feeds an implementer (the `/implement-spec` command) that builds test-first, one committable slice at a time. So, when the work is large enough to warrant it, end the spec with a **Slices** section:

- Break the work at API/module boundaries into slices, each small enough to be one reviewable commit.
- For each slice give: its **acceptance criteria / test intent** (what must be true — the contract and key edge cases the implementer will turn into tests; don't write the test code, state what the tests must prove), and its **dependencies** on other slices (so the implementer can parallelize the independent ones).
- Add a checkbox per slice so implementation progress can be tracked in-place.

Do **not** invent slices for work that's really one commit. If the spec is small, skip the Slices section entirely — the implementer treats a spec with no slices as a single slice. Only slice when the size genuinely calls for it.
