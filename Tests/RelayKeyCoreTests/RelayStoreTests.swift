import Foundation
import os
import Testing
@testable import RelayKeyCore

@Suite("RelayStore")
struct RelayStoreTests {
    @Test("Healthy JSON with extra fields maps to running")
    func healthyJSONMapsToRunning() async {
        let transport = FakeHealthTransport { _ in
            let json = """
            {"status":"ok","port":8788,"pid":12345,"target_url":"http://example.invalid"}
            """
            return (Data(json.utf8), 200)
        }
        let home = makeTempHome(prefix: "healthy")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let controller = RelayController(
            paths: paths,
            health: transport,
            commands: FakeCommandRunner()
        )

        let state = await controller.currentState()
        #expect(state == .running(port: 8788))
        #expect(await controller.currentSnapshot().modelSelection == nil)
    }

    @Test("Cannot connect maps to stopped")
    func cannotConnectMapsToStopped() async {
        let transport = FakeHealthTransport { _ in
            throw URLError(.cannotConnectToHost)
        }
        let home = makeTempHome(prefix: "stopped")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let controller = RelayController(
            paths: paths,
            health: transport,
            commands: FakeCommandRunner()
        )

        let state = await controller.currentState()
        #expect(state == .stopped)
    }

    @Test("Missing CLI maps to notInstalled and perform does not run")
    @MainActor
    func missingCLIDoesNotRun() async {
        let home = makeTempHome(prefix: "missing")
        let paths = Paths(home: home)
        let runner = FakeCommandRunner()
        let controller = RelayController(
            paths: paths,
            health: FakeHealthTransport { _ in
                throw URLError(.cannotConnectToHost)
            },
            commands: runner
        )
        let store = RelayStore(controller: controller, paths: paths)
        await store.refresh()
        #expect(store.state == .notInstalled)

        store.perform(.start)
        #expect(runner.callCount == 0)
        #expect(store.activeAction == nil)
    }

