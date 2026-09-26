import Foundation
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
        let transport = FakeHealthTransport { _ in
            let json = #"{"status":"ok","port":8788}"#
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
            if store.activeAction == nil { break }
            try? await Task.sleep(for: .milliseconds(20))
        }

        #expect(store.activeAction == nil)
        #expect(gate.callCount == 1)
        #expect(store.state == .running(port: 8788))
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
    private let lock = NSLock()
    private var _callCount = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome {
        lock.lock()
        _callCount += 1
        lock.unlock()
        return CommandOutcome(exitCode: 0, stderrSnippet: "")
    }
}

private final class GatedCommandRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _callCount
    }

    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome {
        lock.lock()
        _callCount += 1
        lock.unlock()

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isReleased {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        return CommandOutcome(exitCode: 0, stderrSnippet: "")
    }

    func release() {
        lock.lock()
        isReleased = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}
