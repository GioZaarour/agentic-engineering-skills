---
description: Given a technical specification file \#$1 or existing plan, enhance the spec/plan.
argument-hint: [spec-file-path]
---

# /review-spec $1

Review this plan/spec thoroughly before making any changes. 

Before you write review feedback or edit the spec, invoke `/clear-technical-writing`. Apply it to the interview text, recommendations, and spec changes. Define project-specific components before you compare their boundaries or data flow.

First, study the codebase in areas relevant to the spec’s scope, if any. start with AGENTS.md as an entry point if available, which should point it to the right places in the code to look. Otherwise, explore the codebase. This is to make sure you make no implicit assumptions or incorrect framings before interviewing me to plan the spec. You should not be bringing up spec improvements for things that may already be implemented or redundant based on a scan of the codebase.

## Respect the implementation contract

This spec is going to be built by the `/implement-spec` command, which reads it in a specific shape. Review and scrutinize freely — that's the job — but stay conscious of that downstream contract as you edit:

- **Don't delete the structural sections; sharpen them.** The spec might have a **Slices** section (slices at API/module boundaries, each one reviewable commit, each with acceptance criteria / test intent and its dependencies on other slices, each with a checkbox), an **Open questions** section, and essential captured design decisions. You may re-slice, re-order, tighten, or rewrite them — but don't strip them out or leave them malformed.
- **Route findings into those structures instead of orphaning them.** A missing edge case → add it to the relevant slice's acceptance criteria / test intent (state what the test must prove, not test code). A risk that needs my decision → an Open question with what unblocks it. A coupling or boundary problem → fix the slice boundaries and their dependency graph. A DRY/test-coverage concern → the affected slice's criteria.
- **Respect the small-spec case.** If the spec has no Slices section it's a single-slice spec by design — don't manufacture slices onto work that's really one commit. Only introduce slicing if the work is genuinely large enough to warrant it, and say why.

## Guidelines for the spec review

For every issue or recommendation, explain the concrete tradeoffs, give me an opinionated recommendation, and ask for my input before assuming a direction.  
My engineering preferences (use these to guide your recommendations):  
- DRY is important—flag repetition aggressively.  
- Well-tested code is non-negotiable; I’d rather have too many tests than too few.  
- I want code that’s “engineered enough” — not under-engineered (fragile, hacky) and not over-engineered (premature abstraction, unnecessary complexity).  
- I err on the side of handling more edge cases, not fewer; thoughtfulness > speed.  
- Bias toward explicit over clever.  

1. Architecture review  
Evaluate:  
- Overall system design and component boundaries.  
- Dependency graph and coupling concerns.  
- Data flow patterns and potential bottlenecks.  
- Scaling characteristics and single points of failure.  
- Security architecture (auth, data access, API boundaries).  

1. Code quality review  
Evaluate:  
- Code organization and module structure.  
- DRY violations—be aggressive here.  
- Error handling patterns and missing edge cases (call these out explicitly).
- Make sure tracing and error handling are robust, especially for newly added features. Use the existing tracing, logging, and error-handling code if it is already in the codebase.
- Technical debt hotspots.  
- Areas that are over-engineered or under-engineered relative to my preferences.  

1. Test review  
Evaluate:  
- Test coverage gaps (unit, integration, e2e).  
- Test quality and assertion strength.  
- Missing edge case coverage—be thorough.  
- Untested failure modes and error paths.  

1. Performance review  
Evaluate:  
- N+1 queries and database access patterns.  
- Memory-usage concerns.  
- Caching opportunities.  
- Slow or high-complexity code paths.  

For each issue you find  
For every specific issue (bug, smell, design concern, or risk):  
- Describe the problem concretely, with file and line references.  
- Present 2–3 options, including “do nothing” where that’s reasonable.  
- For each option, specify: implementation effort, risk, impact on other code, and maintenance burden.  
- Give me your recommended option and why, mapped to my preferences above.  
- Then explicitly ask whether I agree or want to choose a different direction before proceeding.  

Workflow and interaction  
- Do not assume my priorities on timeline or scale.  
- After each section, pause and ask for my feedback before moving on.  

BEFORE YOU START:  
Ask if I want one of two options:  
1/ BIG CHANGE: Work through this interactively, one section at a time (Architecture → Code Quality → Tests → Performance) with at most 3-5 top issues in each section.  
2/ SMALL CHANGE: Work through interactively 1-2 questions per review section  

The options above are *not explicit boundaries* and you should use your own judgement to determine if there are more *or* less issues than the human or this skill file may anticipate.

If there are no issues, there are none. If there are many issues, all major ones should be escalated, no matter how many.

Keep your review in scope.

FOR EACH STAGE OF REVIEW: output the explanation and pros and cons of each stage’s questions AND your opinionated recommendation and why, and then use AskUserQuestion. Also NUMBER issues and then give LETTERS for options and when using AskUserQuestion make sure each option clearly labels the issue NUMBER and option LETTER so the user doesn’t get confused. Make the recommended option always the 1st option.

Once the review is completed, write surgical edits to the existing spec file according to the review findings and my answers.
