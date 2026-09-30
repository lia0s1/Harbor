import Foundation
import AppKit
import Darwin
import HarborKit

// MARK: - RDP connection state

@MainActor
final class RDPConnection: ObservableObject, Identifiable {
    let id: UUID
    let host: SSHHost
    @Published private(set) var isRunning = false
    @Published private(set) var errorMessage: String?

    private var process: Process?
    /// A Process has been handed to the background launcher but has not yet
    /// been published on the main actor. A disconnect in this interval must
    /// wait for that hand-off instead of letting app termination race it.
    private var launchInProgress = false
    /// A TERM/KILL sequence is in flight. Multiple callers (for example a tab
    /// close followed by app quit) join the same bounded cleanup rather than
    /// treating a nil `process` as proof that the child is gone.
    private var terminationInProgress = false
    private var terminationCompletions: [@Sendable () -> Void] = []
    /// Set as soon as the user disconnects, including the short interval before
    /// the background launcher has returned a Process to the main actor.
    private var disconnectRequested = false
    /// Called with the host ID when the connection exits cleanly (not on error,
    /// so the red dot stays visible until the user explicitly disconnects).
    var onExit: (@MainActor (UUID) -> Void)?

    init(host: SSHHost) {
        self.id = host.id
        self.host = host
    }

    func disconnect(completion: @escaping @Sendable () -> Void = {}) {
        disconnectRequested = true
        guard let p = process else {
            isRunning = false
            if launchInProgress || terminationInProgress {
                terminationCompletions.append(completion)
            } else {
                completion()
            }
            return
        }
        terminate(p, completion: completion)
    }

    fileprivate func markLaunching() {
        launchInProgress = true
    }

    private func terminate(_ p: Process, completion: @escaping @Sendable () -> Void = {}) {
        if terminationInProgress {
            terminationCompletions.append(completion)
            return
        }
        terminationInProgress = true
        terminationCompletions.append(completion)
        process = nil
        isRunning = false
        p.terminate() // SIGTERM
        let pid = p.processIdentifier
        // Retain the connection and Process through the escalation window. The
        // session manager may have removed it from its dictionary already, but
        // that must not turn a TERM-resistant child into an orphan.
        DispatchQueue.global(qos: .utility).async { [self, p] in
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if p.isRunning && pid > 0 {
                kill(pid, SIGKILL)
            }
            p.waitUntilExit()
            Task { @MainActor [self] in
                finishTermination()
            }
        }
    }

    private func finishTermination() {
        guard terminationInProgress || !terminationCompletions.isEmpty else { return }
        terminationInProgress = false
        let completions = terminationCompletions
        terminationCompletions.removeAll()
        for completion in completions { completion() }
    }

    fileprivate func markRunning(_ process: Process) {
        launchInProgress = false
        // `disconnect()` can run while RDPService is still in Process.run() on
        // its launch queue. Never publish a process that was cancelled during
        // that window: terminate and reap it instead.
        if disconnectRequested {
            terminate(process)
            return
        }
        self.process = process
        self.isRunning = true
        self.errorMessage = nil
    }

    fileprivate func markFailed(_ message: String) {
        launchInProgress = false
        self.process = nil
        self.isRunning = false
        self.errorMessage = message
        finishTermination()
    }

    fileprivate func markExited() {
        launchInProgress = false
        self.process = nil
        self.isRunning = false
        finishTermination()
        onExit?(id)
    }
}

// MARK: - RDP service

/// Launches and manages freerdp connections for Windows RDP hosts.
@MainActor
final class RDPService {
    /// Known paths where freerdp/xfreerdp may be installed (Homebrew Intel/ARM + MacPorts).
    private static let freerdpCandidates = [
        "/opt/homebrew/bin/xfreerdp",
        "/usr/local/bin/xfreerdp",
        "/opt/local/bin/xfreerdp",
        "/opt/homebrew/bin/freerdp",
        "/usr/local/bin/freerdp",
    ]

