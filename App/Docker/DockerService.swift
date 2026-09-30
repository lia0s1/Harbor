import Foundation
import Combine
import HarborKit

/// Manages Docker state for one SSH session.
/// Uses the session's existing ControlMaster socket via RemoteExec — never
/// re-authenticates. Polls containers on demand (pull-to-refresh or auto).
@MainActor
final class DockerService: ObservableObject {
    enum Status {
        case idle, loading, unavailable(String), ready
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var containers: [DockerContainer] = []
    @Published private(set) var images: [DockerImage] = []
    /// Last viewed container only. Older log text is dropped so a background
    /// session cannot accumulate unbounded `docker logs` dumps.
    @Published private(set) var containerLogs: [String: String] = [:]
    /// Container IDs with start/stop/rm in flight. UI disables those rows.
    @Published private(set) var mutatingIDs: Set<String> = []
    /// Container whose logs are currently being fetched, if any.
    @Published private(set) var logsLoadingID: String?
    /// Last start/stop/rm/log failure; cleared on the next success or dismiss.
    @Published var lastError: String?

    private let exec: RemoteExec
    /// Shared connect-time socket gate. The mux socket only appears AFTER auth,
    /// so we wait on it before probing docker rather than racing the connect
    /// window (which would misreport a not-yet-ready socket as "docker missing").
    private let readiness: SocketReadiness
    private var refreshTask: Task<Void, Never>?
    /// Untracked action tasks (logs, start, stop, rm) so stop() can cancel them
    /// and their aux ssh children don't outlive a closed session.
    private var actionTasks: [Task<Void, Never>] = []
    /// The ssh process streaming `docker logs -f`, if any.
    private var logProcess: Process?
    /// Bumps on every log request and on stop() so a stale fetch cannot land
    /// on a container the user is no longer viewing.
    private var logGeneration = 0
    /// Sessions opened for `docker exec` that are still connecting; the sink
    /// injects the exec command at the first `.running` and removes itself.
    private var execLaunchObservers: [UUID: AnyCancellable] = [:]

    private static let checkDeadline: TimeInterval = 600
    private static let maxLogBytes = 256 * 1024

    init(exec: RemoteExec, readiness: SocketReadiness) {
        self.exec = exec
        self.readiness = readiness
    }

    /// Check if docker is installed on the remote, then load containers + images.
    func start() {
        guard case .idle = status else { return }
        refresh()
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        stopLogFollow()
        for observer in execLaunchObservers.values { observer.cancel() }
        execLaunchObservers.removeAll()
        for task in actionTasks { task.cancel() }
        actionTasks.removeAll()
        logGeneration += 1
        status = .idle
        containers = []
        images = []
        containerLogs = [:]
        mutatingIDs = []
        logsLoadingID = nil
        lastError = nil
    }

    var isRefreshing: Bool {
        if case .loading = status { return true }
        return false
    }

    func isMutating(_ id: String) -> Bool { mutatingIDs.contains(id) }

