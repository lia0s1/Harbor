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
    @Published private(set) var containerLogs: [String: String] = [:]   // containerID -> log text

    private let exec: RemoteExec
    /// Shared connect-time socket gate. The mux socket only appears AFTER auth,
    /// so we wait on it before probing docker rather than racing the connect
    /// window (which would misreport a not-yet-ready socket as "docker missing").
    private let readiness: SocketReadiness
    private var refreshTask: Task<Void, Never>?
    /// Untracked action tasks (logs, start, stop, rm) so stop() can cancel them
    /// and their aux ssh children don't outlive a closed session.
    private var actionTasks: [Task<Void, Never>] = []

    private static let checkDeadline: TimeInterval = 600

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
        for task in actionTasks { task.cancel() }
        actionTasks.removeAll()
        status = .idle
        containers = []
        images = []
        containerLogs = [:]
    }

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
                self.status = .unavailable("无法复用 SSH 连接")
                return
            }
            // Check docker is available
            let which = await exec.run("command -v docker", timeout: 5)
            guard !Task.isCancelled else { return }
            guard which.exitCode == 0 else {
                self.status = .unavailable("远程服务器上未找到 docker 命令")
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
        !id.isEmpty && id.count >= 12 && id.count <= 64 && id.allSatisfy { $0.isHexDigit && $0.isLowercase }
    }

    /// Fetch recent logs for a container (last 200 lines).
    func fetchLogs(for container: DockerContainer) {
        guard Self.isValidContainerID(container.id) else { return }
        track(Task { [weak self] in
            guard let self else { return }
            let out = await exec.run(
                // stderr is already redirected to stdout (2>&1), so Docker errors
                // appear in stdoutText. stderrText here would only be SSH-layer
                // errors — don't show those as container logs.
                "docker logs --tail 200 --timestamps \(sq(container.id)) 2>&1",
                timeout: 15
            )
            guard !Task.isCancelled else { return }
            self.containerLogs[container.id] = out.stdoutText
        })
    }

    /// Start a stopped container.
    func startContainer(_ container: DockerContainer) {
        guard Self.isValidContainerID(container.id) else { return }
        track(Task { [weak self] in
            guard let self else { return }
            _ = await exec.run("docker start \(sq(container.id))", timeout: 10)
            guard !Task.isCancelled else { return }
            self.refresh()
        })
    }

    /// Stop a running container.
    func stopContainer(_ container: DockerContainer) {
        guard Self.isValidContainerID(container.id) else { return }
        track(Task { [weak self] in
            guard let self else { return }
            _ = await exec.run("docker stop \(sq(container.id))", timeout: 15)
            guard !Task.isCancelled else { return }
            self.refresh()
        })
    }

    /// Remove a (stopped) container.
    func removeContainer(_ container: DockerContainer) {
        guard Self.isValidContainerID(container.id) else { return }
        track(Task { [weak self] in
            guard let self else { return }
            _ = await exec.run("docker rm \(sq(container.id))", timeout: 10)
            guard !Task.isCancelled else { return }
            self.refresh()
        })
    }

    private func track(_ task: Task<Void, Never>) {
        actionTasks.append(task)
        // Prune completed tasks so the array doesn't grow without bound.
        actionTasks.removeAll { $0.isCancelled }
    }
}
