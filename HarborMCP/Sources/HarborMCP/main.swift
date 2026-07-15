import Foundation
import HarborKit
import Darwin

// Ignore SIGPIPE so writes to a closed pipe return EPIPE instead of crashing.
signal(SIGPIPE, SIG_IGN)

// MARK: - JSON helpers

struct MCPLimits {
    static let production = MCPLimits(
        requestBytes: 8 * 1_024 * 1_024,
        hostStoreBytes: 4 * 1_024 * 1_024,
        processInputBytes: 4 * 1_024 * 1_024,
        processOutputBytes: 4 * 1_024 * 1_024,
        processErrorBytes: 1 * 1_024 * 1_024
    )

    let requestBytes: Int
    let hostStoreBytes: Int
    let processInputBytes: Int
    let processOutputBytes: Int
    let processErrorBytes: Int
}

func jsonEncode(_ obj: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{}"
}

func jsonDecode(_ data: Data) -> [String: Any]? {
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

@discardableResult
func writeAll(fd: Int32, data: Data) -> Bool {
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return true }
        var offset = 0
        while offset < rawBuffer.count {
            let written = Darwin.write(
                fd,
                baseAddress.advanced(by: offset),
                rawBuffer.count - offset
            )
            if written > 0 {
                offset += written
            } else if written == -1 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

@discardableResult
func writeStdout(_ str: String) -> Bool {
    var data = Data(str.utf8)
    data.append(0x0a)
    return writeAll(fd: STDOUT_FILENO, data: data)
}

enum BoundedLine {
    case line(Data)
    case tooLong
}

struct BoundedLineReader {
    private let fd: Int32
    private let maxBytes: Int
    private var buffer = Data()
    private var reachedEOF = false

    init(fd: Int32, maxBytes: Int) {
        self.fd = fd
        self.maxBytes = maxBytes
    }

    mutating func next() throws -> BoundedLine? {
        while true {
            if let newline = buffer.firstIndex(of: 0x0a) {
                var line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0d { line.removeLast() }
                return line.count <= maxBytes ? .line(line) : .tooLong
            }

            if reachedEOF {
                guard !buffer.isEmpty else { return nil }
                defer { buffer.removeAll(keepingCapacity: false) }
                return buffer.count <= maxBytes ? .line(buffer) : .tooLong
            }

            if buffer.count > maxBytes {
                try discardThroughNewline()
                return .tooLong
            }

            try readChunk()
        }
    }

    private mutating func readChunk() throws {
        var bytes = [UInt8](repeating: 0, count: 8_192)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                buffer.append(contentsOf: bytes.prefix(count))
                return
            }
            if count == 0 {
                reachedEOF = true
                return
            }
            if errno != EINTR {
                throw MCPError("读取 MCP 输入失败: \(String(cString: strerror(errno)))")
            }
        }
    }

    private mutating func discardThroughNewline() throws {
        buffer.removeAll(keepingCapacity: true)
        while true {
            try readChunk()
            if let newline = buffer.firstIndex(of: 0x0a) {
                buffer.removeSubrange(...newline)
                return
            }
            if reachedEOF {
                buffer.removeAll(keepingCapacity: false)
                return
            }
            buffer.removeAll(keepingCapacity: true)
        }
    }
}

// MARK: - MCP authorization

/// MCP starts with no remote capability. The user must opt in to specific saved
/// hosts, and destructive operations require separate explicit switches.
struct MCPAuthorization: Sendable, Equatable {
    static let allowedHostsVariable = "HARBOR_MCP_ALLOWED_HOSTS"
    static let runCommandVariable = "HARBOR_MCP_ENABLE_RUN_COMMAND"
    static let writeFileVariable = "HARBOR_MCP_ENABLE_WRITE_FILE"

    let allowedHosts: Set<String>
    let allowsRunCommand: Bool
    let allowsWriteFile: Bool

    static let denyAll = MCPAuthorization(
        allowedHosts: [],
        allowsRunCommand: false,
        allowsWriteFile: false
    )

    init(environment: [String: String]) {
        self.init(
            allowedHosts: Set(
                (environment[Self.allowedHostsVariable] ?? "")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            ),
            allowsRunCommand: environment[Self.runCommandVariable] == "1",
            allowsWriteFile: environment[Self.writeFileVariable] == "1"
        )
    }

    init(allowedHosts: Set<String>, allowsRunCommand: Bool, allowsWriteFile: Bool) {
        self.allowedHosts = Set(allowedHosts.map { $0.lowercased() })
        self.allowsRunCommand = allowsRunCommand
        self.allowsWriteFile = allowsWriteFile
    }

