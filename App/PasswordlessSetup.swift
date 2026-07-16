import Foundation
import HarborKit

/// One-click passwordless login: uses a password ONCE to append an existing
/// local SSH public key to the host's `authorized_keys`. Host identity must
/// already be trusted by the user's normal OpenSSH known-hosts configuration.
/// The password is passed to a private `SSH_ASKPASS` helper through the child
/// process environment; it is never placed in argv or written to a file.
enum PasswordlessSetup {
    struct Outcome: Sendable {
        let success: Bool
        let message: String
    }

    @MainActor
    static func run(host: SSHHost, password: String) async -> Outcome {
        let okMarker = "__HARBOR_OK_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let keyOKMarker = "__HARBOR_KEY_OK_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        // Validate hostname/username/port before using them in argv.
        guard (try? SSHCommandBuilder.arguments(for: host)) != nil else {
            return Outcome(success: false, message: L("主机参数包含非法字符，无法建立连接。"))
        }
        guard !password.isEmpty else {
            return Outcome(success: false, message: L("请输入当前账户的 SSH 密码。"))
        }
        guard let localKey = existingPublicKey(for: host) else {
            return Outcome(
                success: false,
                message: L("未找到可用的本机 SSH 公钥。请先在“设置 → 密钥”生成带密码保护的密钥，或在上方选择已有私钥。")
            )
        }
        guard let helper = SecureAskpassHelper(secret: password) else {
            return Outcome(success: false, message: L("无法准备认证助手。"))
        }
        defer { helper.cleanup() }

        // Password-auth pass: only install the key and fix the user's SSH file
        // permissions. Harbor never edits or reloads the remote SSH daemon.
        let setupScript = """
        umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys && key="$(cat)" && test -n "$key" && \
        { grep -qxF "$key" ~/.ssh/authorized_keys || printf '%s\\n' "$key" >> ~/.ssh/authorized_keys; } && \
        echo \(okMarker)
        """
        let dest = SSHCommandBuilder.destination(for: host)
        let portArgs = host.port != SSHHost.defaultPort ? ["-p", String(host.port)] : []

        var setupArgv = [
            SSHCommandBuilder.executablePath,
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "PubkeyAuthentication=no",
            "-o", "PreferredAuthentications=password,keyboard-interactive",
            "-o", "NumberOfPasswordPrompts=1",
            "-o", "ConnectTimeout=15",
        ]
        setupArgv.append(contentsOf: portArgs)
        setupArgv.append(dest)
        setupArgv.append(setupScript)

        let setup = await AuxProcess.run(
            argv: setupArgv,
            stdin: Data((localKey.contents + "\n").utf8),
            environment: helper.environment,
            timeout: 30
        )
        guard setup.exitCode == 0, setup.stdoutText.contains(okMarker) else {
            return Outcome(success: false, message: failureMessage(setup, fallback: L("无法用密码登录或写入密钥。")))
        }

        // Key-auth verify: prove the host now logs in by key, no password.
        var verifyArgv = [
            SSHCommandBuilder.executablePath,
            "-F", "/dev/null",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=none",
            "-o", "PasswordAuthentication=no",
            "-o", "BatchMode=yes",
            "-o", "IdentitiesOnly=yes",
            "-o", "ConnectTimeout=15",
            "-i", localKey.privateKeyPath,
        ]
        verifyArgv.append(contentsOf: portArgs)
        verifyArgv.append(dest)
        verifyArgv.append("echo \(keyOKMarker)")

        let verify = await AuxProcess.run(argv: verifyArgv, timeout: 20)
        if verify.exitCode == 0, verify.stdoutText.contains(keyOKMarker) {
            return Outcome(success: true, message: L("✓ 已设置免密登录。下次连接将自动用密钥，无需密码。"))
        }
        return Outcome(
            success: false,
            message: L("公钥已安装，但无法验证密钥登录。请先解锁私钥并加入 ssh-agent；如服务器未开启公钥认证，请联系管理员处理。Harbor 不会修改 sshd_config。")
        )
    }

    // MARK: - Local public key

    private struct LocalPublicKey {
        let contents: String
        let privateKeyPath: String
    }

    /// Loads the selected identity's public key, then the standard OpenSSH
    /// identities. Missing keys are not generated here because automatic
    /// unencrypted private-key creation is not a safe default.
    private static func existingPublicKey(for host: SSHHost) -> LocalPublicKey? {
        let sshDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        let privateKeyURLs: [URL]
        if let identity = host.identityFile?.trimmingCharacters(in: .whitespaces),
           !identity.isEmpty {
            privateKeyURLs = [URL(fileURLWithPath: (identity as NSString).expandingTildeInPath)]
        } else {
            privateKeyURLs = ["id_ed25519", "id_rsa", "id_ecdsa", "id_dsa"].map {
                sshDir.appendingPathComponent($0)
            }
        }

        for privateURL in privateKeyURLs {
            let publicURL = URL(fileURLWithPath: privateURL.path + ".pub")
            guard FileManager.default.fileExists(atPath: privateURL.path),
                  let data = try? Data(contentsOf: publicURL),
                  let key = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  !key.isEmpty,
                  !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  key.split(whereSeparator: \.isWhitespace).count >= 2
            else { continue }
            return LocalPublicKey(contents: key, privateKeyPath: privateURL.path)
        }
        return nil
    }

    // MARK: - Failure reporting

    @MainActor
    private static func failureMessage(_ out: AuxProcess.Output, fallback: String) -> String {
        let err = out.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        if err.localizedCaseInsensitiveContains("host key verification failed")
            || err.localizedCaseInsensitiveContains("remote host identification has changed") {
            return L("主机密钥未受信任或已变更，Harbor 未发送密码。请先在“终端”中使用交互式 ssh 连接，核对并接受主机指纹后再重试。")
        }
        guard let last = err.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return fallback
        }
        return String(last)
    }
}

/// Temporary `SSH_ASKPASS` helper. The executable contains no secret; the
/// secret exists only in the spawned process environment and is never written
/// to disk or included in argv. A crash can therefore leave only an inert
/// helper script behind.
final class SecureAskpassHelper {
    let environment: [String: String]
    private let directory: URL

    init?(secret: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-askpass-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)

            let script = base.appendingPathComponent("askpass.sh")
            let body = "#!/bin/sh\nexec /usr/bin/printf '%s\\n' \"$HARBOR_ASKPASS_SECRET\"\n"
            guard fm.createFile(atPath: script.path, contents: Data(body.utf8)) else {
                try? fm.removeItem(at: base)
                return nil
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            self.directory = base
            self.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C",
                "DISPLAY": ":0",
                "SSH_ASKPASS": script.path,
                "SSH_ASKPASS_REQUIRE": "force",
                "HARBOR_ASKPASS_SECRET": secret,
            ]
        } catch {
            try? fm.removeItem(at: base)
            return nil
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
