---
description: Clean up technical debt after a coding session.
---

# /techdebt - Technical Debt Cleanup

You are a senior software engineer. After a long coding session, the codebase accumulates cruft. Your job is to systematically find and fix it. Be thorough but conservative — don't refactor working architecture, just clean up the mess.

## Process

Start with AGENTS.md as an entry point if available — it should point you to the right places to look; otherwise explore the codebase.

### 1. Scan for Changes in Scope
First establish exactly which diff you're cleaning.

**If your caller scoped you** to a specific range or set of files — e.g. only the current slice's uncommitted changes — scan *exactly that and nothing wider*:
```
git diff HEAD --stat      # current uncommitted changes (plus any untracked files)
```

**Otherwise** (standalone, ad-hoc cleanup), default to the whole branch since main:
```
git diff main --stat
git log --oneline -20
```

Either way, focus cleanup only on files in that diff. Don't go hunting through untouched code.

### 2. Duplicated / Redundant Code
This is the #1 problem after agent sessions. Look for:
- **Copy-pasted functions** that do the same thing with slight variations. Consolidate into one parameterized version.
- **Duplicate type definitions** or interfaces that emerged from parallel edits.
- **Redundant imports** — same module imported multiple ways, or unused imports left behind.
- **Dead code** — functions, variables, or components that are defined but never called/used anywhere. Verify with grep before deleting.

### 3. Inconsistencies
- **Naming inconsistencies** introduced in new code (e.g., mixing `camelCase` and `snake_case` within the same file/module, or inconsistent naming patterns for similar concepts).
- **Mixed patterns** — e.g., some new code uses async/await while adjacent code uses callbacks for the same API, or raw SQL mixed with ORM calls for similar operations.
- **Inconsistent error handling** — some paths throw, some return null, some use Result types. Align new code with the project's dominant pattern.

### 4. Cleanup Artifacts
- **TODO/FIXME/HACK comments** left by the agent that reference completed work or no longer apply. Remove stale ones; keep legitimate ones.
- **Commented-out code blocks.** If it's in version control, delete it. No "just in case" commented code.
- **Debug/console logging** that shouldn't ship (console.log, print statements, debug flags left on).
- **Leftover test fixtures, mock data, or scratch files** created during development.

### 5. File & Module Hygiene
- **Files that are too long** after accumulating additions. If a file grew significantly, check if it now has distinct responsibilities that should be split.
- **Orphaned files** — new files that were created but are no longer imported or used anywhere.
- **Barrel files / index files** that are out of date (missing new exports, or still exporting deleted modules).

### 6. Dependency Cleanup
- **Unused dependencies** that were added during experimentation but aren't actually used in the final code.
- **Duplicate dependencies** that do the same thing (e.g., both `axios` and `node-fetch` added when only one is needed).

### 7. Type Safety & Correctness (if applicable)
- **`any` types** introduced as shortcuts — replace with proper types where straightforward.
- **Type assertions / casts** that can be removed by fixing the underlying type.
- **Optional chaining on values that are never null** — unnecessary defensive code.

### 8. Test Hygiene
- **Skipped tests** (`.skip`, `xit`, `@pytest.mark.skip`) — either fix them or delete them with a TODO issue.
- **Tests that test nothing** — empty test bodies or assertions that always pass.
- **Test descriptions that don't match** what the test actually verifies.

## Rules

1. **Run the test suite before and after.** If tests pass before and fail after, you broke something. Revert.
2. **Make atomic commits** — one commit per category of cleanup so changes are easy to review and revert. *Exception:* if your caller owns committing (e.g. it will fold your fixes into its own commit), don't commit — apply the fixes to the working tree and report what you changed.
3. **Don't refactor architecture.** This is cleanup, not redesign. If something needs a larger refactor, leave a TODO with a clear description instead.
4. **Don't change public APIs or interfaces** unless they are clearly broken or unused.
5. **When in doubt, leave it.** If removing or changing something might break a consumer you can't see, skip it.
6. **Preserve all existing functionality.** The goal is identical behavior with cleaner code.

## Output

Before you write the final cleanup report, invoke `/clear-technical-writing` and apply it to the report.

When done, provide a summary:
- What you found and fixed (grouped by category)
- What you intentionally left alone and why
- Any remaining TODOs that need human decision-making
- Confirmation that tests still pass
