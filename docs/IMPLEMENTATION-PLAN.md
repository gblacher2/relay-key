# RelayKey implementation plan

## Objective

Build a native macOS 14+ menu bar utility to monitor and control the already installed `oc-relay` service. This plan is the implementation contract for the initial PR. A separate review context will review that PR after the implementer finishes.

## Context

- `oc-relay` is a Python CLI at `~/.local/bin/oc-relay` with a `/usr/bin/env python3` shebang.
- Its `status` command exits 1 when stopped and includes recent log lines. The app must never call `status` or `logs`.
- `GET http://127.0.0.1:8788/health` returns JSON with `status`, `port`, and other fields. Decode only `status` and `port`.
- `start` waits about 5 seconds for health. `restart` performs stop then start.
- The development toolchain is Swift 6.4 on macOS 27. The app supports macOS 14+.

## Scope

### Product and menu

- Use SwiftUI `MenuBarExtra` with `.menuBarExtraStyle(.menu)`. No main window or Dock icon. Set `LSUIElement=true` in the staged Info.plist and call `NSApplication.shared.setActivationPolicy(.accessory)` at launch.
- Use SF Symbols and native semantic colors. Every menu label must be under 30 characters. Add no explanatory, promotional, or decorative UI copy.
- Icons: running `bolt.circle.fill`; stopped `bolt.slash.circle`; checking or lifecycle action in progress `arrow.triangle.2.circlepath`; error or missing installation `exclamationmark.triangle`.
- Menu order: disabled status line; Start (visible only when stopped or not installed); Stop and Restart (visible only when running or error); Refresh; Copy Base URL; Open Log; divider; Quit with Command-Q.
- Status line values: `Running · Port 8788` using the health response port, `Stopped`, `Not Installed`, `Checking…`, `Starting…`, `Stopping…`, `Restarting…`, `Relay Unhealthy`, and `Start Failed · Exit N` with the same pattern for Stop and Restart.
- Disable lifecycle controls while an action runs, and in `notInstalled` or `checking`. Disable Refresh while an action runs. Keep Copy Base URL enabled. Disable Open Log when the log file does not exist.

### Package layout

SwiftPM with `swift-tools-version: 6.0`, Swift 6 language mode, and no dependencies:

```text
Sources/RelayKeyCore/Models/RelayStatus.swift
Sources/RelayKeyCore/Services/RelayController.swift
Sources/RelayKeyCore/Stores/RelayStore.swift
Sources/RelayKeyCore/Support/Paths.swift
Sources/RelayKey/App/RelayKeyApp.swift
Sources/RelayKey/Views/RelayMenu.swift
Tests/RelayKeyCoreTests/RelayStoreTests.swift
script/build_and_run.sh
.codex/environments/environment.toml
```

`RelayKeyCore` is a Foundation and Observation only library target. `RelayKey` is the SwiftUI and AppKit executable target. `RelayKeyCoreTests` uses Swift Testing. Keep the split so the tests can import logic without the `@main` app.

### Types and behavior

