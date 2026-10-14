import Foundation
import Combine
import HarborKit

/// Drives the host editor's graded "测试连接" probe:
///   1. DNS resolution (getaddrinfo via HostProber)
///   2. TCP connect to host:port — for SSH hosts also reads the `SSH-` banner
///   3. (SSH only) BatchMode auth check: `ssh -o BatchMode=yes
///      -o NumberOfPasswordPrompts=0 … true`, proving key/agent auth works
///      without ever prompting for a password.
///
/// RDP hosts run stages 1–2 only. Fully async, cancellable, never blocks the
/// UI; results land in `stages` for inline display.
@MainActor
final class ConnectionTester: ObservableObject {
    enum StageKind: String, Equatable {
        case resolve
        case connect
        case auth
    }

    enum StageState: Equatable {
        case pending, running, ok, failed, skipped
    }

    struct Stage: Identifiable, Equatable {
        let kind: StageKind
        var state: StageState = .pending
        var detail = ""
        var id: StageKind { kind }
    }

    @Published private(set) var stages: [Stage] = []
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?

    deinit { task?.cancel() }

    /// Starts a fresh probe for the given (already validated) host draft.
    func start(host: SSHHost) {
        cancel()
        var kinds: [StageKind] = [.resolve, .connect]
        if host.connectionProtocol == .ssh { kinds.append(.auth) }
        stages = kinds.map { Stage(kind: $0) }
        isRunning = true
        task = Task { await run(host: host) }
    }

    /// Cancels the in-flight probe; unfinished stages show as skipped.
    func cancel() {
        task?.cancel()
        task = nil
        guard isRunning else { return }
        for index in stages.indices where stages[index].state == .running || stages[index].state == .pending {
            stages[index].state = .skipped
        }
        isRunning = false
    }

    func reset() {
        cancel()
        stages = []
    }

    // MARK: - Probe sequence

    private func run(host: SSHHost) async {
        // Stage 1: DNS.
        setStage(.resolve, state: .running)
        switch await HostProber.resolve(hostname: host.hostname) {
        case .success(let addresses):
            var detail = addresses.prefix(3).joined(separator: ", ")
            if addresses.count > 3 {
                detail += L(" 等 %lld 个地址", addresses.count)
            }
            setStage(.resolve, state: .ok, detail: detail)
        case .failure(let error):
            setStage(.resolve, state: .failed, detail: describe(error))
            finish()
            return
        }
        guard !Task.isCancelled else { return }

        // Stage 2: TCP (+ SSH banner for SSH hosts).
        setStage(.connect, state: .running)
        let expectBanner = host.connectionProtocol == .ssh
        switch await HostProber.probe(host: host.hostname, port: host.port, banner: expectBanner) {
        case .success(let banner):
            setStage(
                .connect, state: .ok,
                detail: banner.isEmpty
                    ? L("TCP 端口 %lld 已连接", host.port)
                    : L("已连接：%@", banner)
            )
        case .failure(let error):
            setStage(.connect, state: .failed, detail: describe(error))
            finish()
            return
        }
        guard !Task.isCancelled else { return }

        // Stage 3: BatchMode auth (SSH only — never prompts for a password).
        setStage(.auth, state: .running)
        guard let argv = authArgv(for: host) else {
            setStage(.auth, state: .failed, detail: L("当前配置无法构建 ssh 参数"))
            finish()
            return
        }
        let output = await AuxProcess.run(argv: argv, timeout: 15)
        guard !Task.isCancelled else { return }
        interpretAuthOutput(output)
        finish()
    }

    /// `arguments(for:)` carries ports/jump hosts/identity/safe extra args; the
    /// BatchMode prefix comes first so it wins (OpenSSH: first value wins).
    /// Shell and forwards are stripped — the probe runs plain `true`.
    private func authArgv(for host: SSHHost) -> [String]? {
        var probeHost = host
        probeHost.shell = ""
        probeHost.portForwards = []
        guard let base = try? SSHCommandBuilder.arguments(for: probeHost) else { return nil }
        return [SSHCommandBuilder.executablePath,
                "-o", "BatchMode=yes",
                "-o", "NumberOfPasswordPrompts=0",
                "-o", "ConnectTimeout=8"] + base + ["true"]
    }

    private func interpretAuthOutput(_ output: AuxProcess.Output) {
        if output.timedOut {
            setStage(.auth, state: .failed, detail: L("认证超时（15 秒）"))
            return
        }
        if output.exitCode == 0 {
            setStage(.auth, state: .ok, detail: L("免密认证通过（密钥或 ssh-agent 可用）"))
            return
        }
        let stderr = output.stderrText
        let lowered = stderr.lowercased()
        if lowered.contains("host key verification failed") {
            setStage(.auth, state: .failed,
                     detail: L("主机密钥未被信任：请先用终端连接一次并核对指纹"))
        } else if lowered.contains("permission denied") {
            setStage(.auth, state: .failed,
                     detail: L("免密认证未通过（服务器要求密码或交互认证）"))
        } else {
            let lastLine = stderr
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            setStage(.auth, state: .failed,
                     detail: lastLine ?? L("认证探测失败（退出码 %lld）", output.exitCode))
        }
    }

    private func describe(_ error: HostProbeError) -> String {
        switch error {
        case .timeout: return L("超时（8 秒）")
        case .cancelled: return L("已取消")
        case .invalidPort: return L("端口无效")
        case .dnsFailed(let message): return L("DNS 解析失败：%@", message)
        case .connectFailed(let message): return L("连接失败：%@", message)
        case .notSSHServer: return L("端口已连接，但对端不是 SSH 服务（未读到 SSH 标识）")
        }
    }

    private func setStage(_ kind: StageKind, state: StageState, detail: String = "") {
        guard let index = stages.firstIndex(where: { $0.kind == kind }) else { return }
        stages[index].state = state
        stages[index].detail = detail
    }

    private func finish() {
        isRunning = false
    }
}
