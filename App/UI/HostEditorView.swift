import SwiftUI
import AppKit
import HarborKit

/// Full add/edit host form: connection basics, identity file picker, tags,
/// notes, extra arguments, and an editable port-forward list.
///
/// Validation mirrors SSHCommandBuilder so anything saved here is guaranteed
/// to produce a safe ssh argv. Save stays disabled (with an inline error)
/// until the draft validates.
struct HostEditorView: View {
    let title: String
    /// Already-localized; defaults to a localized "保存" when not supplied.
    let saveLabel: String
    let onSave: (SSHHost) -> Void

    @Environment(\.dismiss) private var dismiss

    // Identity preserved across edits so HostStore.update finds the host.
    private let hostID: UUID
    // Auto-detected OS badge fields the form does not edit. Carried through so
    // saving an edit (rename, tag, port-forward…) never wipes the sidebar's
    // distro badge that SessionManager.recordOS persisted on connect.
    private let osID: String?
    private let osName: String?

    @State private var name: String
    @State private var hostname: String
    @State private var portText: String
    @State private var username: String
    @State private var identityFile: String
    @State private var tagsText: String
    @State private var extraArgsText: String
    @State private var notes: String
    @State private var forwards: [ForwardDraft]
    @State private var connectionProtocol: ConnectionProtocol
    @State private var rdpDomain: String
    @State private var shell: String

    /// Snapshot of every field at init, so a pristine (untouched) form can be
    /// told apart from one the user has edited.
    private let initialDraft: DraftSnapshot
    /// True once the hostname field has changed at all, so typing a hostname
    /// and deleting it again still explains the disabled Save button.
    @State private var hostnameWasEdited = false

    /// Transient password used only for one-click passwordless setup; never saved.
    @State private var setupPassword = ""
    @State private var setupStatus: SetupStatus = .idle

    private enum SetupStatus: Equatable {
        case idle, running
        case success(String)
        case failure(String)
    }

    init(
        title: String,
        saveLabel: String? = nil,
        host: SSHHost = SSHHost(),
        onSave: @escaping (SSHHost) -> Void
    ) {
        self.title = title
        self.saveLabel = saveLabel ?? L("保存")
        self.onSave = onSave
        self.hostID = host.id
        self.osID = host.osID
        self.osName = host.osName
        _name = State(initialValue: host.name)
        _hostname = State(initialValue: host.hostname)
        _portText = State(initialValue: host.port == SSHHost.defaultPort ? "" : String(host.port))
        _username = State(initialValue: host.username)
        _identityFile = State(initialValue: host.identityFile ?? "")
        _tagsText = State(initialValue: host.tags.joined(separator: ", "))
        _extraArgsText = State(initialValue: host.extraArgs.joined(separator: " "))
        _notes = State(initialValue: host.notes)
        _forwards = State(initialValue: host.portForwards.map(ForwardDraft.init))
        _connectionProtocol = State(initialValue: host.connectionProtocol)
        _rdpDomain = State(initialValue: host.rdpDomain)
        _shell = State(initialValue: host.shell)
        initialDraft = DraftSnapshot(
            name: host.name,
            hostname: host.hostname,
            portText: host.port == SSHHost.defaultPort ? "" : String(host.port),
            username: host.username,
            identityFile: host.identityFile ?? "",
            tagsText: host.tags.joined(separator: ", "),
            extraArgsText: host.extraArgs.joined(separator: " "),
            notes: host.notes,
            forwards: host.portForwards.map(ForwardDraft.init),
            connectionProtocol: host.connectionProtocol,
            rdpDomain: host.rdpDomain,
            shell: host.shell
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 8)

            Form {
                connectionSection
                identitySection
                organizationSection
                forwardsSection
                advancedSection
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 520, height: 600)
        .onChange(of: hostname) { hostnameWasEdited = true }
    }

    // MARK: - Sections

