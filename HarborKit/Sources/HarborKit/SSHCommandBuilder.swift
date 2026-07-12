import Foundation

/// Errors produced when an `SSHHost` cannot be turned into a safe ssh argv.
public enum SSHCommandError: Error, Equatable, LocalizedError {
    case emptyHostname
    case unsafeValue(field: String, value: String)
    case invalidPort(Int)

    public var errorDescription: String? {
        switch self {
        case .emptyHostname:
            return "Hostname is empty."
        case .unsafeValue(let field, let value):
            return "Unsafe \(field): \u{201C}\(value)\u{201D}"
        case .invalidPort(let port):
            return "Invalid port: \(port)"
        }
    }
}

/// Builds the argv (excluding the executable path) for `/usr/bin/ssh` from an `SSHHost`.
///
/// Pure logic, no side effects. Rejects values that could be parsed as ssh
/// options (argument injection): leading "-" in hostname/username/identityFile,
/// and whitespace or control characters in hostname/username.
public enum SSHCommandBuilder {
    public static let executablePath = "/usr/bin/ssh"

    /// Default options applied to every connection. `ConnectTimeout=10` bounds
    /// the TCP/connection establishment so an unreachable host fails in ~10s
    /// instead of the ~75s system default — fast failure feedback, and it lets
    /// the auto-reconnect backoff escalate and give up correctly (a host that
    /// took 75s to fail would defeat any reasonable stability window). It only
    /// caps connection setup, never the interactive auth wait (password/2FA).
    public static let defaultOptions: [String] = [
        "-o", "ServerAliveInterval=30",
        "-o", "ConnectTimeout=10",
    ]

    /// Multiplexing options for the MAIN interactive session: it becomes (or
    /// joins) the ControlMaster at the given socket path, so auxiliary
    /// commands (monitoring, files) can piggyback without re-authenticating.
    /// The socket path must already be expanded (no `%C`/`%h` tokens) so the
    /// app and aux commands share the same literal path.
    public static func multiplexingOptions(controlSocketPath: String) -> [String] {
        [
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "ControlPersist=no",
        ]
    }

    public static func arguments(for host: SSHHost, controlSocketPath: String? = nil) throws -> [String] {
        let hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        guard !hostname.isEmpty else { throw SSHCommandError.emptyHostname }
        try validate(hostname, field: "hostname")

        let username = host.username.trimmingCharacters(in: .whitespaces)
        if !username.isEmpty {
            try validate(username, field: "username")
        }

        guard (1...65535).contains(host.port) else {
            throw SSHCommandError.invalidPort(host.port)
        }

        var args: [String] = []
        args.append(contentsOf: defaultOptions)

        if let socket = controlSocketPath?.trimmingCharacters(in: .whitespaces), !socket.isEmpty {
            try validateNoSpacesOrControlCharacters(socket, field: "controlSocketPath")
            args.append(contentsOf: multiplexingOptions(controlSocketPath: socket))
        }

        if host.port != SSHHost.defaultPort {
            args.append(contentsOf: ["-p", String(host.port)])
        }

        if let identity = host.identityFile?.trimmingCharacters(in: .whitespaces),
           !identity.isEmpty {
            try validateNoLeadingDash(identity, field: "identityFile")
            try validateNoControlCharacters(identity, field: "identityFile")
            args.append(contentsOf: ["-i", identity])
        }

        for forward in host.portForwards {
            args.append(contentsOf: try forwardArguments(for: forward))
        }

        try validateExtraArgs(host.extraArgs)
        args.append(contentsOf: host.extraArgs)

        args.append(destination(for: host))

        // Custom remote shell (e.g. powershell.exe / cmd.exe for Windows SSH).
        // SSH does not allocate a PTY when a remote command is given; `-t` forces
        // one so the shell is interactive inside the terminal emulator.
        let shell = host.shell.trimmingCharacters(in: .whitespaces)
        if !shell.isEmpty {
            try validateNoLeadingDash(shell, field: "shell")
            try validateNoControlCharacters(shell, field: "shell")
            // Insert -t before the destination so the server allocates a PTY.
            if let destIndex = args.indices.last {
                args.insert("-t", at: destIndex)
            }
            args.append(shell)
        }

        return args
    }

    /// Full argv including the ssh executable path, convenient for spawning.
    public static func command(for host: SSHHost, controlSocketPath: String? = nil) throws -> [String] {
        [executablePath] + (try arguments(for: host, controlSocketPath: controlSocketPath))
    }

    /// The `[user@]host` destination argument, trimmed the same way
    /// `arguments(for:)` builds it. Pure string assembly — no validation.
    public static func destination(for host: SSHHost) -> String {
        let hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        let username = host.username.trimmingCharacters(in: .whitespaces)
        return username.isEmpty ? hostname : "\(username)@\(hostname)"
    }

