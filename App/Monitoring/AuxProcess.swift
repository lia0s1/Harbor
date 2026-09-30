import Foundation

/// Runs a short-lived helper process (auxiliary ssh commands piggybacking on
/// the ControlMaster socket) off the main thread, with a hard timeout.
/// Plain Foundation Process — never a PTY, never a local shell.
enum AuxProcess {
    struct Output: Sendable {
        enum Stream: String, Sendable, Equatable {
            case stdout
            case stderr
        }

        /// A bounded-output or pipe-read failure.  Kept separate from the
        /// process exit status so callers that need to distinguish an SSH
        /// failure from a local resource limit can do so without parsing text.
        enum Failure: Sendable, Equatable {
            case outputLimitExceeded(Stream)
            case outputReadFailed(Stream)
        }

        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool
        let failure: Failure?

        init(
            exitCode: Int32,
            stdout: Data,
            stderr: Data,
            timedOut: Bool,
            failure: Failure? = nil
        ) {
            self.exitCode = exitCode
            self.stdout = stdout
            self.stderr = stderr
            self.timedOut = timedOut
            self.failure = failure
        }

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }

        var outputLimitExceeded: Bool {
            if case .outputLimitExceeded = failure { return true }
            return false
        }

        var failureDescription: String? {
            switch failure {
            case .outputLimitExceeded(let stream):
                return "Command \(stream.rawValue) exceeded Harbor's output limit."
            case .outputReadFailed(let stream):
                return "Harbor could not read command \(stream.rawValue)."
            case nil:
                return nil
            }
        }
    }

    /// Per-stream caps for short-lived helpers.  A remote peer controls the
    /// output of ssh/sftp commands, so retaining it until EOF must never make
    /// the app's memory usage unbounded.  Limits can be narrowed by a caller
    /// that expects a small reply (for example, a monitoring probe).
    struct OutputLimits: Sendable, Equatable {
        let stdout: Int
        let stderr: Int

        init(stdout: Int = 8 * 1024 * 1024, stderr: Int = 1 * 1024 * 1024) {
            self.stdout = max(0, stdout)
            self.stderr = max(0, stderr)
        }

        static let `default` = OutputLimits()
    }

    /// Spawns `argv` (argv[0] = executable path) and waits for exit, killing
    /// the child after `timeout` seconds (SIGTERM, then SIGKILL one second
    /// later). Cancelling the surrounding task also terminates the child.
    /// When `stdin` is provided it is written to the child and the pipe is
    /// closed (used for `sftp -b -` batch scripts); otherwise stdin is null.
    /// When `environment` is non-nil it replaces the inherited environment
    /// (used to inject an `SSH_ASKPASS` helper for one-time password auth).
    static func run(
        argv: [String],
        stdin stdinData: Data? = nil,
        environment: [String: String]? = nil,
        timeout: TimeInterval = 5,
        outputLimits: OutputLimits = .default
    ) async -> Output {
        guard let executable = argv.first else {
            return Output(exitCode: -1, stdout: Data(), stderr: Data(), timedOut: false)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(argv.dropFirst())
        let inPipe: Pipe?
        if stdinData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inPipe = nil
        }
        // Same environment as the app (SSH_AUTH_SOCK etc.) unless an explicit
        // environment is supplied; BatchMode on the ssh side guarantees no
        // interactive prompts for the inherited case regardless.
        process.environment = environment ?? ProcessInfo.processInfo.environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Shared state touched from three contexts (the spawn queue, the timeout
        // watchdog, and the cancellation handler). All three coordinate through
        // `state.lock`, and only the SPAWN queue ever touches `process` itself —
        // the watchdog and onCancel signal the captured PID instead, so there is
        // no unsynchronized access to the Process object.
        let state = State()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    // If the task was already cancelled before this block ran,
                    // onCancel fired with no PID to signal — so never spawn the
                    // child at all. (Lost-cancellation window #1.)
                    state.lock.lock()
                    let cancelledBeforeRun = state.cancelled
                    state.lock.unlock()
                    if cancelledBeforeRun {
                        continuation.resume(returning: Output(
                            exitCode: -1, stdout: Data(), stderr: Data(), timedOut: false
                        ))
                        return
                    }

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(returning: Output(
                            exitCode: -1, stdout: Data(), stderr: Data(), timedOut: false
                        ))
                        return
                    }

                    // Publish the PID and, atomically, learn whether cancellation
                    // arrived DURING run() (when onCancel saw pid == 0 and could
                    // not act). The single lock serializes this against onCancel,
                    // so exactly one side ends up issuing the kill. (Window #2.)
                    let pid = process.processIdentifier
                    state.lock.lock()
                    state.pid = pid
                    let cancelledDuringRun = state.cancelled
                    state.lock.unlock()
                    if cancelledDuringRun {
                        terminate(pid: pid, state: state)
                    }

                    // Feed stdin off this queue so a child that never reads
                    // cannot block the reaper below; close to signal EOF.
                    if let stdinData, let inPipe {
                        DispatchQueue.global(qos: .utility).async {
                            let handle = inPipe.fileHandleForWriting
                            // A child that dies before reading (e.g. sftp
                            // failing to connect) must surface EPIPE, not
                            // kill the app with SIGPIPE.
                            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
                            try? handle.write(contentsOf: stdinData)
                            try? handle.close()
                        }
                    }

                    let watchdog = DispatchWorkItem {
                        state.lock.lock()
                        state.timedOut = true
                        state.lock.unlock()
                        terminate(pid: pid, state: state)
                    }
                    DispatchQueue.global(qos: .utility).asyncAfter(
                        deadline: .now() + timeout, execute: watchdog
                    )

                    // Drain both pipes incrementally.  Each collector keeps at
                    // most its configured cap; on overflow it terminates the
                    // child, then continues discarding data until EOF so a full
                    // pipe can never block reaping.
                    let outData = BoundedDataCollector(limit: outputLimits.stdout)
                    let errData = BoundedDataCollector(limit: outputLimits.stderr)
                    let errDone = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .utility).async {
                        drain(
                            errPipe.fileHandleForReading,
                            into: errData,
                            stream: .stderr,
                            pid: pid,
                            state: state
                        )
                        errDone.signal()
                    }
                    drain(
                        outPipe.fileHandleForReading,
                        into: outData,
                        stream: .stdout,
                        pid: pid,
                        state: state
                    )
                    process.waitUntilExit()
                    // Mark finished the instant the child is reaped, BEFORE any
                    // further work: past this point the PID may be recycled by the
                    // OS, so the watchdog/onCancel SIGKILL escalation must never
                    // fire. (Closes the wrong-PID kill window.)
                    state.lock.lock()
                    state.finished = true
                    let didTimeOut = state.timedOut
                    state.lock.unlock()

                    errDone.wait()
                    watchdog.cancel()

                    // The stderr reader can still be draining buffered bytes
                    // after waitUntilExit() returns, so fetch the final failure
                    // only after both readers have reached EOF.
                    state.lock.lock()
                    let failure = state.failure
                    state.lock.unlock()

                    let capturedStderr = errData.value()
                    let renderedStderr = stderrWithFailureMarker(
                        capturedStderr,
                        limit: outputLimits.stderr,
                        failure: failure
                    )

                    continuation.resume(returning: Output(
                        // A process may exit 0 in the small window between an
                        // overflow being observed and SIGTERM delivery.  Make
                        // resource-limit failures non-successful for existing
                        // callers that only check the status code.
                        exitCode: failure == nil ? process.terminationStatus : -1,
                        stdout: outData.value(),
                        stderr: renderedStderr,
                        timedOut: didTimeOut,
                        failure: failure
                    ))
                }
            }
        } onCancel: {
            // Record the cancellation and, if the child is already spawned and
            // not yet reaped, reap it by its captured PID. If it hasn't spawned
            // yet (pid == 0), the spawn queue will observe `cancelled` and act.
            state.lock.lock()
            state.cancelled = true
            let pid = state.pid
            let finished = state.finished
            state.lock.unlock()
            guard !finished, pid > 0 else { return }
            terminate(pid: pid, state: state)
        }
    }

    /// Shared, lock-protected coordination state. `@unchecked Sendable` because
    /// every field is only ever read/written under `lock`.
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var pid: pid_t = 0
        /// Child reaped (terminationStatus available); PID may now be recycled.
        var finished = false
        /// The surrounding task was cancelled.
        var cancelled = false
        /// The watchdog fired before the child exited.
        var timedOut = false
        /// First terminal reader failure wins; callers get a stable, typed
        /// reason even if both pipes become oversized concurrently.
        var failure: Output.Failure?
    }

    /// Lock-protected, bounded stream collector.  It retains only the first
    /// `limit` bytes and then keeps draining/discarding data until EOF.
    private final class BoundedDataCollector: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var exceeded = false

        init(limit: Int) {
            self.limit = limit
        }

        /// Returns false once this stream reached its limit.  The caller must
        /// still continue reading the pipe to avoid deadlocking the child.
        func append(_ value: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !exceeded else { return false }

            let remaining = limit - data.count
            guard value.count <= remaining else {
                if remaining > 0 {
                    data.append(contentsOf: value.prefix(remaining))
                }
                exceeded = true
                return false
            }
            data.append(value)
            return true
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private static let readChunkSize = 64 * 1024

    /// Reads a pipe in bounded chunks.  This must be called for both stdout
    /// and stderr concurrently; otherwise a chatty child could block on the
    /// undrained pipe before its timeout/overflow is observed.
    private static func drain(
        _ handle: FileHandle,
        into collector: BoundedDataCollector,
        stream: Output.Stream,
        pid: pid_t,
        state: State
    ) {
        do {
            while let chunk = try handle.read(upToCount: readChunkSize), !chunk.isEmpty {
                if !collector.append(chunk) {
                    recordFailure(.outputLimitExceeded(stream), pid: pid, state: state)
                }
            }
        } catch {
            // A read error would otherwise leave the other side of the pipe
            // undrained and the reaper blocked forever.  Surface it explicitly
            // and use the same bounded termination path as an overflow.
            recordFailure(.outputReadFailed(stream), pid: pid, state: state)
        }
    }

    /// Records the first failure and terminates the child exactly once for
    /// that condition.  `terminate` itself remains safe to race with timeout
    /// and cancellation, which use the same lock-gated finished state.
    private static func recordFailure(_ failure: Output.Failure, pid: pid_t, state: State) {
        state.lock.lock()
        let shouldTerminate = state.failure == nil && !state.finished
        if state.failure == nil {
            state.failure = failure
        }
        state.lock.unlock()
        if shouldTerminate {
            terminate(pid: pid, state: state)
        }
    }

    /// Existing callers already surface stderr on failure.  Preserve that
    /// behavior while reserving a clear diagnostic for an output cap/read
    /// failure; the returned Data still stays within the configured cap.
    private static func stderrWithFailureMarker(
        _ stderr: Data,
        limit: Int,
        failure: Output.Failure?
    ) -> Data {
        guard let failure else { return stderr }
        let text: String
        switch failure {
        case .outputLimitExceeded(let stream):
            text = "[Harbor] Command \(stream.rawValue) exceeded the output limit.\n"
        case .outputReadFailed(let stream):
            text = "[Harbor] Could not read command \(stream.rawValue).\n"
        }
        let marker = Data(text.utf8)
        guard limit > 0 else { return Data() }
        if marker.count >= limit { return Data(marker.prefix(limit)) }
        let keep = min(stderr.count, limit - marker.count)
        var result = Data(stderr.prefix(keep))
        result.append(marker)
        return result
    }

    /// SIGTERM the captured PID, then SIGKILL one second later if it still has
    /// not been reaped. Gated on `finished` so a recycled PID is never signalled.
    /// Only ever signals the PID — never touches the `Process` object.
    private static func terminate(pid: pid_t, state: State) {
        guard pid > 0 else { return }
        state.lock.lock()
        let alreadyFinished = state.finished
        state.lock.unlock()
        guard !alreadyFinished else { return }
        kill(pid, SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
            state.lock.lock()
            let finished = state.finished
            state.lock.unlock()
            if !finished { kill(pid, SIGKILL) }
        }
    }
}
