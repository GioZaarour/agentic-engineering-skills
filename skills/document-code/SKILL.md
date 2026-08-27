---
description: Add documenting comments to code so a future engineer understands what each part does in the machine — file summaries, and comments on structs, objects, functions, traits, conditionals. Explains the function of the parts and the business logic they encode, not the line-by-line syntax.
---

# /document-code

Before you write or revise comments, invoke `/clear-technical-writing`. Apply it to every comment and docstring you add. Preserve exact code identifiers, but define internal terms for a competent engineer who is new to the codebase.

Write documenting comments that tell what each piece does **in the machine**. Add a file summary at the top of each file, and comments on structs, objects, conditionals, functions, traits, and the like.

Put comments where an engineer would stop and ask *"what does this code do, exactly?"* — an engineer can read the code, but when it sits on many layers of abstraction they often can't tell what its **function** is. So don't narrate what a line does in its specifics; state what the function of the part is.

Comments must also explain **business logic in the context of the software itself.** If the code defines a rule or convention that isn't obvious from the syntax, say so plainly — "this code does *this* in the software" — so the rule survives even when the reader doesn't reverse-engineer it from the code.

## Boundaries

- Document the code your caller points you at — a diff, a set of files, or the slice just written. If nothing is specified, document the code currently changed in the working tree (`git diff HEAD` plus untracked files). Don't wander into untouched code.
- Document for a reader who is fresh to this code, not for yourself — you are primed by having just written or read it, so comment the things that were obvious to you but won't be to them.
- Explain function and intent, never restate the obvious (`// increment i`). If a comment only echoes the code, drop it.
- Don't touch behavior. This adds comments only — no refactoring, no renames.
- Match the surrounding file's comment style and density; follow the language's doc-comment convention (`///` / `//!` in Rust, `/** */` in C++, etc.).
- IMPORTANT: don't include temporal references in any comments. DO NOT refer to slices/sections from an implementation spec. DO NOT refer to GitHub issue/PR numbers. DO NOT refer to specs. 
- IMPORTANT: don't use temporal language in comments. 
- Here is an example of what NOT to say: "§8.3 in the spec asserted that a valid VST should never crash the engine, so now we do ____". This is 1) a temportal reference to a slice from a spec, and 2) temporal language that speaks as if there was a previous state and there is now a new state in the code (using the word "now"). Code explanations should be *absolute*, and if they are overwritten due to a code change, the comment should be overwritten *absolutely* to be as explainable as possible for what an engineer *sees in front of them.*