    /// Static check used by views that need to know if freerdp is available
    /// before a RDPService instance exists (e.g. HostListView's connect guard).
    static var isFreerdpInstalled: Bool {
        freerdpCandidates.contains(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Resolved path to xfreerdp binary, if installed.
    private(set) lazy var freerdpPath: String? = {
        for path in Self.freerdpCandidates {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }()

    var isFreerdpInstalled: Bool { freerdpPath != nil }

    // MARK: Connect

    /// CharacterSet covering ASCII control characters (0x00–0x1F) and DEL (0x7F).
    private static let controlCharacterSet: CharacterSet = {
        // All values are guaranteed valid Unicode scalars; guard against
        // the failable init as a defensive measure.
        guard let lo = Unicode.Scalar(0x00),
              let hi = Unicode.Scalar(0x1F),
              let del = Unicode.Scalar(0x7F) else {
            return CharacterSet.controlCharacters
        }
        return CharacterSet(charactersIn: lo ... hi)
            .union(CharacterSet(charactersIn: del ... del))
    }()

    private func validateField(_ value: String, name: String) throws {
        if value.isEmpty {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not be empty"])
        }
        if value.hasPrefix("-") {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not start with '-'"])
        }
        let controlChars = Self.controlCharacterSet
        if value.unicodeScalars.contains(where: { controlChars.contains($0) }) {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not contain control characters"])
        }
        if value.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not contain whitespace"])
        }
        if value.contains("[") || value.contains("]") {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "主机名不能包含括号字符"])
        }
    }

    func connect(host: SSHHost, connection: RDPConnection, password: String = "") {
        guard let xfreerdp = freerdpPath else {
            connection.markFailed("未找到 freerdp。请先运行：brew install freerdp")
            return
        }

        do {
            try validateField(host.hostname, name: "hostname")
            guard (1...65535).contains(host.port) else {
                throw NSError(domain: "HarborRDP", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "port must be between 1 and 65535"])
            }
            let user = host.username.trimmingCharacters(in: .whitespaces)
            if !user.isEmpty { try validateField(user, name: "username") }
            let domain = host.rdpDomain.trimmingCharacters(in: .whitespaces)
            if !domain.isEmpty { try validateField(domain, name: "domain") }
        } catch {
            connection.markFailed("输入验证失败：\(error.localizedDescription)")
            return
        }

        let port = host.port
        // FreeRDP requires IPv6 addresses wrapped in brackets: /v:[::1]:3389
        let hostPart = host.hostname.contains(":") ? "[\(host.hostname)]" : host.hostname
        var args: [String] = [
            "/v:\(hostPart):\(port)",
            "/dynamic-resolution",
            "/cert:deny",           // abort on any certificate validation failure
            "+clipboard",
            "/log-level:ERROR",
        ]

        // Username
        let user = host.username.trimmingCharacters(in: .whitespaces)
        if !user.isEmpty { args.append("/u:\(user)") }

        // Domain
        let domain = host.rdpDomain.trimmingCharacters(in: .whitespaces)
        if !domain.isEmpty { args.append("/d:\(domain)") }

        // FreeRDP reads the password from stdin before connecting. It never
        // appears in argv, and strict certificate validation occurs before the
        // credentials can be sent to the server.
        if !password.isEmpty { args.append("/from-stdin:force") }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: xfreerdp)
        process.arguments = args

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe

        // Watch for exit on a background thread, then hop back to main.
        process.terminationHandler = { [weak connection] p in
            let exitCode = p.terminationStatus
            Task { @MainActor in
                if exitCode == 0 {
                    connection?.markExited()
                } else if exitCode == 131 || exitCode == 2 {
                    // 131 = SIGTERM (we terminated it), 2 = user closed window
                    connection?.markExited()
                } else {
                    connection?.markFailed("freerdp 退出码 \(exitCode)，请检查主机地址、端口、证书信任和凭据。")
                }
            }
        }

        // Process.run() is a synchronous fork+exec; run off the main actor so
        // a slow freerdp launch (probe, DNS) never stalls the UI.
        // Keep the connection alive through the launch hand-off. If the UI
        // removes it during this interval, its cancellation bit still reaches
        // markRunning and the just-started child is terminated instead of
        // becoming orphaned.
        connection.markLaunching()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try process.run()
                if !password.isEmpty {
                    let data = (password + "\n").data(using: .utf8) ?? Data()
                    try stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                stdinPipe.fileHandleForWriting.closeFile()
                Task { @MainActor in
                    connection.markRunning(process)
                }
            } catch {
                Task { @MainActor in
                    connection.markFailed("无法启动 freerdp：\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Install hint

    /// Opens Terminal with the brew install command pre-filled.
    func openInstallInstructions() {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "tell application \"Terminal\" to do script \"brew install --cask freerdp\""]
            try? p.run()
        }
    }
}
