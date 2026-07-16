import Foundation

/// Local-only command safety classification used by Harbor's confirmation UI.
/// This is a guardrail, not a shell parser or a policy-enforcement mechanism:
/// the user can still deliberately run any command after confirming it.
public enum CommandRisk: String, Equatable, Sendable {
    case destructiveFiles
    case systemLifecycle
    case processTermination
    case containerOrClusterDeletion

    public var summary: String {
        switch self {
        case .destructiveFiles: return "可能删除或覆盖文件"
        case .systemLifecycle: return "可能重启、关机或停止服务"
        case .processTermination: return "可能强制结束进程"
        case .containerOrClusterDeletion: return "可能删除容器或集群资源"
        }
    }
}

public enum CommandRiskDetector {
    /// Returns the first high-impact operation found in a user-entered shell
    /// command. Matching is intentionally conservative and transparent: it
    /// only prompts; it never rewrites or blocks the user's input.
    public static func detect(in command: String) -> CommandRisk? {
        let normalized = command.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        // Collapse runs of spaces so "rm  -rf" (extra spaces) still matches.
        let condensed = normalized.split(separator: " ").filter { !$0.isEmpty }.joined(separator: " ")
        let tokens = normalized.split(whereSeparator: { $0.isWhitespace })

        if condensed.contains("rm -rf")
            || condensed.contains("rm -fr")
            || condensed.contains("rm --recursive")
            || condensed.contains("mkfs")
            || condensed.contains("dd if=") {
            return .destructiveFiles
        }

        if tokens.contains("reboot") || tokens.contains("shutdown") || tokens.contains("poweroff")
            || containsLifecycleCommand(tokens) {
            return .systemLifecycle
        }

        if normalized.contains("kill -9") || normalized.contains("killall -9") {
            return .processTermination
        }

        if normalized.contains("docker rm") || normalized.contains("docker rmi")
            || normalized.contains("docker system prune") || normalized.contains("docker compose down")
            || normalized.contains("kubectl delete") {
            return .containerOrClusterDeletion
        }

        return nil
    }

    private static func containsLifecycleCommand(_ tokens: [Substring]) -> Bool {
        for index in tokens.indices where tokens[index] == "systemctl" || tokens[index] == "service" {
            let next = tokens.index(after: index)
            guard next < tokens.endIndex else { continue }
            if tokens[index] == "systemctl",
               ["stop", "restart", "disable"].contains(String(tokens[next])) { return true }
            let afterService = tokens.index(after: next)
            if tokens[index] == "service", afterService < tokens.endIndex,
               ["stop", "restart"].contains(String(tokens[afterService])) { return true }
        }
        return false
    }
}
