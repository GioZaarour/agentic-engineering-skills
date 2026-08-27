---
name: clear-technical-writing
description: Write or revise human-facing software engineering text for competent engineers who are new to the codebase. Use for code comments and docstrings, repository documentation, PR descriptions, PR reviews, review comments, and engineering reports. Do not apply these rules to source code, identifiers, raw tool output, quoted text, or private reasoning.
---

# /clear-technical-writing

Write clear technical English for software engineering. Preserve the technical meaning. Make that meaning accessible to a competent software engineer who is new to this codebase.

This skill adapts useful ideas from ASD-STE100 and the Google developer documentation style guide. It is not ASD-STE100 and does not claim compliance with that standard. Software documentation needs project terms, API names, code identifiers, and language-specific vocabulary that the ASD-STE100 dictionary does not cover.

## Scope

Apply this skill to text that a person will read as engineering communication:

- Inline comments, file comments, docstrings, and generated API documentation.
- Design notes and review documents.
- `README.md`, `AGENTS.md`, runbooks, migration guides, and other repository documentation.
- PR descriptions, PR reviews, PR comments, commit messages, and engineering reports.

Do not apply this writing style to:

- Source code, identifiers, schemas, or protocol fields.
- Commands, paths, exact error messages, raw logs, test fixtures, or tool output.
- Text quoted from a user or source, unless the task is to edit that text.
- Private analysis or tool instructions that people will not read as part of the result.

Do not rewrite an unrelated existing document only to make its style match this skill. Apply the skill to text within the task's scope.

## Audience and order

Assume that the reader is a competent software engineer who does not know this codebase. The reader understands standard software concepts, but does not know the project's components, internal names, or unwritten conventions.

Use this order:

1. State the outcome, decision, or risk.
2. Give the context that the reader needs.
3. Explain the mechanism.
4. Explain why it matters.
5. Give the next action, if there is one.

Put the most important information first in the document, section, paragraph, and sentence.

## Introduce before you reference

Do not use an internal term until you identify what it is and what it does. A code-formatted symbol does not explain itself.

At first use:

1. Give the plain-language role.
2. Give the exact code name, if the name helps the reader find the implementation.
3. Define any related internal object before you describe how the objects interact.

After the first use, use the same term for the same concept. Do not rotate through synonyms for variety.

Bad:

> The scheduler forwards the job spec to the executor, where it becomes a run graph.

Clear:

> The `Scheduler` decides which queued job runs next. It sends a `JobSpec` object to the `Executor`. A `JobSpec` describes one job and its resource limits. The `Executor` converts the specification into a `RunGraph`, which lists the tasks and their dependencies.

Do not front-load definitions that the reader does not need yet. Introduce each term immediately before, or as, you first use it.

## Use one term for one concept

- Use the project's established term when it is accurate.
- Preserve the spelling and capitalization of code identifiers.
- Define project-specific abbreviations on first use. Avoid an abbreviation that appears only a few times.
- Replace an ambiguous pronoun with the noun. A sentence such as "It sends it there" makes the reader reconstruct the actors.
- Add a descriptive noun after a code element when needed: the `config.yaml` file, the `POST` request, the `UserStore` class.
- Do not turn a code name into an English verb. Write "send a `POST` request," not "POST the data," unless the short form is the established language of the audience.
- Use precise, established engineering terms when they are clearer than a longer substitute. Terms such as race condition, transaction, and idempotent can be correct. Define an uncommon or project-specific use.

## Prefer simple words and concrete verbs

Use the shortest familiar word that preserves the exact meaning. Prefer verbs that name an observable action.

Use these replacements when the simpler word is accurate:

| Avoid | Prefer |
|---|---|
| facilitate | help, allow |
| leverage, utilize | use |
| orchestrate | call, run, coordinate |
| instantiate | create |
| perform validation | validate |
| make a determination | decide |
| provide visibility into | show |
| surface an error | report or show an error |
| execute the logic | run the check or call the function |
| is responsible for handling | handles |

Do not replace a precise term with a simple but inaccurate word. For example, use "call the constructor" when construction behavior matters. Do not use "instantiate" only to sound technical.

Avoid vague nouns such as solution, flow, process, logic, handler, manager, payload, and context when a more specific noun is available. If one of these words is the actual project term, define what it contains or does.

Describe software behavior, not human intention or emotion. Write "the service rejects an expired token," not "the service does not like old tokens." A component can select, compare, accept, or reject when those verbs describe its actual operation.

## Remove unnecessary abstraction and figurative language

Name the component, action, data, or risk directly. Do not use a metaphor as a substitute for an explanation.

Avoid phrases such as:

- load-bearing, blast radius, belt and suspenders, happy path, landmine
- architectural spine, seam, substrate, glue, gate, plumbing
- move the needle, low-hanging fruit, under the hood, magic, silver bullet

Use one of these phrases only when it is an established domain term and the literal alternative would be less accurate. Explain the concrete meaning on first use.

Bad:

> This adapter seam orchestrates provider instantiation and limits the blast radius.

Clear:

> Add a `PaymentProvider` interface between checkout and Stripe. Tests can replace Stripe with a fake provider. Create the Stripe provider when the application starts. This boundary keeps Stripe-specific code out of checkout.

## Build short, direct sentences

- Write one main idea per sentence.
- Aim for no more than 20 words in an instruction and 25 words in descriptive text. Split a longer sentence when it carries more than one idea. Do not remove necessary words only to meet a count.
- Prefer subject-verb-object order. Keep the subject and verb near the start.
- Use active voice when the actor matters. Name the person, component, service, or command that acts.
- Use passive voice only when the actor is unknown, irrelevant, or less important than the result.
- Use present tense for current behavior. Use future tense only for an actual future event.
- Prefer positive statements. State what the system does before exceptions or prohibitions.
- Avoid stacked noun phrases. If more than two nouns modify another noun, rewrite the phrase or define a shorter project term.
- Avoid semicolons, long parenthetical asides, double negatives, and phrasal verbs when a direct alternative exists.

