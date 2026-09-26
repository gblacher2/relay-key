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
/// Exit code reported when the runner stops a child for exceeding its timeout.
private let commandTimeoutExitCode: Int32 = 124
/// Grace period after SIGTERM before escalating to SIGKILL.
private let timeoutKillGraceSeconds: Double = 2

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
            let timeoutControl = TimeoutControl(
                process: process,
                graceSeconds: timeoutKillGraceSeconds
            )

            process.terminationHandler = { finished in
                let timedOut = timeoutControl.didTimeOut
                timeoutControl.cancel()
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                completion.resume(
                    CommandOutcome(
                        exitCode: timedOut ? commandTimeoutExitCode : finished.terminationStatus,
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

/// Soft-timeout → SIGTERM, then hard-timeout → SIGKILL, without capturing
/// non-Sendable DispatchWorkItem across Process.terminationHandler's @Sendable boundary.
///
/// `finished` coordinates timer items with `terminationHandler`/`cancel()` so kill(2)
/// is only attempted while the child may still be alive. `timedOut` is sticky so the
/// runner can resume with a timeout failure even if the child later exits "normally".
private final class TimeoutControl: @unchecked Sendable {
    private let lock = NSLock()
    private let process: Process
    private let graceSeconds: Double
    private var softItem: DispatchWorkItem?
    private var hardItem: DispatchWorkItem?
    private var finished = false
    private var timedOut = false

    init(process: Process, graceSeconds: Double) {
        self.process = process
        self.graceSeconds = graceSeconds
    }

    func schedule(after seconds: Double) {
        let item = DispatchWorkItem { [weak self] in
            self?.onSoftTimeout()
        }
        lock.lock()
        softItem = item
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: item)
    }

    var didTimeOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOut
    }

    func cancel() {
        lock.lock()
        finished = true
        softItem?.cancel()
        softItem = nil
        hardItem?.cancel()
        hardItem = nil
        lock.unlock()
    }

    private func onSoftTimeout() {
        let hard: DispatchWorkItem?
        lock.lock()
        softItem = nil
        if finished || !process.isRunning {
            lock.unlock()
            return
        }
        timedOut = true
        signalIfRunning(SIGTERM)
        let item = DispatchWorkItem { [weak self] in
            self?.onHardTimeout()
        }
        hardItem = item
        hard = item
        lock.unlock()
        if let hard {
            DispatchQueue.global().asyncAfter(deadline: .now() + graceSeconds, execute: hard)
        }
    }

    private func onHardTimeout() {
        lock.lock()
        defer { lock.unlock() }
        hardItem = nil
        guard !finished else { return }
        timedOut = true
        signalIfRunning(SIGKILL)
    }

    /// Caller must hold `lock`.
    private func signalIfRunning(_ signal: Int32) {
        let pid = process.processIdentifier
        guard pid > 0, process.isRunning else { return }
        // kill(2) returns ESRCH if the child already exited; unlike Process.terminate(),
        // it does not raise an Obj-C exception.
        kill(pid, signal)
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
