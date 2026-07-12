import Foundation

/// Runs a short-lived helper process (auxiliary ssh commands piggybacking on
/// the ControlMaster socket) off the main thread, with a hard timeout.
/// Plain Foundation Process — never a PTY, never a local shell.
enum AuxProcess {
    struct Output {
        let exitCode: Int32
        let stdout: Data
        let stderr: Data
        let timedOut: Bool

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        var stderrText: String { String(decoding: stderr, as: UTF8.self) }
    }

    /// Spawns `argv` (argv[0] = executable path) and waits for exit, killing
    /// the child after `timeout` seconds (SIGTERM, then SIGKILL one second
    /// later). Cancelling the surrounding task also terminates the child.
    /// When `stdin` is provided it is written to the child and the pipe is
    /// closed (used for `sftp -b -` batch scripts); otherwise stdin is null.
    /// When `environment` is non-nil it replaces the inherited environment
    /// (used to inject an `SSH_ASKPASS` helper for one-time password auth).
    static func run(argv: [String], stdin stdinData: Data? = nil, environment: [String: String]? = nil, timeout: TimeInterval = 5) async -> Output {
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

                    // Drain stderr on a second queue so a full pipe buffer can
                    // never deadlock the child; read stdout here.
                    let errData = LockedData()
                    let errDone = DispatchSemaphore(value: 0)
                    DispatchQueue.global(qos: .utility).async {
                        errData.store(errPipe.fileHandleForReading.readDataToEndOfFile())
                        errDone.signal()
                    }
                    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
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

                    continuation.resume(returning: Output(
                        exitCode: process.terminationStatus,
                        stdout: outData,
                        stderr: errData.value(),
                        timedOut: didTimeOut
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
    }

    /// One-producer/one-consumer handoff for stderr. A semaphore establishes
    /// ordering at runtime, while the lock also makes that synchronization
    /// explicit to Swift's strict-concurrency checker.
    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()

        func store(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
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