    @Test("Overlapping perform calls share one runner invocation")
    @MainActor
    func overlappingPerformIsSerialized() async {
        let home = makeTempHome(prefix: "gate")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let gate = GatedCommandRunner()
        let healthCalls = OSAllocatedUnfairLock(initialState: 0)
        let transport = FakeHealthTransport { _ in
            let count = healthCalls.withLock { value -> Int in
                value += 1
                return value
            }
            // Distinguish post-action refresh from the initial refresh.
            let port = count == 1 ? 8788 : 9999
            let json = #"{"status":"ok","port":\#(port)}"#
            return (Data(json.utf8), 200)
        }
        let controller = RelayController(
            paths: paths,
            health: transport,
            commands: gate
        )
        let store = RelayStore(controller: controller, paths: paths)
        await store.refresh()
        #expect(store.state == .running(port: 8788))
        #expect(healthCalls.withLock { $0 } == 1)

        store.perform(.stop)
        store.perform(.stop)
        store.perform(.restart)

        #expect(store.activeAction == .stop)
        for _ in 0..<50 {
            if gate.callCount >= 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.callCount == 1)

        gate.release()
        for _ in 0..<50 {
            if store.activeAction == nil && store.state == .running(port: 9999) {
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.activeAction == nil)
        #expect(gate.callCount == 1)
        #expect(healthCalls.withLock { $0 } == 2)
        #expect(store.state == .running(port: 9999))
    }

    @Test("Non-200, bad JSON, and non-ok status map to unhealthy")
    func unhealthyMappings() async {
        let home = makeTempHome(prefix: "unhealthy")
        installFakeCLI(in: home)
        let paths = Paths(home: home)

        let non200 = RelayController(
            paths: paths,
            health: FakeHealthTransport { _ in
                (Data(#"{"status":"ok","port":8788}"#.utf8), 503)
            },
            commands: FakeCommandRunner()
        )
        #expect(await non200.currentState() == .unhealthy)

        let badJSON = RelayController(
            paths: paths,
            health: FakeHealthTransport { _ in
                (Data("not-json".utf8), 200)
            },
            commands: FakeCommandRunner()
        )
        #expect(await badJSON.currentState() == .unhealthy)

        let notOk = RelayController(
            paths: paths,
            health: FakeHealthTransport { _ in
                (Data(#"{"status":"degraded","port":8788}"#.utf8), 200)
            },
            commands: FakeCommandRunner()
        )
        #expect(await notOk.currentState() == .unhealthy)
    }

    @Test("Model choice waits for CLI and health readback while blocking lifecycle actions")
    @MainActor
    func modelChoiceIsConfirmedAndSerialized() async {
        let home = makeTempHome(prefix: "model-choice")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let gate = GatedCommandRunner()
        let healthCalls = OSAllocatedUnfairLock(initialState: 0)
        let transport = FakeHealthTransport { _ in
            let count = healthCalls.withLock { value -> Int in
                value += 1
                return value
            }
            let selected = count == 1 ? "null" : #""mimo-v2.6-flash""#
            let json = #"{"status":"ok","port":8788,"model_selection":{"version":1,"selected":\#(selected),"models":["mimo-v2.6-flash","glm-5.3"],"error":null}}"#
            return (Data(json.utf8), 200)
        }
        let store = RelayStore(
            controller: RelayController(paths: paths, health: transport, commands: gate),
            paths: paths
        )
        await store.refresh()
        #expect(store.canSelectModel)
        #expect(store.modelSelection?.selected == nil)

        store.selectModel("mimo-v2.6-flash")
        store.perform(.stop)
        #expect(store.isSelectingModel)
        #expect(!store.canSelectModel)
        for _ in 0..<50 {
            if gate.callCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(gate.callCount == 1)
        gate.release()
        for _ in 0..<50 {
            if !store.isSelectingModel { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.modelSelection?.selected == "mimo-v2.6-flash")
        #expect(!store.modelSelectionFailed)
        #expect(healthCalls.withLock { $0 } == 2)
    }

    @Test("Failed model command preserves the previous selection")
    @MainActor
    func failedModelChoicePreservesSelection() async {
        let home = makeTempHome(prefix: "model-failure")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let runner = FakeCommandRunner(exitCode: 1)
        let transport = FakeHealthTransport { _ in
            let json = #"{"status":"ok","port":8788,"model_selection":{"version":1,"selected":"glm-5.3","models":["mimo-v2.6-flash","glm-5.3"],"error":null}}"#
            return (Data(json.utf8), 200)
        }
        let store = RelayStore(
            controller: RelayController(paths: paths, health: transport, commands: runner),
            paths: paths
        )
        await store.refresh()
        store.selectModel("mimo-v2.6-flash")
        for _ in 0..<50 {
            if !store.isSelectingModel { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.modelSelectionFailed)
        #expect(store.modelSelection?.selected == "glm-5.3")
        #expect(runner.callCount == 1)
    }

    @Test("A late health refresh cannot undo a confirmed model selection")
    @MainActor
    func staleRefreshCannotUndoModelChoice() async {
        let home = makeTempHome(prefix: "model-stale")
        installFakeCLI(in: home)
        let paths = Paths(home: home)
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let transport = FakeHealthTransport { _ in
            let count = calls.withLock { value -> Int in
                value += 1
                return value
            }
            if count == 2 {
                try? await Task.sleep(for: .milliseconds(200))
            }
            let selected = count >= 3 ? #""mimo-v2.6-flash""# : "null"
            let json = #"{"status":"ok","port":8788,"model_selection":{"version":1,"selected":\#(selected),"models":["mimo-v2.6-flash"],"error":null}}"#
            return (Data(json.utf8), 200)
        }
        let store = RelayStore(
            controller: RelayController(
                paths: paths, health: transport, commands: FakeCommandRunner()
            ), paths: paths
        )
        await store.refresh()
        let pending = Task { await store.refresh() }
        for _ in 0..<50 {
            if calls.withLock({ $0 }) >= 2 { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        store.selectModel("mimo-v2.6-flash")
        for _ in 0..<50 {
            if !store.isSelectingModel { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        await pending.value
        #expect(store.modelSelection?.selected == "mimo-v2.6-flash")
        #expect(!store.modelSelectionFailed)
    }
}

private func makeTempHome(prefix: String) -> URL {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("relay-key-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return home
}

private func installFakeCLI(in home: URL) {
    let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
    try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let cli = bin.appendingPathComponent("oc-relay")
    FileManager.default.createFile(atPath: cli.path, contents: Data("#!/bin/sh\n".utf8))
    try? FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: cli.path
    )
}

private struct FakeHealthTransport: HealthTransport {
    let handler: @Sendable (URL) async throws -> (Data, Int)

    func get(_ url: URL) async throws -> (Data, Int) {
        try await handler(url)
    }
}

private final class FakeCommandRunner: CommandRunning, @unchecked Sendable {
    private let callCountState = OSAllocatedUnfairLock(initialState: 0)
    private let exitCode: Int32

    init(exitCode: Int32 = 0) {
        self.exitCode = exitCode
    }

    var callCount: Int {
        callCountState.withLock { $0 }
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome {
        callCountState.withLock { $0 += 1 }
        return CommandOutcome(exitCode: exitCode, stderrSnippet: "")
    }
}

private final class GatedCommandRunner: CommandRunning, @unchecked Sendable {
    private struct State {
        var callCount = 0
        var continuation: CheckedContinuation<Void, Never>?
        var isReleased = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var callCount: Int {
        state.withLock { $0.callCount }
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome {
        state.withLock { $0.callCount += 1 }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let shouldResumeImmediately = state.withLock { current -> Bool in
                if current.isReleased {
                    return true
                }
                current.continuation = cont
                return false
            }
            if shouldResumeImmediately {
                cont.resume()
            }
        }
        return CommandOutcome(exitCode: 0, stderrSnippet: "")
    }

    func release() {
        let cont = state.withLock { current -> CheckedContinuation<Void, Never>? in
            current.isReleased = true
            let pending = current.continuation
            current.continuation = nil
            return pending
        }
        cont?.resume()
    }
}
