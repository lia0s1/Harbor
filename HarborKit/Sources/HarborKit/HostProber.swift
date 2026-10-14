import Foundation
import Network

/// Failure reasons for the graded connection probe. The UI maps these to
/// localized text; `dnsFailed`/`connectFailed` carry the OS diagnostic.
public enum HostProbeError: Error, Equatable, Sendable {
    case timeout
    case cancelled
    case invalidPort
    case dnsFailed(String)
    case connectFailed(String)
    /// TCP connected but the peer did not send an `SSH-` identification line.
    case notSSHServer
}

/// Graded reachability probe used by the host editor's "测试连接" button:
/// DNS resolution (`getaddrinfo`), then TCP connect plus SSH banner read
/// (`NWConnection`). Everything is async, timeout-bounded and cancellable.
///
/// Only the first two stages live here; the BatchMode auth probe runs a real
/// `/usr/bin/ssh` and stays in the app layer (ConnectionTester).
public enum HostProber {
    public static let defaultTimeout: TimeInterval = 8

    // MARK: - DNS

    /// Resolves `hostname` to numeric addresses (deduplicated, capped at 8).
    /// The blocking `getaddrinfo` runs on a utility queue; timeout and
    /// cancellation resume immediately even if the resolver itself is stuck
    /// (its result is then simply dropped).
    public static func resolve(
        hostname: String,
        timeout: TimeInterval = defaultTimeout
    ) async -> Result<[String], HostProbeError> {
        let box = ResumeBox<Result<[String], HostProbeError>>()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.arm { continuation.resume(returning: $0) }
                DispatchQueue.global(qos: .userInitiated).async {
                    box.fire(resolveBlocking(hostname))
                }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                    box.fire(.failure(.timeout))
                }
            }
        } onCancel: {
            box.fire(.failure(.cancelled))
        }
    }

    private static func resolveBlocking(_ hostname: String) -> Result<[String], HostProbeError> {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(hostname, nil, &hints, &result)
        guard status == 0, let first = result else {
            return .failure(.dnsFailed(String(cString: gai_strerror(status))))
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var seen = Set<String>()
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(
                info.pointee.ai_addr, info.pointee.ai_addrlen,
                &buffer, socklen_t(buffer.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 {
                let address = String(cString: buffer)
                if seen.insert(address).inserted {
                    addresses.append(address)
                }
            }
            guard addresses.count < 8 else { break }
            current = info.pointee.ai_next
        }
        return addresses.isEmpty
            ? .failure(.dnsFailed("no address records"))
            : .success(addresses)
    }

    // MARK: - TCP (+ optional SSH banner)

    /// Connects to `host:port` over TCP. When `banner` is true, additionally
    /// reads until the first newline (capped at 1 KB total) and requires a
    /// valid `SSH-` identification line — the success value is the banner.
    /// When false (e.g. RDP), a completed connect is already success and the
    /// value is empty.
    public static func probe(
        host: String,
        port: Int,
        banner: Bool,
        timeout: TimeInterval = defaultTimeout
    ) async -> Result<String, HostProbeError> {
        guard let rawPort = UInt16(exactly: port), rawPort > 0,
              let nwPort = NWEndpoint.Port(rawValue: rawPort) else {
            return .failure(.invalidPort)
        }
        let box = ResumeBox<Result<String, HostProbeError>>()
        let connBox = ConnectionBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                box.arm { continuation.resume(returning: $0) }
                let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
                connBox.set(connection)
                let queue = DispatchQueue(label: "dev.zero.Harbor.host-probe")

                var buffer = Data()
                // Local funcs capture by reference, so `buffer` accumulates
                // across receive callbacks and `receiveMore` can recurse.
                func receiveMore() {
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) {
                        data, _, isComplete, error in
                        if let data { buffer.append(data) }
                        if let line = parseBanner(buffer) {
                            box.fire(.success(line))
                            connBox.cancel()
                            return
                        }
                        // Keep waiting while the banner line may still be
                        // arriving (no newline yet, cap not reached).
                        let canStillArrive = !isComplete && error == nil
                            && buffer.count < 1024 && !buffer.contains(0x0A)
                        if canStillArrive {
                            receiveMore()
                        } else {
                            box.fire(.failure(.notSSHServer))
                            connBox.cancel()
                        }
                    }
                }

                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if banner {
                            receiveMore()
                        } else {
                            box.fire(.success(""))
                            connBox.cancel()
                        }
                    case .failed(let error):
                        box.fire(.failure(.connectFailed(describe(error))))
                        connBox.cancel()
                    case .waiting(let error):
                        // A probe reports the FIRST error — NWConnection would
                        // otherwise retry transient-looking failures (e.g.
                        // ECONNREFUSED) and the user would stare at a spinner.
                        box.fire(.failure(.connectFailed(describe(error))))
                        connBox.cancel()
                    case .cancelled:
                        box.fire(.failure(.cancelled))
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + timeout) {
                    box.fire(.failure(.timeout))
                    connBox.cancel()
                }
            }
        } onCancel: {
            box.fire(.failure(.cancelled))
            connBox.cancel()
        }
    }

    // MARK: - Banner parsing

    /// Extracts the SSH identification line (`SSH-2.0-...`) from received
    /// bytes. RFC 4253 allows the server to send other lines first (capped
    /// at 50); the first line starting with `SSH-` wins. A trailing partial
    /// line is accepted (banner prefix is enough to identify the service).
    public static func parseBanner(_ data: Data) -> String? {
        let text = String(decoding: data, as: UTF8.self)
        var scanned = 0
        // `isNewline` treats the CRLF grapheme cluster as one separator, so
        // banners arrive without a trailing "\r".
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine)
            scanned += 1
            if line.hasPrefix("SSH-") { return line }
            if scanned >= 50 { return nil }
        }
        return nil
    }

    private static func describe(_ error: NWError) -> String {
        let description = error.localizedDescription
        return description.isEmpty ? String(describing: error) : description
    }
}

/// Resume-once bridge for continuation-based probes. `fire` after `arm`
/// resumes immediately; `fire` before `arm` (cancellation racing setup)
/// stashes the value so `arm` delivers it; later fires are dropped.
private final class ResumeBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var finisher: (@Sendable (Value) -> Void)?
    private var pending: Value?
    private var fired = false

    func arm(_ finisher: @escaping @Sendable (Value) -> Void) {
        lock.lock()
        self.finisher = finisher
        let early = fired ? pending : nil
        pending = nil
        lock.unlock()
        if let early { finisher(early) }
    }

    func fire(_ value: Value) {
        lock.lock()
        guard !fired else {
            lock.unlock()
            return
        }
        fired = true
        let finisher = self.finisher
        if finisher == nil { pending = value }
        lock.unlock()
        finisher?(value)
    }
}

/// Lets the cancellation handler reach the live NWConnection, which is only
/// created inside the continuation body.
private final class ConnectionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var connection: NWConnection?

    func set(_ connection: NWConnection) {
        lock.lock()
        self.connection = connection
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let connection = self.connection
        self.connection = nil
        lock.unlock()
        connection?.cancel()
    }
}
