import Foundation

public struct CommandOutcome: Sendable {
    public let exitCode: Int32
    public let stderrSnippet: String

    public init(exitCode: Int32, stderrSnippet: String) {
        self.exitCode = exitCode
        self.stderrSnippet = stderrSnippet
    }
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome
}

private let commandCaptureLimit = 8 * 1024

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        _ executable: URL,
        arguments: [String],
        timeout: Duration
    ) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice

            var environment = ProcessInfo.processInfo.environment
            let requiredPath = "/usr/bin:/bin:/usr/sbin:/sbin"
            if let existing = environment["PATH"], !existing.isEmpty {
                environment["PATH"] = existing + ":" + requiredPath
            } else {
                environment["PATH"] = requiredPath
            }
            process.environment = environment

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            let state = PipeDrainState()
            attachDrain(pipe: stdoutPipe, into: state)
            attachDrain(pipe: stderrPipe, into: state, isStdout: false)

            let timeoutSeconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            let timeoutItem = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                }
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + timeoutSeconds,
                execute: timeoutItem
            )

            process.terminationHandler = { finished in
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    returning: CommandOutcome(
                        exitCode: finished.terminationStatus,
                        stderrSnippet: state.stderrString()
                    )
                )
            }

            do {
                try process.run()
            } catch {
                timeoutItem.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(
                    returning: CommandOutcome(exitCode: 127, stderrSnippet: "")
                )
            }
        }
    }

    private func attachDrain(
        pipe: Pipe,
        into state: PipeDrainState,
        isStdout: Bool = true
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.append(data, isStdout: isStdout)
        }
    }
}

private final class PipeDrainState: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func append(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout {
            append(data, to: &stdout)
        } else {
            append(data, to: &stderr)
        }
    }

    func stderrString() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: stderr, encoding: .utf8) ?? ""
    }

    private func append(_ data: Data, to buffer: inout Data) {
        let remaining = commandCaptureLimit - buffer.count
        guard remaining > 0 else { return }
        if data.count <= remaining {
            buffer.append(data)
        } else {
            buffer.append(data.prefix(remaining))
        }
    }
}
