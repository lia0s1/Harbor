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
        let cleanupArmedMarker = "__HARBOR_KEY_CLEANUP_ARMED_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        // Validate hostname/username/port before using them in argv.
        guard (try? SSHCommandBuilder.arguments(for: host)) != nil else {
            return Outcome(success: false, message: L("主机参数包含非法字符，无法建立连接。"))
        }
        guard !password.isEmpty else {
            return Outcome(success: false, message: L("请输入当前账户的 SSH 密码。"))
        }
        let localKey: LocalPublicKey
        switch await existingPublicKey(for: host) {
        case .found(let key):
            localKey = key
        case .missing:
            return Outcome(
                success: false,
                message: L("未找到可用的本机 SSH 公钥。请先在“设置 → 密钥”生成带密码保护的密钥，或在上方选择已有私钥。")
            )
        case .unverified:
            return Outcome(
                success: false,
                message: L("无法确认所选私钥与 .pub 文件属于同一密钥，Harbor 未向远端安装公钥。请从私钥重新导出 .pub 文件后重试。")
            )
        }
        guard let helper = SecureAskpassHelper(secret: password) else {
            return Outcome(success: false, message: L("无法准备认证助手。"))
        }
        defer { helper.cleanup() }

        // Never install the literal sidecar line. A per-attempt comment makes
        // cleanup exact: it can remove only the key added by this invocation,
        // not a pre-existing authorization for the same public key.
        let installKey = "\(localKey.authorizedKeyMaterial) harbor-passwordless-\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"

        // Password-auth pass: only install the key and fix the user's SSH file
        // permissions. Harbor never edits or reloads the remote SSH daemon.
        let setupScript = """
        umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys && key="$(cat)" && test -n "$key" && \
        echo \(cleanupArmedMarker) && \
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
            stdin: Data((installKey + "\n").utf8),
            environment: helper.environment,
            timeout: 30
        )
        guard setup.exitCode == 0, setup.stdoutText.contains(okMarker) else {
            let cleanupNote: String
            if setup.stdoutText.contains(cleanupArmedMarker) {
                let cleaned = await removeInstalledKey(
                    setupArgv: setupArgv,
                    key: installKey,
                    helper: helper
                )
                cleanupNote = cleanupStatusMessage(cleaned)
            } else {
                cleanupNote = ""
            }
            return Outcome(
                success: false,
                message: failureMessage(setup, fallback: L("无法用密码登录或写入密钥。"))
                    + cleanupNote
            )
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
        let cleaned = await removeInstalledKey(
            setupArgv: setupArgv,
            key: installKey,
            helper: helper
        )
        return Outcome(
            success: false,
            message: L("公钥已安装，但无法验证密钥登录。请先解锁私钥并加入 ssh-agent；如服务器未开启公钥认证，请联系管理员处理。Harbor 不会修改 sshd_config。")
                + cleanupStatusMessage(cleaned)
        )
    }

    // MARK: - Local public key

    private struct LocalPublicKey: Sendable {
        /// Canonical `type base64` fields, with any sidecar comment omitted.
        /// This is what OpenSSH authenticates; comments must not affect pairing.
        let authorizedKeyMaterial: String
        let privateKeyPath: String
    }

    private enum LocalPublicKeyLookup: Sendable {
        case found(LocalPublicKey)
        case missing
        case unverified
    }

    /// Loads the selected identity's public key, then the standard OpenSSH
    /// identities. Missing keys are not generated here because automatic
    /// unencrypted private-key creation is not a safe default.
    private static func existingPublicKey(for host: SSHHost) async -> LocalPublicKeyLookup {
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

        var foundUnverifiedPair = false
        for privateURL in privateKeyURLs {
            let publicURL = URL(fileURLWithPath: privateURL.path + ".pub")
            guard FileManager.default.fileExists(atPath: privateURL.path),
                  FileManager.default.fileExists(atPath: publicURL.path)
            else { continue }

            guard let publicKey = canonicalPublicKey(at: publicURL),
                  let privateBlob = await publicKeyBlob(fromPrivateKeyAt: privateURL),
                  privateBlob == publicKey.blob
            else {
                foundUnverifiedPair = true
                continue
            }
            return .found(LocalPublicKey(
                authorizedKeyMaterial: publicKey.material,
                privateKeyPath: privateURL.path
            ))
        }
        return foundUnverifiedPair ? .unverified : .missing
    }

    /// Parses a standard OpenSSH `type base64 [comment]` public key. Pairing
    /// compares the raw blob rather than trusting a `.pub` filename or comment.
    private static func canonicalPublicKey(at url: URL) -> (material: String, blob: Data)? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return canonicalPublicKey(in: data)
    }

    private static func canonicalPublicKey(in data: Data) -> (material: String, blob: Data)? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }

        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty,
              !line.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }

        let fields = line.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }

        let keyType = String(fields[0])
        let encodedBlob = String(fields[1])
        guard !keyType.hasPrefix("-"),
              !keyType.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let blob = Data(base64Encoded: encodedBlob),
              embeddedKeyType(in: blob) == keyType
        else { return nil }

        return ("\(keyType) \(encodedBlob)", blob)
    }

    /// An OpenSSH public-key blob begins with a four-byte big-endian length and
    /// the key algorithm name. Verify it so a mismatched leading key type
    /// cannot be installed even if its base64 payload is otherwise valid.
    private static func embeddedKeyType(in blob: Data) -> String? {
        guard blob.count >= 4 else { return nil }
        let length = blob.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let end = 4 + Int(length)
        guard end <= blob.count,
              let type = String(data: blob.subdata(in: 4..<end), encoding: .utf8),
              !type.isEmpty
        else { return nil }
        return type
    }

    /// Reads the public blob embedded in an `openssh-key-v1` private-key
    /// envelope. That header remains unencrypted even when the private portion
    /// is passphrase-protected, so it is a real pairing proof without asking
    /// for a passphrase or consulting the sidecar `.pub` file.
    private static func publicKeyBlob(fromPrivateKeyAt url: URL) async -> Data? {
        guard let privateData = try? Data(contentsOf: url) else { return nil }
        if let blob = openSSHEnvelopePublicKeyBlob(from: privateData) {
            return blob
        }
        return await derivedPublicKeyBlob(fromLegacyPrivateKeyAt: url.path)
    }

    /// For non-OpenSSH envelopes (for example unencrypted PEM keys), ask
    /// ssh-keygen to derive the public key. The process has no stdin or askpass
    /// environment, so encrypted/unsupported files simply fail closed instead
    /// of prompting or accepting a sidecar as evidence.
    private static func derivedPublicKeyBlob(fromLegacyPrivateKeyAt path: String) async -> Data? {
        let output = await AuxProcess.run(
            argv: ["/usr/bin/ssh-keygen", "-y", "-f", path],
            environment: [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C",
                "SSH_ASKPASS_REQUIRE": "never",
            ],
            timeout: 10
        )
        guard output.exitCode == 0,
              let publicKey = canonicalPublicKey(in: output.stdout)
        else { return nil }
        return publicKey.blob
    }

    /// `openssh-key-v1` stores three strings (cipher, KDF name/options), the
    /// number of keys, and then the unencrypted public-key blobs before the
    /// encrypted private section. Harbor accepts only the normal single-key
    /// form so there is no ambiguity about which private identity was chosen.
    private static func openSSHEnvelopePublicKeyBlob(from privateData: Data) -> Data? {
        guard let payload = openSSHEnvelopePayload(from: privateData) else { return nil }
        let magic = Data("openssh-key-v1\0".utf8)
        guard payload.starts(with: magic) else { return nil }

        var reader = SSHBinaryReader(data: payload, offset: magic.count)
        guard reader.readString() != nil, // ciphername
              reader.readString() != nil, // kdfname
              reader.readString() != nil, // kdfoptions
              reader.readUInt32() == 1,
              let publicBlob = reader.readString(),
              embeddedKeyType(in: publicBlob) != nil
        else { return nil }
        return publicBlob
    }

    private static func openSSHEnvelopePayload(from privateData: Data) -> Data? {
        guard let text = String(data: privateData, encoding: .utf8) else { return nil }
        let lines = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 3,
              lines.first == "-----BEGIN OPENSSH PRIVATE KEY-----",
              lines.last == "-----END OPENSSH PRIVATE KEY-----"
        else { return nil }
        return Data(base64Encoded: lines.dropFirst().dropLast().joined())
    }

    private struct SSHBinaryReader {
        let data: Data
        var offset: Int

        mutating func readUInt32() -> UInt32? {
            guard offset <= data.count - 4 else { return nil }
            let value = (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
            offset += 4
            return value
        }

        mutating func readString() -> Data? {
            guard let length = readUInt32() else { return nil }
            let byteCount = Int(length)
            guard byteCount <= data.count - offset else { return nil }
            let value = data.subdata(in: offset..<(offset + byteCount))
            offset += byteCount
            return value
        }
    }

    /// Re-authenticates with the one-time password path and removes precisely
    /// the per-attempt key line. The command retains strict host-key checking;
    /// if the host identity can no longer be verified, cleanup deliberately
    /// fails rather than trusting a different host.
    private static func removeInstalledKey(
        setupArgv: [String],
        key: String,
        helper: SecureAskpassHelper
    ) async -> Bool {
        let cleanupMarker = "__HARBOR_KEY_REMOVED_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))__"
        let cleanupScript = """
        umask 077; file="$HOME/.ssh/authorized_keys"; test -f "$file" || { echo \(cleanupMarker); exit 0; }; \\
        key="$(cat)" && test -n "$key" || exit 1; \\
        grep -qxF "$key" "$file"; status=$?; \\
        if [ "$status" -eq 1 ]; then echo \(cleanupMarker); exit 0; fi; \\
        [ "$status" -eq 0 ] || exit 1; \\
        tmp="$(mktemp "${file}.harbor.XXXXXX")" || exit 1; \\
        trap 'rm -f "$tmp"' 0 1 2 15; \\
        grep -vxF "$key" "$file" > "$tmp"; status=$?; \\
        if [ "$status" -ne 0 ] && [ "$status" -ne 1 ]; then exit 1; fi; \\
        chmod 600 "$tmp" && mv -f "$tmp" "$file" && echo \(cleanupMarker)
        """
        guard !setupArgv.isEmpty else { return false }
        var cleanupArgv = setupArgv
        cleanupArgv[cleanupArgv.count - 1] = cleanupScript
        let cleanup = await AuxProcess.run(
            argv: cleanupArgv,
            stdin: Data((key + "\n").utf8),
            environment: helper.environment,
            timeout: 30
        )
        return cleanup.exitCode == 0 && cleanup.stdoutText.contains(cleanupMarker)
    }

    @MainActor
    private static func cleanupStatusMessage(_ cleaned: Bool) -> String {
        cleaned
            ? L("已确认本次安装的公钥不存在或已移除。")
            : L("Harbor 无法确认移除本次安装的公钥；请在远端 ~/.ssh/authorized_keys 中删除带 harbor-passwordless- 前缀的那一行。")
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

            let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let envKey = "HARBOR_ASKPASS_" + token
            let script = base.appendingPathComponent("askpass.sh")
            let body = "#!/bin/sh\nexec /usr/bin/printf '%s\\n' \"$\(envKey)\"\n"
            guard fm.createFile(atPath: script.path, contents: Data(body.utf8)) else {
                try? fm.removeItem(at: base)
                return nil
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)

            self.directory = base
            var environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "LC_ALL": "C",
                "DISPLAY": ":0",
                "SSH_ASKPASS": script.path,
                "SSH_ASKPASS_REQUIRE": "force",
            ]
            environment[envKey] = secret
            self.environment = environment
        } catch {
            try? fm.removeItem(at: base)
            return nil
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
