import SwiftUI
import AppKit
import HarborKit

// MARK: - Key info model

/// A detected SSH private key in ~/.ssh
struct SSHKeyInfo: Identifiable, Equatable {
    let id = UUID()
    let fileName: String       // e.g. "id_ed25519"
    let fullPath: String       // e.g. "/Users/zero/.ssh/id_ed25519"
    let keyType: SSHKeyType
    let hasPubKey: Bool
    let pubKeyPath: String     // e.g. "/Users/zero/.ssh/id_ed25519.pub"
    var loadedInAgent: Bool

    enum SSHKeyType: String, CaseIterable {
        case ed25519
        case rsa
        case ecdsa
        case dsa
        case encrypted
        case unknown

        /// Non-localized type identifier for internal use
        var typeCode: String {
            switch self {
            case .ed25519: return "Ed25519"
            case .rsa: return "RSA"
            case .ecdsa: return "ECDSA"
            case .dsa: return "DSA"
            case .encrypted: return "Encrypted"
            case .unknown: return "Unknown"
            }
        }

        /// Localized display label — call from @MainActor context
        @MainActor
        var label: String {
            switch self {
            case .ed25519: return "Ed25519"
            case .rsa: return "RSA"
            case .ecdsa: return "ECDSA"
            case .dsa: return "DSA"
            case .encrypted: return L("加密")
            case .unknown: return L("未知")
            }
        }
    }
}

// MARK: - Settings tab

/// SSH key management panel shown as the "密钥" tab in Settings.
struct KeyManagementView: View {
    @State private var keys: [SSHKeyInfo] = []
    @State private var showGenerateSheet = false
    @State private var errorMessage: String?