    /// Re-fetch containers and images.
    func refresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.status = .loading
            // Wait for the shared ControlMaster socket before probing so a Docker
            // tab opened during the connect window doesn't fail with a misleading
            // "docker missing" error while the socket is still coming up.
            let socketAlive = await readiness.waitUntilReady(
                deadline: Date().addingTimeInterval(Self.checkDeadline))
            guard !Task.isCancelled else { return }
            guard socketAlive else {
                self.status = .unavailable(L("无法复用 SSH 连接"))
                return
            }
            // Check docker is available
            let which = await exec.run("command -v docker", timeout: 5)
            guard !Task.isCancelled else { return }
            guard which.exitCode == 0 else {
                self.status = .unavailable(L("远程服务器上未找到 docker 命令"))
                return
            }
            // Fetch containers
            let psOut = await exec.run(
                "docker ps -a --format '{{json .}}'",
                timeout: 10
            )
            let imgOut = await exec.run(
                "docker images --format '{{json .}}'",
                timeout: 10
            )
            guard !Task.isCancelled else { return }
            self.containers = DockerParser.parseContainers(psOut.stdoutText)
            self.images = DockerParser.parseImages(imgOut.stdoutText)
            self.status = .ready
        }
    }

    /// Returns true when `id` matches the Docker container ID format (12–64
    /// lowercase hex chars). Guards action commands against a compromised remote
    /// docker binary returning a crafted ID; sq() already prevents injection,
    /// so this is defense-in-depth.
    private static func isValidContainerID(_ id: String) -> Bool {
        !id.isEmpty && id.count >= 12 && id.count <= 64 && id.allSatisfy {
            ("0"..."9").contains($0) || ("a"..."f").contains($0)
        }
    }

    /// Streams `docker logs -f` for a container: seeds with the last 200 lines
    /// and appends live output into `containerLogs` until replaced or stopped.
    /// The ssh child is killed by `stopLogFollow()` (stop / next request).
    func followLogs(for container: DockerContainer) {
        guard Self.isValidContainerID(container.id) else { return }
        stopLogFollow()
        logGeneration += 1
        let generation = logGeneration
        let id = container.id
        logsLoadingID = id

        guard let argv = try? SSHCommandBuilder.auxiliaryCommand(
            controlSocketPath: exec.controlSocketPath,
            destination: exec.destination,
            remoteScript: "docker logs -f --tail 200 --timestamps \(sq(id)) 2>&1",
            port: exec.port
        ) else {
            logsLoadingID = nil
            lastError = L("无法启动日志跟踪")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: argv[0])
        process.arguments = Array(argv.dropFirst())
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            logsLoadingID = nil
            lastError = L("无法启动日志跟踪")
            return
        }
        logProcess = process

        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { [weak self] fh in
            let data = fh.availableData
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            let chunk = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.appendLog(id: id, generation: generation, chunk: chunk)
            }
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                handle.readabilityHandler = nil
                if self.logProcess === process {
                    self.logProcess = nil
                }
                guard generation == self.logGeneration else { return }
                if self.logsLoadingID == id { self.logsLoadingID = nil }
                self.lastError = L("日志跟踪已结束（容器可能已停止）")
            }
        }
    }

    /// Kills the active `docker logs -f` ssh child, if any.
    func stopLogFollow() {
        logGeneration += 1
        if let process = logProcess {
            if process.isRunning { process.terminate() }
            logProcess = nil
        }
        logsLoadingID = nil
    }

    private func appendLog(id: String, generation: Int, chunk: String) {
        guard generation == logGeneration else { return }
        let text = (containerLogs[id] ?? "") + chunk
        containerLogs = [id: Self.cappedLog(text)]
        if logsLoadingID == id { logsLoadingID = nil }
    }

    /// Start a stopped container.
    func startContainer(_ container: DockerContainer) {
        mutate(container, command: "docker start \(sq(container.id))", timeout: 10)
    }

    /// Stop a running container.
    func stopContainer(_ container: DockerContainer) {
        mutate(container, command: "docker stop \(sq(container.id))", timeout: 15)
    }

    /// Restart a running or stopped container.
    func restartContainer(_ container: DockerContainer) {
        mutate(container, command: "docker restart \(sq(container.id))", timeout: 30)
    }

    /// Remove a (stopped) container.
    func removeContainer(_ container: DockerContainer) {
        mutate(container, command: "docker rm \(sq(container.id))", timeout: 10)
    }

    /// Remove an image (`docker rmi`). Image IDs share the container-ID hex
    /// format, so the same validation guard applies.
    func removeImage(_ image: DockerImage) {
        guard Self.isValidContainerID(image.id) else { return }
        let id = image.id
        guard mutatingIDs.insert(id).inserted else { return }
        track { [weak self] in
            guard let self else { return }
            defer { self.mutatingIDs.remove(id) }
            let out = await self.exec.run("docker rmi \(sq(id))", timeout: 30)
            guard !Task.isCancelled else { return }
            if out.exitCode == 0 {
                self.lastError = nil
            } else {
                let stderr = out.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastError = stderr.isEmpty ? L("操作失败") : stderr
            }
            self.refresh()
        }
    }

    /// Opens a new SSH tab to `host` and runs `docker exec -it <id> sh` in it
    /// as soon as the session reaches `.running`. Returns false when the
    /// container ID is invalid or the tab could not open.
    @discardableResult
    func openExecTerminal(for container: DockerContainer, host: SSHHost, sessionManager: SessionManager) -> Bool {
        guard Self.isValidContainerID(container.id) else { return false }
        guard let session = sessionManager.openSession(host: host) else { return false }
        let command = "docker exec -it \(sq(container.id)) sh\n"
        let sessionID = session.id
        execLaunchObservers[sessionID] = session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak session] state in
                guard let self, let session else { return }
                if case .running = state {
                    session.sendText(command)
                    self.execLaunchObservers[sessionID] = nil
                } else if case .exited = state {
                    self.execLaunchObservers[sessionID] = nil
                }
            }
        return true
    }

    private func mutate(_ container: DockerContainer, command: String, timeout: TimeInterval) {
        guard Self.isValidContainerID(container.id) else { return }
        let id = container.id
        guard mutatingIDs.insert(id).inserted else { return }
        track { [weak self] in
            guard let self else { return }
            defer { self.mutatingIDs.remove(id) }
            let out = await self.exec.run(command, timeout: timeout)
            guard !Task.isCancelled else { return }
            if out.exitCode == 0 {
                self.lastError = nil
            } else {
                let stderr = out.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                self.lastError = stderr.isEmpty ? L("操作失败") : stderr
            }
            self.refresh()
        }
    }

    /// Keep the tail so the newest docker lines survive the 256 KiB cap.
    private static func cappedLog(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxLogBytes else { return text }
        let drop = utf8.count - maxLogBytes
        var index = utf8.index(utf8.startIndex, offsetBy: drop)
        while index < utf8.endIndex, utf8[index] & 0b1100_0000 == 0b1000_0000 {
            index = utf8.index(after: index)
        }
        return String(text[index...])
    }

    @discardableResult
    private func track(_ body: @MainActor @escaping () async -> Void) -> Task<Void, Never> {
        // Capture a handle to the task so the task itself can remove the entry
        // once it completes (naturally OR via cancellation).
        var handle: Task<Void, Never>?
        let task = Task { @MainActor [weak self] in
            defer {
                if let self, let h = handle {
                    self.actionTasks.removeAll { $0 == h }
                }
            }
            await body()
        }
        handle = task
        actionTasks.append(task)
        actionTasks.removeAll { $0.isCancelled }
        return task
    }
}