    private var connectionSection: some View {
        Section(L("连接")) {
            Picker(L("协议"), selection: $connectionProtocol) {
                Label("SSH", systemImage: "terminal")
                    .tag(ConnectionProtocol.ssh)
                Label("RDP（Windows）", systemImage: "desktopcomputer")
                    .tag(ConnectionProtocol.rdp)
            }
            .onChange(of: connectionProtocol) { _, proto in
                // Auto-adjust default port when switching protocols
                let currentPort = Int(portText.trimmingCharacters(in: .whitespaces))
                switch proto {
                case .rdp:
                    if portText.isEmpty || currentPort == SSHHost.defaultPort {
                        portText = String(SSHHost.defaultRDPPort)
                    }
                case .ssh, .local:
                    if currentPort == SSHHost.defaultRDPPort {
                        portText = ""
                    }
                }
            }
            TextField(L("名称"), text: $name, prompt: Text(verbatim: L("可选的显示名称")))
            TextField(L("主机名"), text: $hostname, prompt: Text(verbatim: "192.168.1.1"))
            TextField(
                L("端口"),
                text: $portText,
                prompt: Text(verbatim: connectionProtocol == .rdp ? "3389" : "22")
            )
            TextField(L("用户名"), text: $username, prompt: Text(verbatim: L("可选")))
            if connectionProtocol == .rdp {
                TextField(L("域"), text: $rdpDomain, prompt: Text(verbatim: L("CORP（可选）")))
            }
        }
    }

