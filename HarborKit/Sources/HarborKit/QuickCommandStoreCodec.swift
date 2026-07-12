import Foundation

/// Encodes/decodes the on-disk commands.json document for the 命令 panel. Pure
/// data <-> bytes; file IO lives in the app layer so it stays testable here.
/// Mirrors `HostStoreCodec`: a versioned wrapper, tolerant decode (accepts a
/// bare array too), pretty-printed deterministic output.
public enum QuickCommandStoreCodec {
    public struct Document: Codable, Sendable {
        public var version: Int
        public var commands: [QuickCommand]

        public init(version: Int = QuickCommandStoreCodec.currentVersion, commands: [QuickCommand]) {
            self.version = version
            self.commands = commands
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            // `commands` is REQUIRED (mirrors HostStoreCodec): an object missing
            // it is corruption, not an empty list — throw so the app layer moves
            // the file aside rather than overwriting it empty on the next save.
            commands = try c.decode([QuickCommand].self, forKey: .commands)
        }
    }

    public static let currentVersion = 1

    public static func encode(_ commands: [QuickCommand]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(commands: commands))
    }

    public static func decode(_ data: Data) throws -> [QuickCommand] {
        let decoder = JSONDecoder()
        // Try the versioned wrapper first; only fall back to the legacy bare-array
        // format when the top-level object is missing the expected keyed structure
        // (migration path). All other errors — corrupt JSON, type mismatches, etc.
        // — propagate so the app layer can move the file aside rather than silently
        // losing data. Mirrors HostStoreCodec.decode(_:).
        do {
            let document = try decoder.decode(Document.self, from: data)
            return document.commands
        } catch DecodingError.keyNotFound, DecodingError.typeMismatch {
            return try decoder.decode([QuickCommand].self, from: data)
        }
    }

    /// Sensible starter commands offered on first run (the user keeps or deletes
    /// them) and offered as a one-click "添加常用命令" set in the 命令 panel.
    /// Titles are zh-Hans source keys; the app localizes them via L() for display
    /// only — the stored title stays as written here so it round-trips. Commands
    /// with `{name}` placeholders prompt for input before sending.
    public static func starterCommands() -> [QuickCommand] {
        [
            // 系统
            QuickCommand(title: "磁盘使用", command: "df -h", group: "系统"),
            QuickCommand(title: "内存使用", command: "free -h", group: "系统"),
            QuickCommand(title: "运行时间 / 负载", command: "uptime", group: "系统"),
            QuickCommand(title: "CPU 信息", command: "lscpu", group: "系统"),
            QuickCommand(title: "系统信息", command: "uname -a", group: "系统"),
            QuickCommand(title: "实时资源 (top)", command: "top", group: "系统"),
            QuickCommand(title: "CPU 占用前 15", command: "ps aux --sort=-%cpu | head -n 16", group: "系统"),
            QuickCommand(title: "内存占用前 15", command: "ps aux --sort=-%mem | head -n 16", group: "系统"),
            QuickCommand(title: "目录大小", command: "du -sh ./* 2>/dev/null | sort -rh | head -n 20", group: "系统"),
            // 网络
            QuickCommand(title: "监听端口", command: "ss -tulnp", group: "网络"),
            QuickCommand(title: "网络连接", command: "ss -tnp", group: "网络"),
            QuickCommand(title: "公网 IP", command: "curl -s ifconfig.me; echo", group: "网络"),
            QuickCommand(title: "网卡地址", command: "ip -br addr", group: "网络"),
            // 服务
            QuickCommand(title: "服务状态", command: "systemctl status {服务} --no-pager", group: "服务"),
            QuickCommand(title: "重启服务", command: "systemctl restart {服务}", group: "服务"),
            QuickCommand(title: "服务日志", command: "journalctl -u {服务} -n 120 --no-pager", group: "服务"),
            // Docker
            QuickCommand(title: "容器列表", command: "docker ps -a", group: "Docker"),
            QuickCommand(title: "镜像列表", command: "docker images", group: "Docker"),
            QuickCommand(title: "容器日志", command: "docker logs --tail 120 {容器}", group: "Docker"),
            QuickCommand(title: "资源占用", command: "docker stats --no-stream", group: "Docker"),
        ]
    }
}