    private let sshDir: String = {
        ("~/.ssh" as NSString).expandingTildeInPath
    }()

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack {
                Text(L("SSH 密钥"))
                    .font(.title3.weight(.semibold))
                Spacer()
                HStack(spacing: DS.Space.s) {
                    Button {
                        refreshKeys()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help(L("刷新"))
                    Button {
                        showGenerateSheet = true
                    } label: {
                        Image(systemName: "plus")
                    }
                    .help(L("生成新密钥"))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            if let error = errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            }

            if keys.isEmpty {
                VStack(spacing: DS.Space.m) {
                    Image(systemName: "key.slash")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)
                    Text(L("~/.ssh 中没有找到私钥。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text(L("点击 + 生成新密钥，或将已有的私钥文件复制到 ~/.ssh 目录。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(keys) { key in
                        KeyRowView(key: key, onRefresh: refreshKeys)
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(width: 520, height: 420)
        .onAppear { refreshKeys() }
        .sheet(isPresented: $showGenerateSheet) {
            GenerateKeySheet(isPresented: $showGenerateSheet, sshDir: sshDir, onGenerated: refreshKeys)
                .localized(LocalizationManager.shared)
        }
    }

    private func refreshKeys() {
        errorMessage = nil
        keys = scanSSHDirectory(sshDir: sshDir)
        Task {
            await checkAgentLoaded()
        }
    }

    /// Query `ssh-add -L` once and mark which keys are loaded in the agent.
    private func checkAgentLoaded() async {
        let output = await AuxProcess.run(
            argv: ["/usr/bin/ssh-add", "-L"],
            timeout: 3
        )
        guard output.exitCode == 0 else {
            // Agent not running or no identities
            for i in keys.indices { keys[i].loadedInAgent = false }
            return
        }
        let agentLines = output.stdoutText
            .split(separator: "\n")
            .map(String.init)

        // Match by pubkey content fingerprint — we compare the base64 key material
        var loadedPaths = Set<String>()
        for keyInfo in keys {
            let pubPath = keyInfo.pubKeyPath
            guard FileManager.default.fileExists(atPath: pubPath),
                  let pubContent = try? String(contentsOfFile: pubPath, encoding: .utf8)
            else { continue }
            // Extract the base64 key part (middle field in "type key comment")
            let parts = pubContent.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let keyMaterial = String(parts[1])

            // ssh-add -L prints full public keys ("type base64 comment"), so the
            // base64 key material appears verbatim when the key is loaded.
            let found = agentLines.contains { line in
                line.contains(keyMaterial)
            }
            if found {
                loadedPaths.insert(keyInfo.fullPath)
            }
        }

        for i in keys.indices {
            keys[i].loadedInAgent = loadedPaths.contains(keys[i].fullPath)
        }
    }
}

// MARK: - Key row

private struct KeyRowView: View {
    let key: SSHKeyInfo
    let onRefresh: () -> Void
    @State private var addToAgentFeedback: String?
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: DS.Space.m) {
            // Icon
            Image(systemName: key.loadedInAgent ? "key.fill" : "key")
                .foregroundStyle(key.loadedInAgent ? Color.green : .secondary)
                .frame(width: 20)

            // Info
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: key.fileName)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Text(verbatim: key.keyType.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if key.hasPubKey {
                        Text(verbatim: ".pub")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    if key.loadedInAgent {
                        Text(L("已在 Agent 中"))
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
            }

            Spacer()

            // Action buttons
            HStack(spacing: 6) {
                if let msg = addToAgentFeedback, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }

                if !key.loadedInAgent {
                    Button(L("添加到 Agent")) {
                        addToAgent()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                if key.hasPubKey {
                    Button(L("复制公钥")) {
                        copyPubKey()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button(L("删除…")) {
                showDeleteConfirmation = true
            }
            if key.hasPubKey {
                Button(L("复制公钥")) {
                    copyPubKey()
                }
            }
        }
        .alert(L("删除“%@”？", key.fileName), isPresented: $showDeleteConfirmation) {
            Button(L("取消"), role: .cancel) { }
            Button(L("删除"), role: .destructive) {
                deleteKey()
            }
        } message: {
            Text(L("删除 %@？此操作无法撤销。", key.fileName))
        }
    }

    private func addToAgent() {
        Task {
            let result = await AuxProcess.run(
                argv: ["/usr/bin/ssh-add", key.fullPath],
                timeout: 10
            )
            await MainActor.run {
                if result.exitCode == 0 {
                    addToAgentFeedback = L("已添加")
                    onRefresh()
                } else {
                    let msg = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    addToAgentFeedback = msg.isEmpty ? L("添加失败") : msg
                }
                // Auto-clear feedback after 3 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    addToAgentFeedback = nil
                }
            }
        }
    }

    private func copyPubKey() {
        guard let content = try? String(contentsOfFile: key.pubKeyPath, encoding: .utf8) else {
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
    }

    private func deleteKey() {
        let urls = [
            URL(fileURLWithPath: key.fullPath),
            URL(fileURLWithPath: key.pubKeyPath)
        ].filter { FileManager.default.fileExists(atPath: $0.path) }

        // Try to move each file to trash individually. Only fall back to
        // permanent deletion for files that failed to trash — never batch-delete
        // all files when only one failed (would delete already-trashed files too).
        var untrashed: [URL] = []
        for url in urls {
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                untrashed.append(url)
            }
        }
        for url in untrashed {
            try? FileManager.default.removeItem(at: url)
        }
        onRefresh()
    }
}

// MARK: - Generate key sheet

private struct GenerateKeySheet: View {
    @Binding var isPresented: Bool
    let sshDir: String
    let onGenerated: () -> Void

    @State private var keyName = "id_ed25519"
    @State private var keyType: GenerateKeyType = .ed25519
    @State private var comment = ""
    @State private var passphrase = ""
    @State private var confirmPassphrase = ""
    @State private var isGenerating = false
    @State private var generationError: String?

    enum GenerateKeyType: String, CaseIterable, Identifiable {
        case ed25519
        case rsa4096

        var id: String { rawValue }

        @MainActor
        var label: String {
            switch self {
            case .ed25519: return "Ed25519 (\(L("推荐")))"
            case .rsa4096: return "RSA 4096"
            }
        }
    }

    private var defaultComment: String {
        let user = NSUserName()
        let host = ProcessInfo.processInfo.hostName
        return "\(user)@\(host)"
    }

    // Validate
    private var isValidName: Bool {
        let trimmed = keyName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Must not contain path separators or start with .
        guard !trimmed.contains("/"), !trimmed.hasPrefix(".") else { return false }
        // Must not already exist
        let destPath = "\(sshDir)/\(trimmed)"
        return !FileManager.default.fileExists(atPath: destPath)
            && !FileManager.default.fileExists(atPath: "\(destPath).pub")
    }

    private var passphrasesMatch: Bool {
        passphrase == confirmPassphrase
    }

    private var canGenerate: Bool {
        !isGenerating && isValidName && !passphrase.isEmpty && passphrasesMatch
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("生成 SSH 密钥"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 8)

            Form {
                Section(L("密钥信息")) {
                    TextField(L("密钥名称"), text: $keyName, prompt: Text(verbatim: "id_ed25519"))
                    if !isValidName && !keyName.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(L("名称无效或文件已存在"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Picker(L("密钥类型"), selection: $keyType) {
                        ForEach(GenerateKeyType.allCases) { type in
                            Text(verbatim: type.label).tag(type)
                        }
                    }

                    TextField(L("备注"), text: $comment, prompt: Text(verbatim: defaultComment))
                }

                Section(L("密码保护（必填）")) {
                    SecureField(L("密码"), text: $passphrase, prompt: Text(verbatim: L("用于保护私钥")))
                    SecureField(L("确认密码"), text: $confirmPassphrase, prompt: Text(verbatim: L("再次输入密码")))
                    if passphrase.isEmpty {
                        Text(L("为避免生成无密码保护的私钥，此处不能留空。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !passphrasesMatch {
                        Text(L("两次输入的密码不一致"))
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                if let error = generationError {
                    Section {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(5)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            // Footer
            HStack {
                Spacer()
                HStack(spacing: DS.Space.s) {
                    Button(L("取消"), role: .cancel) { isPresented = false }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button(L("生成")) { generate() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canGenerate)
                    if isGenerating {
                        ProgressView().controlSize(.small)
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 440, height: 400)
        .onAppear {
            comment = defaultComment
        }
    }

    private func generate() {
        guard canGenerate else { return }
        isGenerating = true
        generationError = nil

        let trimmedName = keyName.trimmingCharacters(in: .whitespaces)
        let destPath = "\(sshDir)/\(trimmedName)"
        let finalComment = comment.trimmingCharacters(in: .whitespaces).isEmpty
            ? defaultComment
            : comment.trimmingCharacters(in: .whitespaces)
        guard let helper = SecureAskpassHelper(secret: passphrase) else {
            isGenerating = false
            generationError = L("无法准备密钥生成认证助手。")
            return
        }

        var argv: [String] = ["/usr/bin/ssh-keygen"]
        switch keyType {
        case .ed25519:
            argv.append(contentsOf: ["-t", "ed25519"])
        case .rsa4096:
            argv.append(contentsOf: ["-t", "rsa", "-b", "4096"])
        }
        argv.append(contentsOf: ["-f", destPath, "-C", finalComment, "-q"])
        // ssh-keygen asks for the new passphrase twice. With no tty and
        // SSH_ASKPASS_REQUIRE=force it invokes the helper for both prompts;
        // the passphrase therefore never appears in argv or a plaintext file.
        passphrase = ""
        confirmPassphrase = ""

        Task {
            defer { helper.cleanup() }
            let result = await AuxProcess.run(
                argv: argv,
                environment: helper.environment,
                timeout: 15
            )
            await MainActor.run {
                isGenerating = false
                if result.exitCode == 0 {
                    isPresented = false
                    onGenerated()
                } else {
                    let msg = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
                    generationError = msg.isEmpty
                        ? L("密钥生成失败（退出码 %lld）", result.exitCode)
                        : msg
                }
            }
        }
    }
}

// MARK: - Scanning helpers

/// Scan ~/.ssh for private keys
func scanSSHDirectory(sshDir: String) -> [SSHKeyInfo] {
    let fm = FileManager.default
    guard fm.fileExists(atPath: sshDir),
          let contents = try? fm.contentsOfDirectory(atPath: sshDir) else {
        return []
    }

    let skipNames: Set<String> = [
        "known_hosts", "known_hosts.old",
        "authorized_keys", "authorized_keys2",
        "config", "config.d"
    ]

    // The real agent check runs asynchronously after scan

    var results: [SSHKeyInfo] = []

    for name in contents {
        let fullPath = "\(sshDir)/\(name)"

        // Skip .dotfiles, known_hosts, authorized_keys, config, -cert.pub
        if name.hasPrefix(".") { continue }
        if name.hasSuffix("-cert.pub") { continue }
        if skipNames.contains(name) { continue }
        if name.hasSuffix(".pub") { continue }

        // Must be a regular file
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: fullPath, isDirectory: &isDir),
              !isDir.boolValue else { continue }

        // Check if it's a private key by reading first line
        guard let handle = FileHandle(forReadingAtPath: fullPath),
              let headData = try? handle.read(upToCount: 256) else { continue }
        try? handle.close()
        let header = String(decoding: headData, as: UTF8.self)
        let firstLine = header.split(separator: "\n").first.map(String.init) ?? ""

        let keyType: SSHKeyInfo.SSHKeyType
        switch firstLine.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "-----BEGIN OPENSSH PRIVATE KEY-----":
            keyType = .ed25519  // OpenSSH format — most common for ed25519, but could be others; derived heuristically below
        case "-----BEGIN RSA PRIVATE KEY-----":
            keyType = .rsa
        case "-----BEGIN DSA PRIVATE KEY-----":
            keyType = .dsa
        case "-----BEGIN EC PRIVATE KEY-----":
            keyType = .ecdsa
        case "-----BEGIN ENCRYPTED PRIVATE KEY-----":
            keyType = .encrypted
        case "-----BEGIN PRIVATE KEY-----":
            keyType = .unknown  // PKCS#8 — could be anything
        default:
            continue  // Not a private key
        }

        // For OpenSSH format, try to determine actual type
        var resolvedType = keyType
        if keyType == .ed25519 || keyType == .unknown {
            // Try to read the full key to find type hints
            if let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                if content.contains("openssh-key-v1") {
                    // Look at .pub file to determine the exact key algorithm
                    let pubPath = "\(fullPath).pub"
                    if let pubContent = try? String(contentsOfFile: pubPath, encoding: .utf8) {
                        let pubParts = pubContent.split(separator: " ", omittingEmptySubsequences: true)
                        if let algo = pubParts.first {
                            if algo.hasPrefix("ssh-ed25519") {
                                resolvedType = .ed25519
                            } else if algo.hasPrefix("ssh-rsa") {
                                resolvedType = .rsa
                            } else if algo.hasPrefix("ecdsa-sha2-") {
                                resolvedType = .ecdsa
                            } else if algo.hasPrefix("ssh-dss") {
                                resolvedType = .dsa
                            }
                        }
                    }
                } else if content.contains("ENCRYPTED") {
                    resolvedType = .encrypted
                }
            }
        }

        let pubPath = "\(fullPath).pub"
        let hasPub = fm.fileExists(atPath: pubPath)

        results.append(SSHKeyInfo(
            fileName: name,
            fullPath: fullPath,
            keyType: resolvedType,
            hasPubKey: hasPub,
            pubKeyPath: pubPath,
            loadedInAgent: false
        ))
    }

    // Sort: alphabetical by filename
    results.sort { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }

    // Move loaded keys first (done after async check)
    return results
}
