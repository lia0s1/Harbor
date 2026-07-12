import Foundation
import Combine
import HarborKit

/// Owns all open terminal sessions and the tab selection.
@MainActor
final class SessionManager: ObservableObject {
    private static let trustedSystemShells: Set<String> = {
        let fallback = ["/bin/zsh", "/usr/bin/zsh", "/bin/bash", "/usr/bin/bash"]
        let fallbackSet = Set(fallback)
        guard let raw = try? String(contentsOfFile: "/etc/shells", encoding: .utf8) else {
            return fallbackSet
        }
        var shells = fallbackSet
        for line in raw.split(whereSeparator: \.isNewline) {
            let candidate = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if candidate.isEmpty || candidate.hasPrefix("#") { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                shells.insert(candidate)
            }
        }
        return shells
    }()

    private static let defaultLocalShell = "/bin/zsh"

    private static func sanitizedLocalShell(_ shell: String?) -> String {
        guard let shell else { return defaultLocalShell }
        let trimmed = shell.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trustedSystemShells.contains(trimmed) else { return defaultLocalShell }
        return trimmed
    }

    @Published private(set) var sessions: [TerminalSession] = []
    /// Active RDP connections keyed by host ID. One per host (RDP windows are
    /// managed by freerdp; Harbor just tracks their lifecycle).
    @Published private(set) var rdpConnections: [UUID: RDPConnection] = [:]
    @Published var selectedSessionID: UUID? {
        didSet {
            guard oldValue != selectedSessionID else { return }
            // Switching tabs moves live monitoring/ping to the newly selected
            // session and pauses the one we left.
            refreshActiveMonitoring()
        }
    }
    /// Set when opening a session fails validation (bad hostname etc.); the UI
    /// surfaces it as an alert and clears it.
    @Published var connectionError: String?
    /// IDs of the most recently connected hosts, newest first, persisted in
    /// user defaults. May contain IDs of since-deleted or ad-hoc hosts; the
    /// UI resolves them against the HostStore and skips misses.
    @Published private(set) var recentHostIDs: [UUID] = []

    private static let recentHostsKey = "recentHostIDs"
    private static let recentHostsLimit = 5

    /// Bundles all per-session service objects so they can be stored in a
    /// single dictionary instead of six separate ones.
    private struct SessionServices {
        /// Agentless monitor (CPU / mem / disk / net) over the ControlMaster socket.
        var monitor: MonitorService?
        /// ICMP/TCP ping prober for the latency widget.
        var ping: PingService?
        /// Live port-forward toggle service (nil when the host has no forwards).
        var forwarding: ForwardingService?
        /// Remote file browser data source.
        var files: FileService?
        /// One-shot detailed system report (系统信息). Created on demand the
        /// first time the user opens the sheet; reused on subsequent opens.
        var systemInfo: SystemInfoService?
        /// Docker panel data source — uses the same ControlMaster socket.
        var docker: DockerService?
        /// Shared connect-time socket-readiness gate so the monitor / file /
        /// system-info services don't each spawn their own `ssh -O check` loop.
        /// Reset on session exit.
        var socketReadiness: SocketReadiness?
    }

    /// Per-session service bundle. Replaces the six individual dictionaries
    /// (monitorServices, pingServices, forwardingServices, fileServices,
    /// systemInfoServices, socketReadiness) that used to live at the top level.
    private var services: [UUID: SessionServices] = [:]
    private var stateObservers: [UUID: AnyCancellable] = [:]
    private var systemInfoObservers: [UUID: AnyCancellable] = [:]
    /// Per-session timer for the post-connect stability confirmation window.
    private var stabilityConfirmTasks: [UUID: Task<Void, Never>] = [:]
    /// Per-session timer for reconnect backoff. Kept separate from
    /// stabilityConfirmTasks so the two timers can't silently cancel each other.
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    /// Sessions that CONFIRMED a stable connection (stayed `.running` past
    /// `stableConfirmDelay`). Only these auto-reconnect on a later drop — an
    /// initial connect failure (bad host / auth / unreachable) never qualifies,
    /// even though the 0.8s running-fallback briefly flips it to `.running`.
    private var everRunning: Set<UUID> = []
    /// Consecutive failed reconnect attempts. Escalates the backoff and triggers
    /// give-up at `maxAutoReconnect`. Reset to 0 only on a CONFIRMED-stable
    /// connection — NOT on the optimistic 0.8s `.running` fallback, which for an
    /// unreachable host would otherwise reset it every cycle and loop forever.
    private var reconnectCount: [UUID: Int] = [:]
    private static let maxAutoReconnect = 5
    /// A session must stay `.running` this long to count as a confirmed connect
    /// (resets the give-up counter). Must exceed ssh's `ConnectTimeout` (10s) so
    /// an unreachable host always drops BEFORE confirming, letting the counter
    /// climb to the give-up threshold instead of resetting.
    private static let stableConfirmDelay: TimeInterval = 15
    /// Owned store — injected into the environment by HarborApp so views can
    /// subscribe directly to it while SessionManager also accesses it without
    /// optional chaining.
    let hostStore = HostStore()
    /// Per-session freerdp launcher. Not a singleton so its lifecycle is tied to
    /// this SessionManager instance, making it mockable and testable.
    private let rdpService = RDPService()