    private var identitySection: some View {
        Section(L("认证")) {
            LabeledContent(L("密钥文件")) {
                HStack(spacing: 6) {
                    TextField(
                        "",
                        text: $identityFile,
                        prompt: Text(verbatim: L("默认密钥 / ssh-agent"))
                    )
                    .labelsHidden()
                    if !identityFile.isEmpty {
                        Button {
                            identityFile = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(L("使用默认密钥"))
                    }
                    Button(L("选择…"), action: chooseIdentityFile)
                }
            }

            // One-click passwordless login: enter the password once and Harbor
            // only appends this Mac's public key to authorized_keys. The host
            // fingerprint must already be trusted through interactive ssh.
            LabeledContent(L("密码")) {
                SecureField(
                    "",
                    text: $setupPassword,
                    prompt: Text(verbatim: L("用于一键免密登录（不会保存）"))
                )
                .labelsHidden()
                .onSubmit(runPasswordlessSetup)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: DS.Space.s) {
                    Button(L("安装公钥并验证登录")) { runPasswordlessSetup() }
                        .disabled(!canSetupPasswordless)
                    if case .running = setupStatus {
                        ProgressView().controlSize(.small).scaleEffect(0.8)
                    }
                }
                Text(L("首次连接请先在“终端”中运行交互式 ssh 并核对主机指纹。Harbor 只安装公钥，不会修改服务器 sshd_config。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                setupStatusLabel
            }
        }
    }

    private var canSetupPasswordless: Bool {
        if case .running = setupStatus { return false }
        return connectionProtocol == .ssh
            && passwordlessPort != nil
            && !setupPassword.isEmpty
            && !hostname.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var passwordlessPort: Int? {
        let value = portText.trimmingCharacters(in: .whitespaces)
        if value.isEmpty { return SSHHost.defaultPort }
        guard let port = Int(value), (1...65535).contains(port) else { return nil }
        return port
    }

    @ViewBuilder private var setupStatusLabel: some View {
        switch setupStatus {
        case .idle, .running:
            EmptyView()
        case .success(let message):
            Label(message, systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func runPasswordlessSetup() {
        let trimmedHost = hostname.trimmingCharacters(in: .whitespaces)
        guard connectionProtocol == .ssh,
              !trimmedHost.isEmpty,
              !setupPassword.isEmpty,
              let port = passwordlessPort
        else { return }
        let host = SSHHost(
            hostname: trimmedHost,
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            identityFile: identityFile.trimmingCharacters(in: .whitespaces).isEmpty
                ? nil
                : identityFile.trimmingCharacters(in: .whitespaces)
        )
        let password = setupPassword
        setupPassword = ""
        setupStatus = .running
        Task {
            let outcome = await PasswordlessSetup.run(host: host, password: password)
            setupStatus = outcome.success ? .success(outcome.message) : .failure(outcome.message)
        }
    }

    private var organizationSection: some View {
        Section(L("分组")) {
            TextField(L("标签"), text: $tagsText, prompt: Text(verbatim: L("prod, web（逗号分隔）")))
            LabeledContent(L("备注")) {
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(height: 56)
                    .scrollContentBackground(.hidden)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(.separator, lineWidth: 1)
                    )
            }
        }
    }

    private var forwardsSection: some View {
        Section {
            ForEach($forwards) { $forward in
                ForwardEditorRow(forward: $forward) {
                    forwards.removeAll { $0.id == forward.id }
                }
            }
        } header: {
            HStack {
                Text(verbatim: L("端口转发"))
                Spacer()
                Button {
                    forwards.append(ForwardDraft())
                } label: {
                    Label(L("添加转发"), systemImage: "plus")
                        .font(.callout)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var advancedSection: some View {
        Section(L("高级")) {
            if connectionProtocol == .ssh {
                LabeledContent(L("登录 Shell")) {
                    Picker("", selection: $shell) {
                        Text(L("服务器默认")).tag("")
                        Text("PowerShell").tag("powershell.exe")
                        Text("CMD").tag("cmd.exe")
                        Text("bash").tag("bash")
                        Text("zsh").tag("zsh")
                        Text("fish").tag("fish")
                    }
                    .labelsHidden()
                    .frame(maxWidth: 160)
                }
                TextField(
                    L("额外参数"),
                    text: $extraArgsText,
                    prompt: Text(verbatim: "-v -o Compression=yes")
                )
                .font(.body.monospaced())
                .help(L("附加在 ssh 命令末尾的参数，直接传给 ssh(1)。这里的 -o 选项会覆盖 Harbor 的内置选项（包括 ProxyCommand、ServerAliveInterval 等），请仅填写你信任的内容。"))
            }
        }
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            if let message = validationMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            GlassEffectContainer(spacing: DS.Space.s) {
                HStack(spacing: DS.Space.s) {
                    Button(L("取消"), role: .cancel) { dismiss() }
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                    Button(saveLabel) { save() }
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!isValid)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Validation & building

    private var buildResult: Result<SSHHost, ValidationFailure> {
        let trimmedHostname = hostname.trimmingCharacters(in: .whitespaces)
        guard !trimmedHostname.isEmpty else {
            // Save disabled; no error banner for a pristine form, but once the
            // user has edited anything, explain what is missing.
            return .failure(ValidationFailure(message: isPristine ? "" : L("请填写主机名。")))
        }

        let trimmedPort = portText.trimmingCharacters(in: .whitespaces)
        let port: Int
        if trimmedPort.isEmpty {
            port = connectionProtocol == .rdp ? SSHHost.defaultRDPPort : SSHHost.defaultPort
        } else if let parsed = Int(trimmedPort), (1...65535).contains(parsed) {
            port = parsed
        } else {
            return .failure(ValidationFailure(message: L("端口必须是 1 到 65535 之间的数字。")))
        }

        var portForwards: [PortForward] = []
        for (index, draft) in forwards.enumerated() {
            switch draft.build() {
            case .success(let forward):
                portForwards.append(forward)
            case .failure(let failure):
                return .failure(ValidationFailure(message: L("转发 %lld：%@", index + 1, failure.message)))
            }
        }

        let trimmedIdentity = identityFile.trimmingCharacters(in: .whitespaces)
        let host = SSHHost(
            id: hostID,
            name: name.trimmingCharacters(in: .whitespaces),
            hostname: trimmedHostname,
            port: port,
            username: username.trimmingCharacters(in: .whitespaces),
            identityFile: trimmedIdentity.isEmpty ? nil : trimmedIdentity,
            extraArgs: extraArgsText.split(whereSeparator: \.isWhitespace).map(String.init),
            portForwards: portForwards,
            tags: parsedTags,
            notes: notes,
            osID: osID,
            osName: osName,
            connectionProtocol: connectionProtocol,
            rdpDomain: rdpDomain.trimmingCharacters(in: .whitespaces),
            shell: shell
        )

        // For SSH hosts, run the same injection-safety check used at connect time.
        if connectionProtocol == .ssh {
            do {
                _ = try SSHCommandBuilder.arguments(for: host)
            } catch {
                return .failure(ValidationFailure(message: harborErrorMessage(error)))
            }
        }
        return .success(host)
    }

    /// Comma-separated -> trimmed, de-duplicated (case-insensitive), in order.
    private var parsedTags: [String] {
        var seen = Set<String>()
        return tagsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Value snapshot of all editable fields, comparable to `initialDraft`.
    private struct DraftSnapshot: Equatable {
        var name: String
        var hostname: String
        var portText: String
        var username: String
        var identityFile: String
        var tagsText: String
        var extraArgsText: String
        var notes: String
        var forwards: [ForwardDraft]
        var connectionProtocol: ConnectionProtocol
        var rdpDomain: String
        var shell: String
    }

    private var isPristine: Bool {
        !hostnameWasEdited && initialDraft == DraftSnapshot(
            name: name,
            hostname: hostname,
            portText: portText,
            username: username,
            identityFile: identityFile,
            tagsText: tagsText,
            extraArgsText: extraArgsText,
            notes: notes,
            forwards: forwards,
            connectionProtocol: connectionProtocol,
            rdpDomain: rdpDomain,
            shell: shell
        )
    }

    private var isValid: Bool {
        if case .success = buildResult { return true }
        return false
    }

    private var validationMessage: String? {
        if case .failure(let failure) = buildResult, !failure.message.isEmpty {
            return failure.message
        }
        return nil
    }

    private func save() {
        guard case .success(let host) = buildResult else { return }
        onSave(host)
        dismiss()
    }

    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        panel.message = L("选择一个私钥文件")
        panel.prompt = L("选择")
        if panel.runModal() == .OK, let url = panel.url {
            identityFile = (url.path as NSString).abbreviatingWithTildeInPath
        }
    }
}

// MARK: - Port forward drafts

/// Validation error carrying a user-facing message.
struct ValidationFailure: Error {
    let message: String
}

/// String-field mirror of `PortForward` so partially-typed rows never crash.
struct ForwardDraft: Identifiable, Equatable {
    let id: UUID
    var kind: PortForward.Kind
    var bindAddress: String
    var bindPortText: String
    var targetHost: String
    var targetPortText: String

    init() {
        id = UUID()
        kind = .local
        bindAddress = ""
        bindPortText = ""
        targetHost = ""
        targetPortText = ""
    }

    init(_ forward: PortForward) {
        id = forward.id
        kind = forward.kind
        bindAddress = forward.bindAddress ?? ""
        bindPortText = String(forward.bindPort)
        targetHost = forward.targetHost
        targetPortText = forward.targetPort == 0 ? "" : String(forward.targetPort)
    }

    @MainActor
    func build() -> Result<PortForward, ValidationFailure> {
        guard let bindPort = Int(bindPortText.trimmingCharacters(in: .whitespaces)),
              (1...65535).contains(bindPort) else {
            return .failure(ValidationFailure(message: L("绑定端口必须在 1 到 65535 之间。")))
        }
        let bind = bindAddress.trimmingCharacters(in: .whitespaces)
        var forward = PortForward(
            id: id,
            kind: kind,
            bindAddress: bind.isEmpty ? nil : bind,
            bindPort: bindPort
        )
        if kind != .dynamic {
            let target = targetHost.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else {
                return .failure(ValidationFailure(message: L("%@转发需要填写目标主机。", kind.label)))
            }
            guard let targetPort = Int(targetPortText.trimmingCharacters(in: .whitespaces)),
                  (1...65535).contains(targetPort) else {
                return .failure(ValidationFailure(message: L("目标端口必须在 1 到 65535 之间。")))
            }
            forward.targetHost = target
            forward.targetPort = targetPort
        }
        // Surface ssh-option injection problems (leading "-", whitespace) here
        // instead of at the whole-host level so the message names the row.
        do {
            _ = try SSHCommandBuilder.forwardArguments(for: forward)
        } catch {
            return .failure(ValidationFailure(message: harborErrorMessage(error)))
        }
        return .success(forward)
    }
}

extension PortForward.Kind {
    @MainActor
    var label: String {
        switch self {
        case .local: return L("本地 (-L)")
        case .remote: return L("远程 (-R)")
        case .dynamic: return L("动态 (-D)")
        }
    }
}

/// One editable forwarding rule: kind picker plus bind/target fields.
struct ForwardEditorRow: View {
    @Binding var forward: ForwardDraft
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker(L("类型"), selection: $forward.kind) {
                    ForEach(PortForward.Kind.allCases, id: \.self) { kind in
                        Text(verbatim: kind.label).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("移除此转发"))
            }
            HStack(spacing: 6) {
                TextField(L("绑定地址"), text: $forward.bindAddress, prompt: Text(verbatim: L("绑定地址（可选）")))
                    .labelsHidden()
                TextField(L("绑定端口"), text: $forward.bindPortText, prompt: Text(verbatim: L("端口")))
                    .labelsHidden()
                    .frame(width: 64)
                if forward.kind != .dynamic {
                    Image(systemName: "arrow.right")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField(L("目标主机"), text: $forward.targetHost, prompt: Text(verbatim: L("目标主机")))
                        .labelsHidden()
                    TextField(L("目标端口"), text: $forward.targetPortText, prompt: Text(verbatim: L("端口")))
                        .labelsHidden()
                        .frame(width: 64)
                }
            }
            .textFieldStyle(.roundedBorder)
        }
        .padding(.vertical, 2)
    }
}