Bad:

> Session token validation failure handling logic facilitates invalid request rejection.

Clear:

> The API validates the session token. It rejects the request when the token is invalid.

## Explain why and show causality

Do not stop after naming a design choice. State the problem it solves, the constraint it preserves, or the failure it prevents.

Bad:

> Use a mutex to serialize access.

Clear:

> Protect the map with a mutex. Two request threads can update the same entry. Without the mutex, one update can overwrite the other.

Use explicit cause-and-effect words such as because, so, when, and therefore. Do not imply causality with proximity alone. Do not claim that a change "ensures," "guarantees," or "prevents" an outcome unless the evidence supports that absolute claim.

## Write procedures for action

- Use a numbered list when order matters. Use bullets when order does not matter.
- Put one action in each step unless two small actions must occur together.
- Start each step with an imperative verb: Run, Open, Select, Add, Remove.
- Put the condition, location, or goal before the action. This order lets readers skip steps that do not apply.
- State what a command does instead of writing only "run the following command."
- Explain placeholders before the reader must replace them.
- State the result after the action when the result helps the reader continue.
- Mark optional steps with `Optional:` at the start.
- Use a note for information, not for a required action.
- Use a warning only for a concrete risk. Name what is at risk, the possible result, and the safe action.

Bad:

> Run `bin/migrate` if the database schema is older than version 12.

Clear:

> If the database schema is older than version 12, run `bin/migrate`. The command applies the missing schema changes.

## Organize for scanning

- Give each paragraph one topic. Use a short paragraph; five or six sentences is usually enough.
- Use descriptive, sentence-case headings. Start task headings with a verb. Use a noun phrase for a concept heading.
- Introduce a list or table when its purpose is not clear from the heading.
- Keep list items parallel. Start comparable items with the same part of speech.
- Use descriptive link text that makes sense without the surrounding sentence. Do not use "click here."
- Format code identifiers, filenames, commands, fields, and literal values as code.
- Do not rely on position, color, or an image alone. Use labels such as "the preceding diagram" or the element's visible name.
- Give each meaningful image concise alt text and explain its new information in the surrounding text.
- Avoid relative time words such as "currently" and "recently" when a version number or date is more precise.
- Use US English unless the repository or user specifies another form.

## Keep the tone direct and respectful

- Address the reader as "you" when the reader performs an action. Use the imperative for steps.
- Use third person for actions that the software or an end user performs.
- Be conversational, calm, and factual. Do not be cute, promotional, or ceremonial.
- Avoid slang, idioms, humor, cultural references, and complex metaphors.
- Use inclusive terms. Do not use disability, violence, or social identity as a metaphor for software behavior.
- Do not use "please" in routine instructions.
- Do not call a task simple, easy, obvious, trivial, or quick.
- Remove filler such as "please note," "it is important to note," "in order to," and "at this time."
- Do not pre-announce content with phrases such as "This section will discuss." State the content.
- Make objective claims. Include evidence or limits for claims about correctness, security, performance, and cost.

## Apply the rules to engineering artifacts

### Code comments and API documentation

- Explain purpose, behavior, business rules, non-obvious constraints, and failure cases. Do not narrate syntax.
- Start a public symbol's documentation with its purpose. Then describe inputs, outputs, side effects, prerequisites, defaults, and errors that a caller must know.
- For deprecated code, name the replacement and explain what the caller must change.

Bad:

> Orchestrates cache invalidation across dependent services.

Clear:

> Deletes the cached account record, then tells the billing service to reload it. This order prevents billing from reading stale account data.

### Specs and design documents

- Define each component before you describe its relationships.
- Describe data as concrete fields or objects, not only as a "payload" or "context."
- State who owns each action and where state changes.
- Tie each design choice to a requirement, constraint, test, or observed failure.
- Separate facts, decisions, assumptions, risks, and deferred work.
- Use "must" for a requirement, "should" for a recommendation, "can" for an ability, and "might" for a possibility. Avoid "may" when it could mean either permission or possibility.

### PR descriptions and reviews

- Lead with the behavior that changed or the finding that requires action.
- Cite the file, symbol, test, or observed result that supports the statement.
- Explain user or system impact in literal terms.
- Make review comments actionable: state the problem, why it matters, and the smallest acceptable fix.
- Distinguish verified facts from predictions and suggestions.

Bad review comment:

> The retry gate is not load-bearing under concurrent writes.

Clear review comment:

> `saveWithRetry` reads the record version before each write. Two writers can read the same version and both updates can succeed. Compare and update the version in one database statement so that one writer receives a conflict.

## Final check

Before you publish human-facing text, check it from the perspective of an engineer who has not read the code:

- Does the text define each internal component or term before it uses the term?
- Does each concept have one consistent name?
- Is the actor clear in each important sentence?
- Can a concrete verb replace an abstract phrase?
- Does each design choice or instruction explain why it matters?
- Does each paragraph contain one topic and lead with its main point?
- Are claims precise, supported, and limited to what the evidence proves?
- Can the reader act without first reverse-engineering another component?

If clarity conflicts with a rule in this skill, preserve the technical meaning and choose the clearer wording. Follow project-specific writing requirements before this skill, and use this skill before general external style guidance.

## Source basis

This adaptation draws from the [ASD-STE100 Simplified Technical English standard](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) and the [Google developer documentation style guide](https://developers.google.com/style/). It intentionally selects rules that improve software-engineering communication instead of reproducing either source.