    init() {
        let stored = UserDefaults.standard.stringArray(forKey: SessionManager.recentHostsKey) ?? []
        recentHostIDs = stored.compactMap(UUID.init(uuidString:))
    }

    var selectedSession: TerminalSession? {
        guard let id = selectedSessionID else { return nil }
        return sessions.first { $0.id == id }
    }

    /// Opens a new session for the host (multiple simultaneous sessions per
    /// host are allowed) and selects its tab.
    @discardableResult
    func openSession(host: SSHHost) -> TerminalSession? {
        do {
            // Every open tab (even an exited one — it may reconnect) keeps its
            // socket reserved, so a new tab to the same destination becomes its
            // own mux master and closing one tab never disconnects siblings.
            let usedSockets = Set(sessions.map(\.controlSocketPath))
            let session = try TerminalSession(host: host, avoidingControlSocketPaths: usedSockets)
            sessions.append(session)
            attachServices(to: session)
            selectedSessionID = session.id
            recordRecent(host.id)
            return session
        } catch {
            connectionError = harborErrorMessage(error)
            return nil
        }
    }

    /// Opens a new local shell tab (spawns $SHELL in a PTY, no SSH).
    @discardableResult
    func openLocalSession() -> TerminalSession {
        let shell = Self.sanitizedLocalShell(ProcessInfo.processInfo.environment["SHELL"])
        let session = TerminalSession(localShell: shell)
        sessions.append(session)
        selectedSessionID = session.id
        // Observe for cleanup on exit.
        let cancel = session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] state in
                guard let self, let session else { return }
                if case .exited = state { self.detachServices(for: session.id) }
            }
        stateObservers[session.id] = cancel
        objectWillChange.send()
        return session
    }

    // MARK: - RDP

    /// Connect to a Windows host via RDP (freerdp). One connection per host.
    func connectRDP(host: SSHHost, password: String = "") {
        if let existing = rdpConnections[host.id], existing.isRunning { return }
        // Disconnect any existing (non-running) connection before replacing it
        // so the old freerdp process is reaped rather than silently orphaned.
        rdpConnections[host.id]?.disconnect()
        let conn = RDPConnection(host: host)
        conn.onExit = { [weak self] hostID in
            self?.rdpConnections.removeValue(forKey: hostID)
        }
        rdpConnections[host.id] = conn
        rdpService.connect(host: host, connection: conn, password: password)
    }

    func disconnectRDP(host: SSHHost) {
        rdpConnections[host.id]?.disconnect()
        rdpConnections.removeValue(forKey: host.id)
    }

    func rdpConnection(for host: SSHHost) -> RDPConnection? {
        rdpConnections[host.id]
    }

    // MARK: - Monitoring panel data source for a session (nil only for unknown IDs).
    func monitor(for session: TerminalSession) -> MonitorService? {
        services[session.id]?.monitor
    }

    func ping(for session: TerminalSession) -> PingService? {
        services[session.id]?.ping
    }

    /// Live port-forward toggle service for a session (nil when the session
    /// has no forwards defined or its ID is unknown).
    func forwarding(for session: TerminalSession) -> ForwardingService? {
        services[session.id]?.forwarding
    }

    /// File panel data source for a session (nil only for unknown IDs).
    func files(for session: TerminalSession) -> FileService? {
        services[session.id]?.files
    }

    func docker(for session: TerminalSession) -> DockerService? {
        services[session.id]?.docker
    }

    /// Lazily-created one-shot 系统信息 report source for a session. Created on
    /// first request (the report is opened far less often than monitoring), so
    /// idle sessions never hold one. Reuses the session's own ControlMaster
    /// socket — no extra connection.
    func systemInfo(for session: TerminalSession) -> SystemInfoService {
        if let existing = services[session.id]?.systemInfo { return existing }
        let service = SystemInfoService(
            destination: session.destination,
            controlSocketPath: session.controlSocketPath,
            port: session.host.port,
            readiness: readiness(for: session)
        )
        services[session.id, default: SessionServices()].systemInfo = service
        // Once the report loads, remember the detected distro on the saved host
        // so the sidebar shows its OS badge (next time, even before connecting).
        let hostID = session.host.id
        let destination = session.destination
        systemInfoObservers[session.id] = service.$state.sink { [weak self] state in
            guard case .loaded(let info) = state else { return }
            MainActor.assumeIsolated {
                self?.recordOS(hostID: hostID, destination: destination,
                               prettyName: info.prettyName, uname: info.os)
            }
        }
        return service
    }

    /// The session's shared socket-readiness gate, created on first use.
    private func readiness(for session: TerminalSession) -> SocketReadiness {
        if let existing = services[session.id]?.socketReadiness { return existing }
        let gate = SocketReadiness(
            destination: session.destination,
            controlSocketPath: session.controlSocketPath,
            port: session.host.port
        )
        services[session.id, default: SessionServices()].socketReadiness = gate
        return gate
    }

    private func recordOS(hostID: UUID, destination: String, prettyName: String, uname: String) {
        guard let brand = OSBrand.classify(prettyName: prettyName, uname: uname) else { return }
        // Match the saved host by id, or — for a quick-connect session, whose
        // ad-hoc host has a different id — by its destination, so connecting to
        // a saved host's address still tags it.
        guard var host = hostStore.host(withID: hostID)
            ?? hostStore.hosts.first(where: { SSHCommandBuilder.destination(for: $0) == destination }),
              host.osID != brand.id || host.osName != brand.name
        else { return }
        host.osID = brand.id
        host.osName = brand.name
        hostStore.update(host)
    }

    /// Creates the per-session monitor + ping + forwarding services and drives
    /// their lifecycle from the session's state plus tab selection: only the
    /// SELECTED running session monitors and pings (FinalShell shows one rail
    /// at a time). Background tabs keep their file service warm but pause CPU /
    /// ping polling, so N open tabs never mean N concurrent /proc pollers and
    /// N live ping processes hammering the machine.
    private func attachServices(to session: TerminalSession) {
        let readiness = readiness(for: session)
        var bundle = services[session.id] ?? SessionServices()
        bundle.socketReadiness = readiness
        bundle.monitor = MonitorService(
            destination: session.destination,
            controlSocketPath: session.controlSocketPath,
            port: session.host.port,
            readiness: readiness
        )
        bundle.ping = PingService(hostname: session.host.hostname)
        if !session.host.portForwards.isEmpty {
            let exec = RemoteExec(
                destination: session.destination,
                controlSocketPath: session.controlSocketPath,
                port: session.host.port
            )
            bundle.forwarding = ForwardingService(
                exec: exec,
                forwards: session.host.portForwards
            )
        }
        bundle.files = FileService(
            destination: session.destination,
            controlSocketPath: session.controlSocketPath,
            port: session.host.port,
            readiness: readiness
        )
        // Docker panel — uses the same ControlMaster socket.
        let dockerExec = RemoteExec(destination: session.destination, controlSocketPath: session.controlSocketPath, port: session.host.port)
        let docker = DockerService(exec: dockerExec, readiness: readiness)
        bundle.docker = docker
        services[session.id] = bundle

        let sessionID = session.id
        stateObservers[sessionID] = session.$state.sink { [weak self] state in
            // @Published always fires on the main thread here (TerminalSession
            // hops via onMain), but the sink closure itself is nonisolated.
            MainActor.assumeIsolated {
                self?.sessionStateChanged(sessionID: sessionID, state: state)
            }
        }
    }

    private func sessionStateChanged(sessionID: UUID, state: TerminalSession.State) {
        // The sidebar live-session dot and the tab-strip "save as host" button
        // observe only the manager; nudge it so they refresh when a session's
        // live/exited status flips. (Title/terminalView changes do NOT bubble
        // here — they are observed directly by the leaf views — so high-rate
        // terminal output no longer re-renders the whole window.)
        objectWillChange.send()

        // The file service follows pure session lifecycle (it is cheap when
        // idle and the panel for a background tab stays mounted-but-hidden).
        switch state {
        case .connecting:
            break
        case .running:
            services[sessionID]?.files?.start()
            // Don't trust the optimistic 0.8s running-fallback as a real connect.
            // Arm a stability confirm: only if the session is STILL running after
            // `stableConfirmDelay` do we mark it reconnect-eligible and clear the
            // give-up counter. A host that flips to .running then drops (e.g.
            // unreachable, fails at ssh's 10s ConnectTimeout) never confirms, so
            // the counter keeps climbing toward give-up.
            stabilityConfirmTasks.removeValue(forKey: sessionID)?.cancel()
            reconnectTasks.removeValue(forKey: sessionID)?.cancel()
            scheduleStabilityConfirm(sessionID: sessionID)
        case .exited(let code):
            services[sessionID]?.files?.stop()
            // Forget the verified socket so a reconnect re-checks the new master
            // instead of trusting a stale "ready" latch.
            services[sessionID]?.socketReadiness?.reset()
            scheduleAutoReconnect(sessionID: sessionID, code: code)
        }
        // CPU/ping polling is gated on BOTH running and selected. `@Published`
        // emits in willSet, so `session.state` is still the PREVIOUS value while
        // this sink runs — reading it now would see `.connecting` and never
        // start monitoring. Defer one runloop so the property is updated first.
        DispatchQueue.main.async { [weak self] in self?.refreshActiveMonitoring() }
    }

    /// Marks a session reconnect-eligible and clears its give-up counter once it
    /// has stayed `.running` past `stableConfirmDelay` — a real, confirmed
    /// connection, not the optimistic 0.8s fallback.
    private func scheduleStabilityConfirm(sessionID: UUID) {
        stabilityConfirmTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.stableConfirmDelay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            guard let session = self.sessions.first(where: { $0.id == sessionID }),
                  session.state == .running else { return }
            self.everRunning.insert(sessionID)
            self.reconnectCount[sessionID] = 0
            session.setAutoReconnectAttempt(0)
        }
    }

    /// Auto-reconnects a session that dropped UNEXPECTEDLY (was confirmed-connected,
    /// then its master died — network blip, server reboot, idle kill). Deliberately
    /// skips: clean logouts (`exit 0`), sessions that never confirmed a stable
    /// connection (initial connect / auth / unreachable failures), and user-closed
    /// tabs (their state observer is detached before `terminate()`, so `.exited`
    /// never lands here). Escalates the backoff 1→2→4→8s per CONSECUTIVE failed
    /// attempt; after `maxAutoReconnect` it gives up and shows the manual button.
    private func scheduleAutoReconnect(sessionID: UUID, code: Int32?) {
        // Cancel any pending stability confirm and prior reconnect backoff.
        stabilityConfirmTasks.removeValue(forKey: sessionID)?.cancel()
        reconnectTasks.removeValue(forKey: sessionID)?.cancel()
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        guard everRunning.contains(sessionID), let code, code != 0 else {
            session.setAutoReconnectAttempt(0)
            reconnectCount[sessionID] = 0
            return
        }
        let count = (reconnectCount[sessionID] ?? 0) + 1
        guard count <= Self.maxAutoReconnect else {
            // Give up after repeated failures → fall back to the manual 重新连接
            // button. A future drop (after a confirmed-stable reconnect) tries
            // again from scratch.
            reconnectCount[sessionID] = 0
            session.setAutoReconnectAttempt(0)
            return
        }
        reconnectCount[sessionID] = count
        session.setAutoReconnectAttempt(count) // drives the banner
        let delay = min(8.0, pow(2.0, Double(count - 1))) // 1, 2, 4, 8, 8 …
        reconnectTasks[sessionID] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            // Only fire if the user hasn't acted in the meantime (still exited).
            guard let session = self.sessions.first(where: { $0.id == sessionID }),
                  session.state.isExited else { return }
            session.reconnect()
        }
    }

    /// Runs monitor + ping for the selected running session only; pauses them
    /// for every other session. Idempotent (start/stop are guarded), so it is
    /// safe to call on every selection or state change.
    private func refreshActiveMonitoring() {
        for session in sessions {
            let shouldRun = session.id == selectedSessionID && session.state == .running
            if shouldRun {
                services[session.id]?.monitor?.start()
                services[session.id]?.ping?.start()
                // Prefetch the 系统信息 report in the background so opening it is
                // instant (it patiently waits for the socket on its own).
                systemInfo(for: session).fetchIfNeeded()
            } else {
                services[session.id]?.monitor?.stop()
                services[session.id]?.ping?.stop()
            }
        }
    }

    private func detachServices(for sessionID: UUID) {
        stateObservers.removeValue(forKey: sessionID)?.cancel()
        stabilityConfirmTasks.removeValue(forKey: sessionID)?.cancel()
        reconnectTasks.removeValue(forKey: sessionID)?.cancel()
        everRunning.remove(sessionID)
        reconnectCount.removeValue(forKey: sessionID)
        systemInfoObservers.removeValue(forKey: sessionID)?.cancel()
        // Stop all running services then drop the whole bundle in one operation.
        if let bundle = services.removeValue(forKey: sessionID) {
            bundle.monitor?.stop()
            bundle.ping?.stop()
            bundle.files?.stop()
            bundle.docker?.stop()
            bundle.systemInfo?.cancel()
            bundle.socketReadiness?.reset()
            // bundle.forwarding has no stop/cancel — it cleans up on dealloc.
        }
    }

    private func recordRecent(_ hostID: UUID) {
        var recents = recentHostIDs
        recents.removeAll { $0 == hostID }
        recents.insert(hostID, at: 0)
        if recents.count > SessionManager.recentHostsLimit {
            recents.removeLast(recents.count - SessionManager.recentHostsLimit)
        }
        recentHostIDs = recents
        UserDefaults.standard.set(
            recents.map(\.uuidString),
            forKey: SessionManager.recentHostsKey
        )
    }

    /// Terminates the child process if running and removes the tab. Selection
    /// moves to the neighbor that took the closed tab's place (or the new last tab).
    func close(_ session: TerminalSession) {
        guard let index = sessions.firstIndex(where: { $0.id == session.id }) else { return }
        detachServices(for: session.id)
        session.terminate()
        sessions.remove(at: index)
        if selectedSessionID == session.id {
            if sessions.indices.contains(index) {
                selectedSessionID = sessions[index].id
            } else {
                selectedSessionID = sessions.last?.id
            }
        }
    }

    func closeSelected() {
        if let session = selectedSession { close(session) }
    }

    /// Clones `session`: opens a NEW tab to the same host (same config, distinct
    /// mux master — closing the original never kills the clone). Hockey-stick: ⌘D.
    @discardableResult
    func clone(_ session: TerminalSession) -> TerminalSession? {
        return openSession(host: session.host)
    }

    func reconnect(_ session: TerminalSession) {
        // Manual reconnect cancels any pending stability confirm / backoff and
        // clears the banner + escalation counter, then connects immediately.
        stabilityConfirmTasks.removeValue(forKey: session.id)?.cancel()
        reconnectTasks.removeValue(forKey: session.id)?.cancel()
        reconnectCount[session.id] = 0
        session.setAutoReconnectAttempt(0)
        session.reconnect()
        selectedSessionID = session.id
    }

    /// Cmd+1..9: select tab by position.
    func selectSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        selectedSessionID = sessions[index].id
    }

    /// Called on app termination so no orphaned ssh/ping processes linger
    /// (spawned children are NOT killed automatically when the app exits).
    func terminateAll() {
        for session in sessions {
            detachServices(for: session.id)
            session.terminate()
        }
        for conn in rdpConnections.values { conn.disconnect() }
        rdpConnections.removeAll()
    }
}
