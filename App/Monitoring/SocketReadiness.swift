import Foundation

/// One session's shared "is the ControlMaster socket up yet?" gate.
///
/// At connect time the monitor, file and system-info services all need to wait
/// for the mux socket to appear (it only exists AFTER auth succeeds). Without
/// this they each spawned their OWN `ssh -O check` poll loop, so connecting fired
/// three independent short-lived ssh processes racing the same socket. They now
/// share this single gate: ONE `ssh -O check` loop, fanned out to all awaiters.
///
/// Reset on session exit so a reconnect re-verifies the (new) master rather than
/// trusting a stale "ready" latch.
@MainActor
final class SocketReadiness {
    private let exec: RemoteExec
    private var ready = false
    private var pollTask: Task<Void, Never>?
    /// Bumped each time a new poll is started (and on reset). A finishing poll
    /// only clears `pollTask` if its captured generation still matches, so a
    /// poll that resumes after its `await` never stomps a newer handle.
    private var pollGeneration = 0
    private let checkTimeout: TimeInterval
    private let retryDelay: TimeInterval

    /// Upper bound on how long the shared poll keeps probing a never-appearing
    /// socket before parking; an awaiter past its own deadline gives up sooner.
    private static let maxPollDuration: TimeInterval = 600

    init(
        destination: String,
        controlSocketPath: String,
        port: Int,
        checkTimeout: TimeInterval = 5,
        retryDelay: TimeInterval = 2
    ) {
        self.exec = RemoteExec(
            destination: destination,
            controlSocketPath: controlSocketPath,
            port: port
        )
        self.checkTimeout = checkTimeout
        self.retryDelay = retryDelay
    }

    /// Suspends until the socket is verified alive, `deadline` passes, or the
    /// CALLER's task is cancelled (returns `false` for the latter two). Cheap:
    /// the suspension is a short in-process flag poll, not a process spawn — the
    /// single shared `pollTask` does the actual `ssh -O check`. Multiple services
    /// awaiting concurrently therefore cost ONE check loop, not one each.
    func waitUntilReady(deadline: Date) async -> Bool {
        if ready { return true }
        startPolling()
        while !Task.isCancelled {
            if ready { return true }
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s, caller-cancellable
        }
        return false
    }

    private func startPolling() {
        guard pollTask == nil, !ready else { return }
        let pollDeadline = Date().addingTimeInterval(Self.maxPollDuration)
        pollGeneration += 1
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, Date() < pollDeadline {
                if self.ready { return }
                let alive = await self.exec.checkSocket(timeout: self.checkTimeout)
                // The await above is a cancellation/suspension point: re-check
                // before touching shared state so a cancelled poll can't clear
                // a newer pollTask handle stored by a racing startPolling().
                if Task.isCancelled { return }
                if alive {
                    self.ready = true
                    self.clearPollTask(generation: generation)
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(self.retryDelay * 1_000_000_000))
            }
            self.clearPollTask(generation: generation)
        }
    }

    /// Clear `pollTask` only if it is still the handle this poll stored, so a
    /// finishing poll never nils a newer one started after it.
    private func clearPollTask(generation: Int) {
        guard generation == pollGeneration else { return }
        pollTask = nil
    }

    /// Forget the verified state and stop the shared poll. Called when the
    /// session exits so a later reconnect re-checks the freshly-spawned master.
    func reset() {
        pollTask?.cancel()
        pollTask = nil
        pollGeneration += 1
        ready = false
    }
}
