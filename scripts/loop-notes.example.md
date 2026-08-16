<!--
  Copy this to `.loop-notes.md` at your repo root and rewrite it for your
  project. Every stage of the loop — spec, implement, techdebt, review, fix —
  gets this text appended to its prompt, under the machine budget.

  Write it for a competent engineer who has never seen this repo and cannot ask
  you anything. Commands, not adjectives. The things that go here are the ones
  a fresh agent gets wrong: the toolchain that is not on PATH, the suite that
  cannot run headless, the flag that OOMs the box.

  Keep it short. This is not AGENTS.md — the agent reads that too. This is the
  handful of facts that only matter because nobody is watching.
-->

## Build and test

- Install: `pnpm install --frozen-lockfile`
- Build: `pnpm build`
- Unit tests: `pnpm test -- --maxWorkers=2`
- Lint and types: `pnpm lint && pnpm typecheck`
- Rust workspace: `cargo test --workspace`. Source the toolchain first — it is
  not in any shell profile: `source ~/.local/toolchain-env.sh`

Run the unit suite and the linter before you call any slice done.

## What cannot run here

- End-to-end tests (`pnpm test:e2e`) need a browser this host does not have.
  Do not try to install one. Use the unit suite and say in your final message
  which behaviour is therefore unverified.
- Nothing in this repo may talk to the production database. Tests use the
  fixtures in `test/fixtures/`.

## Conventions worth repeating

- Migrations live in `db/migrations/` and are append-only — never edit one that
  has shipped.
- Public API changes need a matching entry in `CHANGELOG.md`.
- Secrets come from `.env.local`, which does not exist on this machine. If a
  task needs one, that is a BLOCK, not a workaround.