- `Paths` is a `Sendable` struct initialized with `home: URL = FileManager.default.homeDirectoryForCurrentUser`. Its URLs are `home/.local/bin/oc-relay`, `home/Library/Logs/oc-relay.log`, `http://127.0.0.1:8788`, and that base URL plus `/health`. Never commit an absolute home path.
- `RelayState: Equatable, Sendable` has `checking`, `running(port: Int)`, `stopped`, `notInstalled`, `unhealthy`, and `actionFailed(RelayAction, exitCode: Int32)` cases. `RelayAction: String, Sendable` has `start`, `stop`, and `restart`; raw values are CLI arguments. Pure helpers map state/action to status line and icon name.
- `HealthTransport: Sendable` provides `get(_ url: URL) async throws -> (Data, Int)`. The live implementation uses an ephemeral `URLSession`, 2-second request timeout, no cache, and `connectionProxyDictionary = [:]`.
- `CommandRunning: Sendable` provides `run(_ executable: URL, arguments: [String], timeout: Duration) async -> CommandOutcome`. The outcome holds an `Int32` exit code and a bounded stderr snippet.
- The live `ProcessCommandRunner` uses `Process.executableURL` set to the CLI and `arguments = [action.rawValue]`; never invoke a shell or interpolate a command string. Set standard input to `FileHandle.nullDevice`. Drain stdout and stderr concurrently through pipe readability handlers, retaining at most 8 KB of each and discarding excess so output cannot block the child. Resume through the termination handler and terminate after 30 seconds. Inherit the environment while ensuring PATH includes `/usr/bin:/bin:/usr/sbin:/sbin` for the CLI shebang and `launchctl`.
- `RelayController.currentState()` checks whether the CLI is executable and returns `notInstalled` if not. Otherwise GET `/health`: HTTP 200 with JSON `status == "ok"` yields `running(port)`; `URLError.cannotConnectToHost`, `timedOut`, `networkConnectionLost`, and `cannotFindHost` yield `stopped`; all other errors, non-200 responses, bad JSON, or other status values yield `unhealthy`. Decode only `status` and `port`. `perform(_:)` runs the CLI action.
- `@MainActor @Observable final class RelayStore` owns `state`, `activeAction`, derived status/icon/button enablement, and a refresh generation counter. `perform(_:)` returns synchronously when an action is already active or the CLI is not installed. Set `activeAction` before awaiting the controller so repeated clicks cannot overlap. Clear it after the command. On a nonzero exit, show `actionFailed`; preserve that failure through automatic polling until the user chooses Refresh or another action. Do an immediate health refresh after each action without letting it erase a just recorded failure. Ignore late health responses whose generation is stale.
- `refresh()` skips during an action. `startPolling()` starts one cancellable task that calls refresh then sleeps 5 seconds in a loop. Call it once at app launch.
- `RelayKeyApp` creates the store with live dependencies in `init`, starts polling, sets accessory activation, and uses the store icon as the `MenuBarExtra` image.
- `RelayMenu` contains the controls. Copy Base URL clears `NSPasteboard.general` and writes exactly `http://127.0.0.1:8788`. Open Log calls `NSWorkspace.shared.open(paths.logURL)`. Quit calls `NSApplication.shared.terminate(nil)`.

### Security

- Never read, store, display, log, or transmit an API key. Never read the relay configuration or LM Studio files. Hardcode port 8788.
- The sole network call is GET to loopback `/health`.
- Never invoke `oc-relay status` or `oc-relay logs` from the app.
- `os.Logger` with subsystem `local.gabriel.relay-key` records only state transitions, action names, and exit codes. Do not log or display captured stderr.
- Do not modify the relay repository, its configuration, its LaunchAgent, or LM Studio files.

### Focused tests

Use injected fakes and one suite with four tests:

1. Healthy JSON including extra `pid` and `target_url` fields maps to `running(port: 8788)`.
2. A fake transport throwing `URLError(.cannotConnectToHost)` maps to `stopped`.
3. A temporary home without the CLI maps to `notInstalled`, and store `perform(.start)` does not call the runner.
4. A gated runner suspends until released. Request `perform(.stop)`, `perform(.stop)`, and `perform(.restart)`. Runner call count is one while gated. After release, `activeAction` is nil and a refresh ran.

No SwiftUI rendering tests.

### Build script and environment

