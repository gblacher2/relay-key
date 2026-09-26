import Foundation
import Testing
@testable import RelayKeyCore

@Suite("ProcessCommandRunner")
struct ProcessCommandRunnerTests {
    @Test("Timeout SIGKILLs a SIGTERM-ignoring child and returns failure")
    func timeoutKillsStubbornChild() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-key-timeout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let script = dir.appendingPathComponent("ignore-term")
        let body = """
        #!/usr/bin/env perl
        $SIG{TERM} = 'IGNORE';
        sleep 30;
        exit 0;
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: script.path
        )

        let runner = ProcessCommandRunner()
        let started = ContinuousClock.now
        let outcome = await runner.run(script, arguments: [], timeout: .seconds(1))
        let elapsed = ContinuousClock.now - started

        #expect(outcome.exitCode == 124)
        #expect(elapsed < .seconds(6))
        #expect(elapsed >= .seconds(1))
    }
}
