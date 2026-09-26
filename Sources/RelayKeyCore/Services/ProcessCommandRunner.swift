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

            let drains = PipeDrainState()
            attachDrain(pipe: stdoutPipe, into: drains, isStdout: true)
            attachDrain(pipe: stderrPipe, into: drains, isStdout: false)

            let completion = OnceContinuation(continuation)
            let timeoutSeconds = Double(timeout.components.seconds)
                + Double(timeout.components.attoseconds) / 1e18
            let timeoutControl = TimeoutControl(process: process)

            process.terminationHandler = { finished in
                timeoutControl.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                completion.resume(
                    CommandOutcome(
                        exitCode: finished.terminationStatus,
                        stderrSnippet: drains.stderrString()
                    )
                )
            }

            do {
                try process.run()
                timeoutControl.schedule(after: timeoutSeconds)
            } catch {
                timeoutControl.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                completion.resume(CommandOutcome(exitCode: 127, stderrSnippet: ""))
            }
        }
    }

    private func attachDrain(
        pipe: Pipe,
        into state: PipeDrainState,
        isStdout: Bool
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            state.append(data, isStdout: isStdout)
        }
    }
}

/// Cancels a scheduled terminate without capturing non-Sendable DispatchWorkItem
/// across Process.terminationHandler's @Sendable boundary.
///
/// `finished` coordinates the timeout item with `terminationHandler`/`cancel()`
/// under one lock so `terminate()` is never called after the process has already
/// exited (which raises an uncatchable Obj-C `NSInvalidArgumentException`).
private final class TimeoutControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private var workItem: DispatchWorkItem?
    private var finished = false

    init(process: Process) {
        self.process = process
    }

    func schedule(after seconds: Double) {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard !self.finished else { return }
            self.finished = true
            self.workItem = nil
            // Prefer kill(2) over Process.terminate(): the latter raises an
            // uncatchable NSInvalidArgumentException if the child already exited
            // between isRunning and the call. kill returns ESRCH instead.
            let pid = self.process.processIdentifier
            if pid > 0, self.process.isRunning {
                kill(pid, SIGTERM)
            }
        }
        lock.lock()
        workItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    func cancel() {
        lock.lock()
        finished = true
        workItem?.cancel()
        workItem = nil
        lock.unlock()
    }
}

private final class OnceContinuation: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandOutcome, Never>?

    init(_ continuation: CheckedContinuation<CommandOutcome, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: CommandOutcome) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: outcome)
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