    // MARK: - Auxiliary (multiplexed) commands

    /// Full argv for an auxiliary command that piggybacks on a live
    /// ControlMaster connection: never opens its own auth prompt
    /// (BatchMode=yes) and never becomes a master itself (ControlMaster=no).
    /// `remoteScript` stays ONE argv element; the remote shell parses it.
    public static func auxiliaryCommand(
        controlSocketPath: String,
        destination: String,
        remoteScript: String,
        port: Int? = nil
    ) -> [String] {
        assertSafeSocketPath(controlSocketPath)
        var argv: [String] = [
            executablePath,
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "BatchMode=yes",
        ]
        if let port, port != SSHHost.defaultPort {
            argv.append(contentsOf: ["-p", String(port)])
        }
        argv.append(destination)
        argv.append(remoteScript)
        return argv
    }

    /// Full argv for `ssh -O check`: exit 0 means the master at the socket is
    /// alive and auxiliary commands will multiplex over it.
    public static func controlCheckCommand(controlSocketPath: String, destination: String) -> [String] {
        assertSafeSocketPath(controlSocketPath)
        return [
            executablePath,
            "-o", "ControlPath=\(controlSocketPath)",
            "-O", "check",
            destination,
        ]
    }

    // MARK: - sftp (batch over the multiplexed connection)

    public static let sftpExecutablePath = "/usr/bin/sftp"

    /// Full argv for `sftp -b -` piggybacking on a live ControlMaster
    /// connection: the batch script (built with `SFTPBatch`) is fed via
    /// stdin, BatchMode guarantees no interactive prompt, and the command
    /// never becomes a master itself.
    public static func sftpBatchCommand(
        controlSocketPath: String,
        destination: String,
        port: Int? = nil
    ) -> [String] {
        assertSafeSocketPath(controlSocketPath)
        var argv: [String] = [
            sftpExecutablePath,
            "-b", "-",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=\(controlSocketPath)",
            "-o", "BatchMode=yes",
        ]
        if let port, port != SSHHost.defaultPort {
            argv.append(contentsOf: ["-P", String(port)]) // sftp's port flag is -P
        }
        argv.append(destination)
        return argv
    }

    // MARK: - Forwards

    /// Arguments for a single forwarding rule (`-L`/`-R`/`-D`). Public so UI
    /// validation can name the offending rule instead of the whole host.
    public static func forwardArguments(for forward: PortForward) throws -> [String] {
        guard (1...65535).contains(forward.bindPort) else {
            throw SSHCommandError.invalidPort(forward.bindPort)
        }

        let bindPrefix: String
        if let bind = forward.bindAddress?.trimmingCharacters(in: .whitespaces), !bind.isEmpty {
            try validate(bind, field: "bindAddress")
            bindPrefix = "\(bind):"
        } else {
            bindPrefix = ""
        }

        switch forward.kind {
        case .dynamic:
            return ["-D", "\(bindPrefix)\(forward.bindPort)"]
        case .local, .remote:
            let target = forward.targetHost.trimmingCharacters(in: .whitespaces)
            guard !target.isEmpty else {
                throw SSHCommandError.unsafeValue(field: "targetHost", value: forward.targetHost)
            }
            try validate(target, field: "targetHost")
            guard (1...65535).contains(forward.targetPort) else {
                throw SSHCommandError.invalidPort(forward.targetPort)
            }
            let flag = forward.kind == .local ? "-L" : "-R"
            return [flag, "\(bindPrefix)\(forward.bindPort):\(target):\(forward.targetPort)"]
        }
    }

    // MARK: - Live forward control

    /// Builds `ssh -S <socket> -O forward <forward-args> <dest>` to ADD a
    /// port forward to an already-running ControlMaster connection without
    /// disconnecting. The forward args follow the same `-L`/`-R`/`-D` format
    /// that `forwardArguments(for:)` produces.
    public static func controlForwardCommand(
        controlSocketPath: String,
        destination: String,
        forward: PortForward
    ) throws -> [String] {
        assertSafeSocketPath(controlSocketPath)
        let args = try forwardArguments(for: forward)
        return [executablePath, "-S", controlSocketPath, "-O", "forward"] + args + [destination]
    }

    /// Builds `ssh -S <socket> -O cancel <forward-args> <dest>` to REMOVE a
    /// port forward from a running ControlMaster connection. The forward args
    /// exactly match the ADD command so the master can identify the rule.
    public static func controlCancelForwardCommand(
        controlSocketPath: String,
        destination: String,
        forward: PortForward
    ) throws -> [String] {
        assertSafeSocketPath(controlSocketPath)
        let args = try forwardArguments(for: forward)
        return [executablePath, "-S", controlSocketPath, "-O", "cancel"] + args + [destination]
    }

