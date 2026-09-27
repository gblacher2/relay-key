# relay-key

RelayKey is a macOS 14+ menu bar controller for an existing local `oc-relay`
service. Implementation is planned in [docs/IMPLEMENTATION-PLAN.md](docs/IMPLEMENTATION-PLAN.md).

After implementation, build with `swift build`, test with `swift test`, and run
the staged app with `./script/build_and_run.sh`. The service CLI is expected at
`~/.local/bin/oc-relay`.

See the [RelayKey user guide](docs/USER-GUIDE.html) for menu controls and troubleshooting.

The `Model (global)` menu requires the `oc-relay` model-selection capability
tracked in [Issue #5](https://github.com/gblacher2/relay-key/issues/5).
It changes the model for future Chat Completions requests made through this
relay and does not edit LM Studio's Custom Model field or API key.
