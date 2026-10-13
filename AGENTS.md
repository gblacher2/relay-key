# relay-key agent instructions

## Project overview

RelayKey is a macOS 14+ menu bar app for the locally installed `oc-relay`
service. The implementation contract is [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md).

## Architecture

Keep a Foundation and Observation only `RelayKeyCore` library separate from the
SwiftUI and AppKit `RelayKey` executable. The library owns paths, health mapping,
process execution, and observable state. The executable owns the menu, pasteboard,
log opening, and app lifecycle. Inject health and command dependencies for tests.

## Development

The implementer will create the package and `script/build_and_run.sh`. Build with
`swift build`, test with `swift test`, and launch the staged app with
`./script/build_and_run.sh`. The menu requires an existing local `oc-relay` CLI.

## Validation

Run `swift build && swift test` and `./script/build_and_run.sh --verify`. Run the
service health and manual menu checks specified in the implementation plan. Run
`git grep -nIiE '/Users/|sk-[a-z0-9]{8}|bearer |config\.json' -- Sources Tests script`
and expect no matches. A failed required check means the task is not complete.

## Coding conventions

Swift 6 language mode, SwiftPM tools 6.0, macOS 14+, and no dependencies. Keep
the app menu bar only, with the exact labels, symbols, and order in the plan. Add
only UI text required there or for operation and accessibility. Do not commit
absolute home paths or secrets.

## Security

Never access API keys, relay configuration, or LM Studio files. The sole network
call is GET loopback `/health`; decode only `status` and `port`. Run the CLI with
`Process` argument arrays for lifecycle actions only. Do not call its `status` or
`logs` subcommands. `os.Logger` subsystem `local.gabriel.relay-key` records only
state transitions, action names, and exit codes; never log or display captured
stderr.

## GitHub workflow and agent guardrails

- GitHub is the canonical system of record. Record durable decisions, acceptance
  criteria, implementation state, review findings, and validation in the repository,
  Issues, or pull requests rather than only in an AI conversation.
- Meaningful work uses an Issue or equivalent complete PR context, a scoped branch,
  an early draft PR, review comments, verification, and a final `READY FOR HUMAN` state.
- Use `feat/`, `fix/`, `refactor/`, or `chore/` branch prefixes. Do not implement normal
  feature work directly on `main` and do not merge without human authorization.
- Inspect the existing architecture and `git status` before changing files. Preserve
  unrelated local work and prefer minimal, scoped modifications.
- Do not suppress type or lint failures, replace working implementations unnecessarily,
  introduce dependencies without justification, or alter unrelated code.
- Never commit secrets, credentials, `.env` values, personal data, local databases,
  logs, or machine-specific state. Commit reconstruction-safe examples and setup docs.
- Push meaningful checkpoints and keep the PR accurate so a fresh agent can continue
  from GitHub alone.

## CI minutes policy

This repository runs on GitHub Actions with a limited monthly minute quota. Agents must follow these rules.

- Commit work in progress with `[skip ci]` in the message. Never use `[skip ci]` on the final commit of a pull request, or its checks will not run.
- Batch related edits into one push instead of pushing after every change.
- Do not add `on: push` triggers for all branches. Use `workflow_dispatch` for experiments.
- Do not add or change a scheduled workflow without asking Gabriel first.
- Before adding any workflow, state its expected runs per month.
- Keep `concurrency` with `cancel-in-progress: true` on pull request workflows, and use `ubuntu-latest` unless macOS or Windows is required.
