import Foundation
import Network
import HarborKit

/// TCP handshake latency probe: every second an `NWConnection` is opened to
/// the host's SSH port and the time to `.ready` (SYN → SYN-ACK → ACK) is
/// recorded. Works when ICMP is filtered (a very common cloud default) and
/// measures exactly the path the session cares about. Series/average/loss
/// accounting mirrors `PingService` so both cards read the same.
@MainActor
final class TcpPingService: ObservableObject {
    /// All probe-derived values batched into one published struct, so one
    /// probe fires objectWillChange exactly once (same rationale as
    /// PingService.PingFrame).
    struct TcpPingFrame: Equatable {
        var latencySeries: [Double] = []
        var latencySum: Double = 0
        var currentMs: Double?
        var averageMs: Double?
        var successCount: Int = 0
        var failureCount: Int = 0
    }
    @Published private(set) var frame = TcpPingFrame()
    /// Convenience accessors — call sites that read these stay unchanged.
    var latencySeries: [Double] { frame.latencySeries }
    var currentMs: Double? { frame.currentMs }
    var averageMs: Double? { frame.averageMs }
    var successCount: Int { frame.successCount }
    var failureCount: Int { frame.failureCount }

    @Published private(set) var isRunning = false
    /// Last probe failure (timeout / refused / no route), surfaced by the TCP
    /// ping card. Cleared on the first successful handshake and by stop().
    @Published private(set) var lastError: String?

    /// Target of the handshake probes (read-only, for the UI's captions).
    let hostname: String
    let port: Int
    private var active = false
    private var probeTask: Task<Void, Never>?

    private static let probeInterval: TimeInterval = 1
    /// A filtered port blackholes SYN; don't wait longer than this per probe.
    private static let probeTimeout: TimeInterval = 3
    private static let maxSamples = 90

    init(hostname: String, port: Int = 22) {
        self.hostname = hostname.trimmingCharacters(in: .whitespaces)
        self.port = port
    }

    deinit {
        assert(Thread.isMainThread, "TcpPingService must be deallocated on the main thread")
        probeTask?.cancel()
    }

    func start() {
        guard !active else { return }
        // Hostnames were already validated by SSHCommandBuilder at session
        // creation; this is defense in depth for the NWConnection endpoint.
        guard !hostname.isEmpty, !hostname.hasPrefix("-"),
              port > 0, port <= 65535,
              !hostname.unicodeScalars.contains(where: {
                  CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0)
              }) else { return }
        active = true
        lastError = nil
        isRunning = true
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.active else { return }
                await self.probeOnce()
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.probeInterval * 1_000_000_000))
            }
        }
    }

    /// Stops probing but keeps the last samples on screen (tab switches).
    func pause() {
        guard active else { return }
        active = false
        probeTask?.cancel()
        probeTask = nil
        isRunning = false
    }

    func stop() {
        pause()
        frame = TcpPingFrame()
        lastError = nil
    }

    // MARK: - Probing

    private func probeOnce() async {
        let result = await Self.measure(host: hostname, port: port, timeout: Self.probeTimeout)
        guard active, !Task.isCancelled else { return }
        var next = frame
        switch result {
        case .success(let ms):
            next.successCount += 1
            next.currentMs = ms
            next.latencySeries.append(ms)
            next.latencySum += ms
            if next.latencySeries.count > Self.maxSamples {
                let overflow = next.latencySeries.count - Self.maxSamples
                next.latencySum -= next.latencySeries.prefix(overflow).reduce(0, +)
                next.latencySeries.removeFirst(overflow)
            }
            next.averageMs = next.latencySum / Double(next.latencySeries.count)
            if lastError != nil { lastError = nil }
        case .timeout:
            next.failureCount += 1
            if lastError == nil { lastError = L("TCP 连接超时") }
        case .failed(let message):
            next.failureCount += 1
            if lastError == nil { lastError = L("TCP 连接失败：%@", message) }
        }
        if next != frame { frame = next }
    }

    /// One TCP connect attempt's outcome.
    private enum ProbeResult {
        case success(Double) // handshake time, milliseconds
        case timeout
        case failed(String)
    }

    /// Opens one NWConnection and measures time-to-ready. Off the main actor:
    /// the state handler runs on a utility queue and only touches the
    /// single-resume box. The timeout always cancels the connection, so the
    /// continuation resolves within `timeout` no matter what the network does.
    private nonisolated static func measure(
        host: String, port: Int, timeout: TimeInterval
    ) async -> ProbeResult {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return .failed("invalid port \(port)")
        }
        return await withCheckedContinuation { continuation in
            let box = ResumeBox(continuation)
            let start = Date()
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let ms = max(0, Date().timeIntervalSince(start) * 1000)
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    box.resume(.success(ms))
                case .failed(let error):
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    box.resume(.failed(error.localizedDescription))
                default:
                    // .waiting (retrying) / .preparing: the timeout owns the deadline.
                    break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                connection.stateUpdateHandler = nil
                connection.cancel()
                box.resume(.timeout)
            }
        }
    }

    /// Guarantees the checked continuation resumes exactly once: `.ready`,
    /// `.failed` and the timeout race, and a double resume would crash.
    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ProbeResult, Never>?

        init(_ continuation: CheckedContinuation<ProbeResult, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: ProbeResult) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            lock.unlock()
            continuation?.resume(returning: result)
        }
    }
}