- `script/build_and_run.sh` uses bash, `set -euo pipefail`, and is executable.
- Stop a prior RelayKey process with `pkill -x RelayKey`, ignoring the not-running case. Run `swift build`; resolve the binary path with `swift build --show-bin-path`.
- Stage `dist/RelayKey.app/Contents/MacOS/RelayKey` and `Contents/Info.plist`. The plist contains `CFBundleExecutable=RelayKey`, `CFBundleIdentifier=local.gabriel.relay-key`, `CFBundleName=RelayKey`, `CFBundlePackageType=APPL`, `LSMinimumSystemVersion=14.0`, and `LSUIElement=true`. Ad-hoc sign and verify with `codesign --force --sign -` and `codesign --verify`.
- Default launch uses `/usr/bin/open -n dist/RelayKey.app`. `--debug` runs the staged binary under `lldb`. `--logs` launches then streams compact process logs. `--telemetry` launches then streams subsystem `local.gabriel.relay-key`. `--verify` launches and, within 10 seconds, confirms `pgrep -x RelayKey` and `plutil -extract LSUIElement raw dist/RelayKey.app/Contents/Info.plist` returns true; otherwise exit nonzero.
- Create `.codex/environments/environment.toml` in the format of the neighboring `codex-provider-switcher` project, with `name = "relay-key"` and a Run action `./script/build_and_run.sh`.
- Fill repository `AGENTS.md` sections for overview, architecture, development, validation, conventions, and security. Keep README minimal: build/run and the `oc-relay` dependency.

## Acceptance criteria

- [ ] Menu bar only, without Dock icon or window; exact specified icons and menu items; labels under 30 characters.
- [ ] Status refreshes every 5 seconds and immediately after actions; the menu stays responsive during actions.
- [ ] Repeated clicks cannot overlap lifecycle commands; lifecycle controls are disabled during actions.
- [ ] Missing CLI shows Not Installed, disables lifecycle commands, and does not crash.
- [ ] CLI launch uses Process with an argument array, no shell, and bounded output capture.
- [ ] Only loopback `/health` is called; no config or key access; no absolute home path is committed.
- [ ] Four focused tests pass and CI is green.
- [ ] Build script supports `--debug`, `--logs`, `--telemetry`, `--verify`; environment Run action exists.

## Verification

Run all and place concise actual output in the draft PR:

1. `swift build && swift test`
2. `./script/build_and_run.sh --verify`
3. `~/.local/bin/oc-relay status` — report only Service and Health lines, never log lines.
4. `curl --fail --silent http://127.0.0.1:8788/health` — inspect locally, but do not publish fields beyond status and port.
5. `git grep -nIiE '/Users/|sk-[a-z0-9]{8}|bearer |config\.json' -- Sources Tests script` — expect no matches.
6. Manual flow: Running → Stop → Stopped → Start → Running → Restart → Running → Copy Base URL; `pbpaste` must equal `http://127.0.0.1:8788`; Open Log opens `~/Library/Logs/oc-relay.log`; no API key appears in app state, output, logs, tests, commits, or PR text. Leave relay Running.

If menu bar interaction cannot be automated, identify the exact unverified manual steps in the PR under Known Limitations. Do not claim them as passed.

## Constraints

- Implement on `feat/menu-bar-control` from `main` with an early draft PR linked to the Issue. Commit and push sensible checkpoints. Keep the PR draft pending independent review.
- The implementer is Claude. Return material architecture or scope questions in the PR rather than changing this plan unilaterally.
- Follow repository and workspace instructions, including risk-based testing and source review before commits.

## Out of scope

- Modifying or reinstalling `oc-relay`, its config, LaunchAgent, or LM Studio.
- Reading API keys or relaying model requests.
- Additional windows, Dock UI, settings, extra UI copy, tests of SwiftUI rendering, or merge/deployment.

## Review focus

Review the full diff, linked Issue, commits, and CI in a separate context. Check the package split and paths; synchronous main-actor overlap guard; Process argument array, concurrent bounded pipe drains, and timeout; health mapping; secret and config boundaries; exact menu labels; staged plist and script flags; and whether the four tests exercise the intended failure modes. Run `swift test` and the verify script locally if available. Leave GitHub review findings inline where possible using P0–P3, and report blockers and unverified criteria. Do not modify code or merge.
