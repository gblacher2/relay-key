# relay-key agent instructions

## Project overview

RelayKey is a macOS 14+ menu bar app for the locally installed `oc-relay`
service. The implementation contract is [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md).

## Architecture

Keep a Foundation and Observation only `RelayKeyCore` library separate from the
SwiftUI and AppKit `RelayKey` executable. The library owns paths, health mapping,
safe model-selection readback, process execution, and observable state. The executable owns the menu, pasteboard,
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
the app menu bar only, with the initial labels and order in the plan plus the
`Model (global)` submenu specified in Issue #5. Add
only UI text required there or for operation and accessibility. Do not commit
absolute home paths or secrets.

## Security

Never access API keys, relay configuration, or LM Studio files. The sole network
call is GET loopback `/health`; decode only `status`, `port`, and the safe
`model_selection` capability, catalog, selected ID, and error. Run the CLI with
`Process` argument arrays for lifecycle and typed `model set/clear` actions only.
Do not call its `status` or
`logs` subcommands. `os.Logger` subsystem `local.gabriel.relay-key` records only
state transitions, action names, and exit codes; never log model IDs or display captured
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