    // MARK: - Validation

    /// Debug-time guard: fires if a caller ever passes a tainted socket path to
    /// an auxiliary builder. In release builds the bad path is passed through
    /// and ssh rejects it with an error rather than executing dangerous code.
    /// Current callers always supply a hex-derived path from ControlMasterSupport,
    /// so this assertion should never fire in practice.
    private static func assertSafeSocketPath(_ path: String) {
        assert(
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
            "controlSocketPath contains control characters: \(path)"
        )
    }

    /// Rejects leading dash, whitespace, and control characters.
    static func validate(_ value: String, field: String) throws {
        try validateNoLeadingDash(value, field: field)
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) {
            throw SSHCommandError.unsafeValue(field: field, value: value)
        }
    }

    static func validateNoLeadingDash(_ value: String, field: String) throws {
        if value.hasPrefix("-") {
            throw SSHCommandError.unsafeValue(field: field, value: value)
        }
    }

    static func validateNoControlCharacters(_ value: String, field: String) throws {
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw SSHCommandError.unsafeValue(field: field, value: value)
        }
    }

    /// Rejects control characters and whitespace (but allows leading dash, since
    /// extraArgs is explicitly for flags like `-o Compression=yes`).
    static func validateNoSpacesOrControlCharacters(_ value: String, field: String) throws {
        if value.unicodeScalars.contains(where: {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
        }) {
            throw SSHCommandError.unsafeValue(field: field, value: value)
        }
    }

    /// Extra ssh arguments are deliberately a small allowlist.  OpenSSH grows
    /// new configuration keywords over time and several innocent-looking ones
    /// execute local programs (`KnownHostsCommand`), load local code
    /// (`PKCS11Provider` / `SecurityKeyProvider`), replace host verification, or
    /// redirect the connection through another control socket.  A denylist is
    /// therefore not a safe boundary for hosts loaded from an import file.
    ///
    /// Options that have first-class Harbor fields (identity, port, forwarding,
    /// destination) are also omitted: there must be one validated source of
    /// truth for those values.
    private static func validateExtraArgs(_ args: [String]) throws {
        let standalone: Set<String> = [
            "-4", "-6", "-C", "-N", "-T", "-a", "-n", "-q", "-t",
            "-v", "-vv", "-vvv", "-x",
        ]
        let safeOptions: Set<String> = [
            "addressfamily", "batchmode", "bindaddress",
            "bindinterface", "casignaturealgorithms",
            "ciphers", "compression", "connectionattempts", "connecttimeout",
            "enableescapecommandline", "escapechar", "exitonforwardfailure",
            "fingerprinthash", "hostbasedacceptedalgorithms",
            "hostbasedauthentication", "hostkeyalgorithms", "identitiesonly", "ipqos",
            "kbdinteractiveauthentication", "kbdinteractivedevices",
            "kexalgorithms", "loglevel", "logverbose", "macs",
            "numberofpasswordprompts", "obscurekeystroketiming",
            "passwordauthentication", "preferredauthentications",
            "pubkeyacceptedalgorithms", "pubkeyauthentication", "rekeylimit",
            "requesttty", "serveralivecountmax",
            "serveraliveinterval", "setenv", "streamlocalbindmask",
            "tcpkeepalive", "usekeychain", "visualhostkey",
        ]

        var index = 0
        while index < args.count {
            let arg = args[index]
            try validateNoSpacesOrControlCharacters(arg, field: "extraArgs")

            if standalone.contains(arg) {
                index += 1
                continue
            }

            let option: String
            if arg == "-o" {
                guard index + 1 < args.count else {
                    throw SSHCommandError.unsafeValue(field: "extraArgs", value: arg)
                }
                option = args[index + 1]
                try validateNoSpacesOrControlCharacters(option, field: "extraArgs")
                index += 2
            } else if arg.hasPrefix("-o"), arg.count > 2 {
                option = String(arg.dropFirst(2)).trimmingPrefix("=")
                index += 1
            } else {
                throw SSHCommandError.unsafeValue(field: "extraArgs", value: arg)
            }

            guard let separator = option.firstIndex(of: "="), separator != option.startIndex else {
                throw SSHCommandError.unsafeValue(field: "extraArgs", value: option)
            }
            let name = option[..<separator].lowercased()
            guard safeOptions.contains(name) else {
                throw SSHCommandError.unsafeValue(field: "extraArgs", value: option)
            }
        }
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}