    var hasAuthorizedHosts: Bool { !allowedHosts.isEmpty }

    func allows(_ host: SSHHost) -> Bool {
        allowedHosts.contains(host.displayName.lowercased())
            || allowedHosts.contains(host.hostname.lowercased())
    }
}

// MARK: - MCP Server

struct MCPServer {
    let socketDir: String
    let hostsURL: URL
    let limits: MCPLimits
    let authorization: MCPAuthorization

    init() {
        self.init(
            socketDir: nil,
            hostsURL: nil,
            limits: .production,
            authorization: MCPAuthorization(environment: ProcessInfo.processInfo.environment)
        )
    }

    init(
        socketDir: String?,
        hostsURL: URL?,
        limits: MCPLimits,
        authorization: MCPAuthorization = .denyAll
    ) {
        self.socketDir = socketDir ?? (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/harbor-mcp")
        self.hostsURL = hostsURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Harbor/hosts.json")
        self.limits = limits
        self.authorization = authorization
        try? FileManager.default.createDirectory(
            atPath: self.socketDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700 as AnyObject]
        )
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: self.socketDir
        )
    }

    mutating func run() {
        var reader = BoundedLineReader(fd: STDIN_FILENO, maxBytes: limits.requestBytes)
        while true {
            do {
                guard let item = try reader.next() else { return }
                switch item {
                case .tooLong:
                    if !writeStdout(jsonEncode(rpcError(NSNull(), -32700, "JSON 请求超过大小上限"))) {
                        return
                    }
                case .line(let data):
                    guard !data.isEmpty else { continue }
                    guard let req = jsonDecode(data) else {
                        if !writeStdout(jsonEncode(rpcError(NSNull(), -32700, "Parse error"))) {
                            return
                        }
                        continue
                    }
                    if let resp = handle(req), !writeStdout(jsonEncode(resp)) {
                        return
                    }
                }
            } catch {
                _ = writeStdout(jsonEncode(rpcError(NSNull(), -32603, error.localizedDescription)))
                return
            }
        }
    }

    func handle(_ req: [String: Any]) -> [String: Any]? {
        let id = req["id"]
        let hasId = req.keys.contains("id")

        guard hasId else { return nil } // notifications: no response
        guard let method = req["method"] as? String, !method.isEmpty else {
            return rpcError(id, -32600, "Invalid Request")
        }
        let params: [String: Any]
        if let rawParams = req["params"] {
            guard let object = rawParams as? [String: Any] else {
                return rpcError(id, -32602, "Invalid params")
            }
            params = object
        } else {
            params = [:]
        }

        switch method {
        case "initialize":
            return ok(id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "harbor-mcp", "version": "1.0.0"],
            ])

        case "tools/list":
            return ok(id, result: ["tools": toolList])

        case "tools/call":
            guard let name = params["name"] as? String, !name.isEmpty else {
                return rpcError(id, -32602, "缺少工具名称")
            }
            let args: [String: Any]
            if let rawArguments = params["arguments"] {
                guard let object = rawArguments as? [String: Any] else {
                    return rpcError(id, -32602, "arguments 必须是对象")
                }
                args = object
            } else {
                args = [:]
            }
            let toolResult = callTool(name, args: args)
            return ok(id, result: [
                "content": [["type": "text", "text": toolResult.text] as [String: Any]],
                "isError": toolResult.isError,
            ])

        case "ping":
            return ok(id, result: [:] as [String: Any])

        default:
            return rpcError(id, -32601, "Method not found: \(method)")
        }
    }

    func ok(_ id: Any?, result: [String: Any]) -> [String: Any] {
        var r: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id { r["id"] = id }
        return r
    }

    func rpcError(_ id: Any?, _ code: Int, _ msg: String) -> [String: Any] {
        var r: [String: Any] = ["jsonrpc": "2.0",
                                 "error": ["code": code, "message": msg] as [String: Any]]
        if let id { r["id"] = id }
        return r
    }

    // MARK: - Tool definitions

    private var toolList: [[String: Any]] {
        guard authorization.hasAuthorizedHosts else { return [] }

        var tools = [
            makeTool(
                "list_hosts",
                "列出当前 MCP 明确授权的 Harbor SSH 主机名称与连接参数",
                props: [:],
                required: []
            ),
            makeTool(
                "list_files",
                "列出远程主机上某目录的文件（ls -la）",
                props: [
                    "host": prop("string", "已授权的 Harbor SSH 主机名称"),
                    "path": prop("string", "远程目录路径，默认为 ~（家目录）"),
                ],
                required: ["host"]
            ),
            makeTool(
                "read_file",
                "读取远程主机上的文本文件内容。⚠️ 安全提示：若文件内容由不可信方控制，可能触发提示词注入攻击——攻击者可在文件中嵌入伪造指令，诱导 LLM 通过 run_command 执行任意命令。请勿在启用 run_command 的情况下读取来源不可信的远程文件。",
                props: [
                    "host": prop("string", "已授权的 Harbor SSH 主机名称"),
                    "path": prop("string", "远程文件路径"),
                ],
                required: ["host", "path"]
            ),
            makeTool(
                "get_system_info",
                "获取远程 Linux 主机的实时系统状态：CPU 负载、内存、磁盘、Top 进程",
                props: [
                    "host": prop("string", "已授权的 Harbor SSH 主机名称"),
                ],
                required: ["host"]
            ),
        ]

        if authorization.allowsRunCommand {
            tools.append(makeTool(
                "run_command",
                "在已授权的远程 SSH 主机上执行 shell 命令并返回输出。⚠️ 安全提示：若与 read_file 组合使用，且读取的文件内容由不可信方控制，可能触发提示词注入攻击。建议仅在需要时通过 HARBOR_MCP_ENABLE_RUN_COMMAND=1 启用本工具。",
                props: [
                    "host":            prop("string",  "已授权的 Harbor SSH 主机名称"),
                    "command":         prop("string",  "要在远程执行的 shell 命令"),
                    "timeout":         prop("number",  "超时秒数，默认 30"),
                    "timeout_seconds": prop("integer", "命令超时秒数（默认30，最大300）"),
                ],
                required: ["host", "command"]
            ))
        }

        if authorization.allowsWriteFile {
            tools.append(makeTool(
                "write_file",
                "将文本内容写入已授权远程主机上的文件（覆盖原有内容）。",
                props: [
                    "host":    prop("string", "已授权的 Harbor SSH 主机名称"),
                    "path":    prop("string", "远程文件路径"),
                    "content": prop("string", "要写入的文本内容"),
                ],
                required: ["host", "path", "content"]
            ))
        }

        return tools
    }

    private func makeTool(_ name: String, _ desc: String,
                           props: [String: Any], required: [String]) -> [String: Any] {
        [
            "name": name,
            "description": desc,
            "inputSchema": [
                "type": "object",
                "properties": props,
                "required": required,
            ] as [String: Any],
        ]
    }

    private func prop(_ type: String, _ desc: String) -> [String: Any] {
        ["type": type, "description": desc]
    }

    // MARK: - Tool dispatch

    struct ToolResult {
        let text: String
        let isError: Bool
    }

    func callTool(_ name: String, args: [String: Any]) -> ToolResult {
        do {
            guard authorization.hasAuthorizedHosts else {
                throw MCPError(
                    "MCP 未授权任何主机。启动时设置 \(MCPAuthorization.allowedHostsVariable)=<已保存主机名>。"
                )
            }
            let text: String
            switch name {
            case "list_hosts":      text = try toolListHosts()
            case "run_command":     text = try toolRunCommand(args)
            case "list_files":      text = try toolListFiles(args)
            case "read_file":       text = try toolReadFile(args)
            case "write_file":      text = try toolWriteFile(args)
            case "get_system_info": text = try toolGetSystemInfo(args)
            default: throw MCPError("未知工具: \(name)")
            }
            return ToolResult(text: text, isError: false)
        } catch {
            return ToolResult(text: "错误: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Host resolution

    func loadHosts() throws -> [SSHHost] {
        guard FileManager.default.fileExists(atPath: hostsURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: hostsURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limits.hostStoreBytes + 1) ?? Data()
        guard data.count <= limits.hostStoreBytes else {
            throw MCPError("hosts.json 超过大小上限")
        }

        let hosts = try HostStoreCodec.decode(data)
        for host in hosts {
            do {
                _ = try SSHCommandBuilder.arguments(for: host)
            } catch {
                throw MCPError("已保存主机“\(host.displayName)”的 SSH 配置不安全: \(error.localizedDescription)")
            }
        }
        return hosts
    }

    struct Resolved {
        let host: SSHHost
        let socketPath: String
    }

    func resolve(_ spec: String) throws -> Resolved {
        let normalized = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, normalized.utf8.count <= 512 else {
            throw MCPError("主机名称无效")
        }
        guard !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw MCPError("主机名称无效")
        }

        let hosts = try loadHosts()
        let lower = normalized.lowercased()
        let matches = hosts.filter {
            $0.displayName.lowercased() == lower || $0.hostname.lowercased() == lower
        }
        guard !matches.isEmpty else {
            throw MCPError("找不到已保存主机“\(normalized)”。请使用 list_hosts 查看可用名称。")
        }
        guard matches.count == 1 else {
            throw MCPError("主机名称“\(normalized)”不唯一，请在 Harbor 中设置唯一名称。")
        }
        let host = matches[0]
        guard host.connectionProtocol == .ssh else {
            throw MCPError("主机“\(host.displayName)”不是 SSH 主机")
        }

        // Reuse HarborKit's digest-based naming instead of a collision-prone
        // rolling hash: two chosen saved hosts must never share an authenticated
        // ControlMaster connection. The discriminator isolates these strict MCP
        // sockets from every historical/app socket namespace.
        let fileName = "strict-" + ControlSocket.fileName(
            for: host,
            discriminator: "harbor-mcp-v1"
        )
        let socketPath = (socketDir as NSString)
            .appendingPathComponent(fileName)

        return Resolved(host: host, socketPath: socketPath)
    }

    private enum Capability {
        case read
        case runCommand
        case writeFile
    }

    private func authorizedHost(_ spec: String, capability: Capability = .read) throws -> Resolved {
        let resolved = try resolve(spec)
        guard authorization.allows(resolved.host) else {
            throw MCPError("主机“\(resolved.host.displayName)”不在 \(MCPAuthorization.allowedHostsVariable) 授权清单中")
        }
        switch capability {
        case .read:
            break
        case .runCommand:
            guard authorization.allowsRunCommand else {
                throw MCPError("未启用 run_command。启动时设置 \(MCPAuthorization.runCommandVariable)=1")
            }
        case .writeFile:
            guard authorization.allowsWriteFile else {
                throw MCPError("未启用 write_file。启动时设置 \(MCPAuthorization.writeFileVariable)=1")
            }
        }
        return resolved
    }

    func sshArgv(for r: Resolved, command: String) throws -> [String] {
        guard !command.utf8.contains(0) else { throw MCPError("远程命令包含 NUL 字符") }

        // Validate the complete saved record before removing options that do not
        // apply to a non-interactive MCP command.
        _ = try SSHCommandBuilder.arguments(for: r.host)
        var host = r.host
        host.portForwards = []
        host.shell = ""
        host.extraArgs = mcpCompatibleExtraArgs(host.extraArgs)
        if let identity = host.identityFile {
            host.identityFile = (identity as NSString).expandingTildeInPath
        }

        var argv = try SSHCommandBuilder.command(for: host, controlSocketPath: r.socketPath)
        // OpenSSH uses the first value obtained for most options, so mandatory
        // non-interactive trust settings must precede saved extra arguments.
        argv.insert(contentsOf: [
            "-o", "BatchMode=yes",
            "-o", "StrictHostKeyChecking=yes",
            "-o", "NumberOfPasswordPrompts=0",
            "-o", "ControlPersist=120",
        ], at: 1)
        argv.append(command)
        return argv
    }

    /// Saved options are validated by `SSHCommandBuilder` above. Remove only
    /// the interactive/process-control switches that conflict with an MCP
    /// command's pipe contract (`-n` discards write_file stdin, `-N` suppresses
    /// the command, and PTY/debug options alter or flood structured output).
    private func mcpCompatibleExtraArgs(_ args: [String]) -> [String] {
        let blockedFlags: Set<String> = ["-N", "-n", "-q", "-t", "-v", "-vv", "-vvv"]
        let blockedOptions: Set<String> = [
            "loglevel", "logverbose", "requesttty", "visualhostkey",
        ]
        var result: [String] = []
        var index = 0
        while index < args.count {
            let argument = args[index]
            if blockedFlags.contains(argument) {
                index += 1
                continue
            }
            if argument == "-o", index + 1 < args.count {
                let option = args[index + 1]
                let name = option.prefix { $0 != "=" }.lowercased()
                if !blockedOptions.contains(name) {
                    result.append(argument)
                    result.append(option)
                }
                index += 2
                continue
            }
            if argument.hasPrefix("-o") {
                let option = argument.dropFirst(2).drop(while: { $0 == "=" })
                let name = option.prefix { $0 != "=" }.lowercased()
                if !blockedOptions.contains(name) { result.append(argument) }
                index += 1
                continue
            }
            result.append(argument)
            index += 1
        }
        return result
    }

    // MARK: - Process execution

    struct ExecutionResult {
        let out: String
        let err: String
        let status: Int32
    }

    private enum ProcessAbort: Sendable {
        case outputLimit(String)
        case io(String)
    }

    private final class ProcessState: @unchecked Sendable {
        private let lock = NSLock()
        private var abort: ProcessAbort?

        func markAbort(_ reason: ProcessAbort) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard abort == nil else { return false }
            abort = reason
            return true
        }

        func snapshot() -> ProcessAbort? {
            lock.lock()
            defer { lock.unlock() }
            return abort
        }
    }

    private final class LimitedBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var data = Data()
        private var overflowed = false

        init(limit: Int) {
            self.limit = limit
        }

        func append(_ chunk: Data) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            let available = max(0, limit - data.count)
            if available > 0 {
                data.append(chunk.prefix(available))
            }
            guard chunk.count > available else { return false }
            let firstOverflow = !overflowed
            overflowed = true
            return firstOverflow
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    private struct PipePair {
        let readFD: Int32
        let writeFD: Int32
    }

    private struct SpawnPipes {
        let input: PipePair
        let output: PipePair
        let error: PipePair

        var all: [Int32] {
            [input.readFD, input.writeFD,
             output.readFD, output.writeFD,
             error.readFD, error.writeFD]
        }
    }

    func exec(argv: [String], stdin input: Data? = nil,
              timeout: TimeInterval = 30) throws -> ExecutionResult {
        guard let executable = argv.first, !executable.isEmpty else {
            throw MCPError("缺少可执行文件")
        }
        guard !argv.contains(where: { $0.utf8.contains(0) }) else {
            throw MCPError("进程参数包含 NUL 字符")
        }
        guard timeout.isFinite, timeout > 0 else { throw MCPError("超时时间无效") }
        if let input, input.count > limits.processInputBytes {
            throw MCPError("stdin 超过大小上限")
        }

        let pipes = try makeSpawnPipes()
        var parentOwnsAllPipes = true
        defer {
            if parentOwnsAllPipes {
                pipes.all.forEach { _ = Darwin.close($0) }
            }
        }
        let pid = try spawn(argv: argv, pipes: pipes)

        // The child owns these three ends after posix_spawn's dup2 actions.
        _ = Darwin.close(pipes.input.readFD)
        _ = Darwin.close(pipes.output.writeFD)
        _ = Darwin.close(pipes.error.writeFD)
        parentOwnsAllPipes = false

        let event = DispatchSemaphore(value: 0)
        let state = ProcessState()
        let outBuffer = LimitedBuffer(limit: limits.processOutputBytes)
        let errBuffer = LimitedBuffer(limit: limits.processErrorBytes)
        let group = DispatchGroup()

        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            Self.drain(
                fd: pipes.output.readFD,
                name: "stdout",
                buffer: outBuffer,
                state: state,
                event: event
            )
        }
        group.enter()
        DispatchQueue.global().async {
            defer { group.leave() }
            Self.drain(
                fd: pipes.error.readFD,
                name: "stderr",
                buffer: errBuffer,
                state: state,
                event: event
            )
        }
        group.enter()
        DispatchQueue.global().async {
            defer {
                _ = Darwin.close(pipes.input.writeFD)
                group.leave()
            }
            _ = writeAll(fd: pipes.input.writeFD, data: input ?? Data())
        }

        var timedOut = false
        var rawStatus: Int32 = 0
        var sentTermination = false
        var sentKill = false
        let commandDeadline = DispatchTime.now() + timeout
        var terminationDeadline: DispatchTime?

        while true {
            let waited = Darwin.waitpid(pid, &rawStatus, WNOHANG)
            if waited == pid { break }
            if waited == -1 {
                if errno == EINTR { continue }
                _ = state.markAbort(.io("等待进程失败: \(String(cString: strerror(errno)))"))
                signalProcessGroup(pid, signal: SIGKILL)
                while Darwin.waitpid(pid, &rawStatus, 0) == -1 && errno == EINTR {}
                break
            }

            let now = DispatchTime.now()
            if !sentTermination {
                if state.snapshot() != nil {
                    signalProcessGroup(pid, signal: SIGTERM)
                    sentTermination = true
                    terminationDeadline = now + 2
                } else if now >= commandDeadline {
                    timedOut = true
                    signalProcessGroup(pid, signal: SIGTERM)
                    sentTermination = true
                    terminationDeadline = now + 2
                }
            } else if !sentKill, let terminationDeadline, now >= terminationDeadline {
                signalProcessGroup(pid, signal: SIGKILL)
                sentKill = true
            }

            var wake = now + 0.02
            if !sentTermination, commandDeadline < wake { wake = commandDeadline }
            if let terminationDeadline, !sentKill, terminationDeadline < wake {
                wake = terminationDeadline
            }
            _ = event.wait(timeout: wake)
        }

        group.wait()
        if timedOut { throw MCPError("命令执行超时") }
        if let abort = state.snapshot() {
            switch abort {
            case .outputLimit(let stream):
                throw MCPError("\(stream) 超过大小上限")
            case .io(let message):
                throw MCPError(message)
            }
        }

        return ExecutionResult(
            out: String(decoding: outBuffer.value(), as: UTF8.self),
            err: String(decoding: errBuffer.value(), as: UTF8.self),
            status: exitStatus(from: rawStatus)
        )
    }

    private func makeSpawnPipes() throws -> SpawnPipes {
        var created: [Int32] = []
        do {
            let input = try makePipe()
            created += [input.readFD, input.writeFD]
            let output = try makePipe()
            created += [output.readFD, output.writeFD]
            let error = try makePipe()
            created += [error.readFD, error.writeFD]
            return SpawnPipes(input: input, output: output, error: error)
        } catch {
            created.forEach { _ = Darwin.close($0) }
            throw error
        }
    }

    private func makePipe() throws -> PipePair {
        var descriptors = [Int32](repeating: -1, count: 2)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            Darwin.pipe(buffer.baseAddress!)
        }
        guard result == 0 else {
            throw MCPError("创建进程管道失败: \(String(cString: strerror(errno)))")
        }
        return PipePair(readFD: descriptors[0], writeFD: descriptors[1])
    }

    private func spawn(argv: [String], pipes: SpawnPipes) throws -> pid_t {
        var actions: posix_spawn_file_actions_t? = nil
        var attributes: posix_spawnattr_t? = nil
        var result = posix_spawn_file_actions_init(&actions)
        guard result == 0 else { throw MCPError("初始化进程失败: \(String(cString: strerror(result)))") }
        defer { posix_spawn_file_actions_destroy(&actions) }

        result = posix_spawnattr_init(&attributes)
        guard result == 0 else { throw MCPError("初始化进程失败: \(String(cString: strerror(result)))") }
        defer { posix_spawnattr_destroy(&attributes) }

        let mappings: [(Int32, Int32)] = [
            (pipes.input.readFD, STDIN_FILENO),
            (pipes.output.writeFD, STDOUT_FILENO),
            (pipes.error.writeFD, STDERR_FILENO),
        ]
        for (source, destination) in mappings {
            result = posix_spawn_file_actions_adddup2(&actions, source, destination)
            guard result == 0 else {
                throw MCPError("配置进程管道失败: \(String(cString: strerror(result)))")
            }
        }
        for descriptor in pipes.all where descriptor > STDERR_FILENO {
            result = posix_spawn_file_actions_addclose(&actions, descriptor)
            guard result == 0 else {
                throw MCPError("配置进程管道失败: \(String(cString: strerror(result)))")
            }
        }

        let flags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        result = posix_spawnattr_setflags(&attributes, flags)
        guard result == 0 else { throw MCPError("配置进程失败: \(String(cString: strerror(result)))") }
        result = posix_spawnattr_setpgroup(&attributes, 0)
        guard result == 0 else { throw MCPError("配置进程组失败: \(String(cString: strerror(result)))") }

        var cArguments: [UnsafeMutablePointer<CChar>?] = []
        defer {
            for case let argument? in cArguments { free(argument) }
        }
        for argument in argv {
            guard let copy = strdup(argument) else { throw MCPError("进程参数内存不足") }
            cArguments.append(copy)
        }
        cArguments.append(nil)

        var pid: pid_t = 0
        result = cArguments.withUnsafeMutableBufferPointer { buffer in
            posix_spawn(
                &pid,
                argv[0],
                &actions,
                &attributes,
                buffer.baseAddress!,
                environ
            )
        }
        guard result == 0 else {
            throw MCPError("启动进程失败: \(String(cString: strerror(result)))")
        }
        return pid
    }

    private func signalProcessGroup(_ pid: pid_t, signal: Int32) {
        // This executor is the only waitpid owner. Until it reaps `pid`, the
        // numeric PID cannot be reused, so signalling cannot hit another process.
        if Darwin.kill(-pid, signal) == -1, errno == ESRCH {
            _ = Darwin.kill(pid, signal)
        }
    }

    private func exitStatus(from waitStatus: Int32) -> Int32 {
        let terminationSignal = waitStatus & 0x7f
        if terminationSignal == 0 {
            return (waitStatus >> 8) & 0xff
        }
        return 128 + terminationSignal
    }

    private static func drain(fd: Int32, name: String,
                              buffer: LimitedBuffer, state: ProcessState,
                              event: DispatchSemaphore) {
        defer { _ = Darwin.close(fd) }
        var bytes = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fd, rawBuffer.baseAddress, rawBuffer.count)
            }
            if count > 0 {
                if buffer.append(Data(bytes.prefix(count))),
                   state.markAbort(.outputLimit(name)) {
                    event.signal()
                }
                continue
            }
            if count == 0 { return }
            if errno == EINTR { continue }
            if state.markAbort(.io("读取 \(name) 失败: \(String(cString: strerror(errno)))")) {
                event.signal()
            }
            return
        }
    }

    private func ssh(resolved r: Resolved, command: String, stdin: Data? = nil,
                     timeout: TimeInterval = 30) throws -> String {
        let argv = try sshArgv(for: r, command: command)
        return try checkedSSHOutput(exec(argv: argv, stdin: stdin, timeout: timeout))
    }

    func checkedSSHOutput(_ result: ExecutionResult) throws -> String {
        guard result.status == 0 else {
            let detail = result.err.trimmed.isEmpty ? result.out.trimmed : result.err.trimmed
            let suffix = detail.isEmpty ? "" : ": \(detail)"
            throw MCPError("SSH 命令失败（退出码 \(result.status)）\(suffix)")
        }
        if result.err.isEmpty { return result.out }
        if result.out.isEmpty { return result.err }
        return result.out + (result.out.hasSuffix("\n") ? "" : "\n")
            + "[stderr]\n" + result.err
    }

    // MARK: - Tool implementations

    private func toolListHosts() throws -> String {
        let hosts = try loadHosts().filter {
            $0.connectionProtocol == .ssh && authorization.allows($0)
        }
        guard !hosts.isEmpty else {
            return "没有与 \(MCPAuthorization.allowedHostsVariable) 匹配的已保存 SSH 主机。"
        }
        return hosts.enumerated().map { i, h in
            let dest = SSHCommandBuilder.destination(for: h)
            let port = h.port != SSHHost.defaultPort ? ":\(h.port)" : ""
            var lines = ["\(i + 1). \(h.displayName)  [\(dest)\(port)]"]
            if !h.tags.isEmpty { lines.append("   标签: \(h.tags.joined(separator: ", "))") }
            if !h.notes.isEmpty { lines.append("   备注: \(h.notes)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private func toolRunCommand(_ args: [String: Any]) throws -> String {
        let host = try stringArg(args, "host", maxBytes: 512)
        let cmd = try stringArg(args, "command", maxBytes: 65_536)
        let timeout = try commandTimeout(args)
        return try ssh(resolved: authorizedHost(host, capability: .runCommand), command: cmd, timeout: timeout)
    }

    private func toolListFiles(_ args: [String: Any]) throws -> String {
        let host = try stringArg(args, "host", maxBytes: 512)
        let resolved = try authorizedHost(host)
        if args["path"] == nil {
            return try ssh(resolved: resolved, command: "ls -la ~")
        }
        let path = try stringArg(args, "path", maxBytes: 4_096)
        return try ssh(resolved: resolved, command: "ls -la \(sq(path))")
    }

    private func toolReadFile(_ args: [String: Any]) throws -> String {
        let host = try stringArg(args, "host", maxBytes: 512)
        let resolved = try authorizedHost(host)
        let path = try stringArg(args, "path", maxBytes: 4_096)
        // Guard against huge files: check byte count before reading.
        let sizeOut = try ssh(resolved: resolved, command: "wc -c < \(sq(path))")
        guard let byteCount = Int64(sizeOut.trimmed), byteCount >= 0 else {
            throw MCPError("无法确认远程文件大小")
        }
        if byteCount > limits.processOutputBytes {
            throw MCPError("文件超过读取大小上限，请使用 SFTP 下载")
        }
        return try ssh(resolved: resolved, command: "cat \(sq(path))")
    }

    struct RemoteWriteRequest {
        let host: String
        let path: String
        let command: String
        let input: Data
    }

    private func toolWriteFile(_ args: [String: Any]) throws -> String {
        let request = try remoteWriteRequest(args)
        let resolved = try authorizedHost(request.host, capability: .writeFile)
        let result = try ssh(
            resolved: resolved,
            command: request.command,
            stdin: request.input,
            timeout: 60
        )
        return result.isEmpty ? "已写入 \(request.path)" : result
    }

    func remoteWriteRequest(_ args: [String: Any]) throws -> RemoteWriteRequest {
        let host = try stringArg(args, "host", maxBytes: 512)
        let path = try stringArg(args, "path", maxBytes: 4_096)
        let content = try stringArg(
            args,
            "content",
            maxBytes: limits.processInputBytes,
            allowEmpty: true,
            allowNUL: true
        )
        let input = Data(content.utf8)
        let target = sq(path)
        let command = """
        target=\(target)
        if [ -L "$target" ]; then echo 'refusing to replace symbolic link' >&2; exit 1; fi
        dir=$(dirname -- "$target") || exit 1
        tmp=$(mktemp "$dir/.harbor-mcp.XXXXXX") || exit 1
        trap 'rm -f -- "$tmp"' EXIT HUP INT TERM
        cat > "$tmp" || exit 1
        if [ -L "$target" ]; then echo 'refusing to replace symbolic link' >&2; exit 1; fi
        if [ -e "$target" ]; then chmod --reference="$target" "$tmp" || exit 1; fi
        mv -f -- "$tmp" "$target" || exit 1
        trap - EXIT HUP INT TERM
        """
        return RemoteWriteRequest(host: host, path: path, command: command, input: input)
    }

    private func toolGetSystemInfo(_ args: [String: Any]) throws -> String {
        let host = try stringArg(args, "host", maxBytes: 512)
        let raw = try ssh(
            resolved: authorizedHost(host), command: MonitorParsers.remoteScript, timeout: 30
        )
        let snap = MonitorParsers.parseSnapshot(raw)

        if snap.os.isEmpty {
            return "无法读取系统信息。确认主机可达且为 Linux 系统，或先用 run_command 测试连通性。"
        }

        var lines: [String] = ["=== 系统信息 ==="]
        lines.append("操作系统: \(snap.os)")
        if snap.uptimeSeconds > 0 {
            lines.append("运行时间: \(MonitorFormat.uptime(seconds: snap.uptimeSeconds))")
        }
        lines.append("系统负载(1/5/15分钟): \(MonitorFormat.loadAverage(snap.load1, snap.load5, snap.load15))")

        if snap.memTotalKB > 0 {
            let used = MonitorFormat.sizeShort(kb: snap.memUsedKB)
            let total = MonitorFormat.sizeShort(kb: snap.memTotalKB)
            let pct = MonitorFormat.percent(snap.memUsedFraction * 100)
            lines.append("内存: \(used) / \(total) (\(pct))")
        }
        if snap.swapTotalKB > 0 {
            let used = MonitorFormat.sizeShort(kb: snap.swapUsedKB)
            let total = MonitorFormat.sizeShort(kb: snap.swapTotalKB)
            lines.append("交换: \(used) / \(total)")
        }

        if !snap.disks.isEmpty {
            lines.append("\n=== 磁盘 ===")
            for d in snap.disks.prefix(10) {
                let used = MonitorFormat.sizeShort(kb: d.usedKB)
                let total = MonitorFormat.sizeShort(kb: d.totalKB)
                let pct = MonitorFormat.percent(d.usedFraction * 100)
                lines.append("\(d.mount): \(used) / \(total) (\(pct))")
            }
        }

        if !snap.topProcesses.isEmpty {
            lines.append("\n=== Top 进程 ===")
            lines.append("PID      用户         CPU%    内存   命令")
            for proc in snap.topProcesses.prefix(10) {
                let pid = "\(proc.pid)".padding(toLength: 8, withPad: " ", startingAt: 0)
                let user = String(proc.user.prefix(12)).padding(toLength: 12, withPad: " ", startingAt: 0)
                let cpu = MonitorFormat.processCPU(proc.cpuPercent)
                    .padding(toLength: 6, withPad: " ", startingAt: 0)
                let mem = MonitorFormat.sizeShort(kb: proc.rssKB)
                    .padding(toLength: 6, withPad: " ", startingAt: 0)
                lines.append("\(pid) \(user) \(cpu)  \(mem)  \(proc.command)")
            }
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func stringArg(_ args: [String: Any], _ name: String, maxBytes: Int,
                           allowEmpty: Bool = false, allowNUL: Bool = false) throws -> String {
        guard let value = args[name] as? String else { throw missing(name) }
        guard allowEmpty || !value.isEmpty else { throw MCPError("参数不能为空: \(name)") }
        guard value.utf8.count <= maxBytes else { throw MCPError("参数超过大小上限: \(name)") }
        guard allowNUL || !value.utf8.contains(0) else { throw MCPError("参数包含 NUL 字符: \(name)") }
        return value
    }

    private func commandTimeout(_ args: [String: Any]) throws -> TimeInterval {
        let value = args["timeout_seconds"] ?? args["timeout"]
        guard let value else { return 30 }
        guard !(value is Bool), let number = value as? NSNumber else {
            throw MCPError("超时时间必须是数字")
        }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0 else { throw MCPError("超时时间无效") }
        return min(seconds, 300)
    }

    private func missing(_ name: String) -> Error {
        MCPError("缺少参数: \(name)")
    }
}

struct MCPError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Entry point

var server = MCPServer()
server.run()
