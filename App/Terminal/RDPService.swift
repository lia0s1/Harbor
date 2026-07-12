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
    private var processExited = false
    /// Called with the host ID when the connection exits cleanly (not on error,
    /// so the red dot stays visible until the user explicitly disconnects).
    var onExit: (@MainActor (UUID) -> Void)?

    init(host: SSHHost) {
        self.id = host.id
        self.host = host
    }

    func disconnect() {
        guard let p = process else { return }
        process = nil
        isRunning = false
        processExited = false
        p.terminate() // SIGTERM
        let pid = p.processIdentifier
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, !self.processExited else { return }
            kill(pid, SIGKILL)
        }
    }

    fileprivate func markRunning(_ process: Process) {
        self.process = process
        self.isRunning = true
        self.errorMessage = nil
    }

    fileprivate func markFailed(_ message: String) {
        processExited = true
        self.process = nil
        self.isRunning = false
        self.errorMessage = message
    }

    fileprivate func markExited() {
        processExited = true
        self.process = nil
        self.isRunning = false
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

    private func validateField(_ value: String, name: String) throws {
        if value.isEmpty {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not be empty"])
        }
        if value.hasPrefix("-") {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not start with '-'"])
        }
        let controlChars = CharacterSet(charactersIn: Unicode.Scalar(0x00)! ... Unicode.Scalar(0x1F)!)
            .union(CharacterSet(charactersIn: Unicode.Scalar(0x7F)! ... Unicode.Scalar(0x7F)!))
        if value.unicodeScalars.contains(where: { controlChars.contains($0) }) {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not contain control characters"])
        }
        if value.unicodeScalars.contains(where: { CharacterSet.whitespaces.contains($0) }) {
            throw NSError(domain: "HarborRDP", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "\(name) must not contain whitespace"])
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
        var args: [String] = [
            "/v:\(host.hostname):\(port)",
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

        do {
            try process.run()
            if !password.isEmpty {
                let data = (password + "\n").data(using: .utf8) ?? Data()
                stdinPipe.fileHandleForWriting.write(data)
            }
            stdinPipe.fileHandleForWriting.closeFile()
            connection.markRunning(process)
        } catch {
            connection.markFailed("无法启动 freerdp：\(error.localizedDescription)")
        }
    }

    // MARK: Install hint

    /// Opens Terminal with the brew install command pre-filled.
    func openInstallInstructions() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "tell application \"Terminal\" to do script \"brew install --cask freerdp\""]
        try? p.run()
    }
}
