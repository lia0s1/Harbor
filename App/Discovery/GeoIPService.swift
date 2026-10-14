import Foundation
import Combine
import HarborKit

/// Source of IP geolocation data. Implementations must tolerate partial
/// failures (return what resolved) and finish within a few seconds.
protocol GeoIPProvider: Sendable {
    /// Looks up public IPs (private/reserved are filtered by the caller).
    /// Batches of at most 100 are guaranteed by GeoIPService.
    func lookup(ips: [String]) async throws -> [GeoIPLocation]
}

/// ipwho.is — free, HTTPS, no API key (the default provider; no ATS
/// exception needed). There is no batch endpoint, so lookups are single-IP
/// GETs with bounded concurrency (≤8 in flight). Per-IP failures are
/// swallowed into "absent from the result": GeoIPService marks just those IPs
/// failed, never caches them, and retries on demand.
struct IPWhoisProvider: GeoIPProvider {
    private static let baseURL = "https://ipwho.is/"
    private static let maxConcurrent = 8
    private static let requestTimeout: TimeInterval = 5

    func lookup(ips: [String]) async throws -> [GeoIPLocation] {
        await withTaskGroup(of: GeoIPLocation?.self) { group in
            var results: [GeoIPLocation] = []
            var next = 0
            while next < ips.count && next < Self.maxConcurrent {
                let ip = ips[next]
                group.addTask { await Self.fetchOne(ip) }
                next += 1
            }
            while let location = await group.next() {
                if let location { results.append(location) }
                if next < ips.count {
                    let ip = ips[next]
                    group.addTask { await Self.fetchOne(ip) }
                    next += 1
                }
            }
            return results
        }
    }

    private static func fetchOne(_ ip: String) async -> GeoIPLocation? {
        // ipwho.is localizes country/region/city — follow the device language.
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en"
        var components = URLComponents(string: baseURL + ip)
        components?.queryItems = [
            URLQueryItem(name: "fields", value: GeoIPResponseParser.ipWhoisFields),
            URLQueryItem(name: "lang", value: language),
        ]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.requestTimeout
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200
        else { return nil }
        return GeoIPResponseParser.parseIPWhois(data)
    }
}

/// ip-api.com free batch endpoint — OPT-IN ONLY. The free tier is HTTP-only,
/// so using this provider requires an NSAppTransportSecurity exception for
/// ip-api.com in the app's Info.plist. The default IPWhoisProvider needs no
/// such exception; this is kept for anyone who explicitly wants the batch
/// endpoint and accepts the plaintext trade-off (construct the service with
/// `GeoIPService(provider: IPAPIBatchProvider())`).
///
/// Limits honored client-side: ≤100 queries per batch, ≤45 requests/minute
/// (one request every 1.4s via a shared pacer), and on HTTP 429 the `X-Ttl`
/// header is waited out (capped at 30s) with a single retry.
struct IPAPIBatchProvider: GeoIPProvider {
    private static let endpoint = URL(string: "http://ip-api.com/batch")!
    private static let maxBatch = 100
    /// 45 req/min ≈ one request every 1.33s; padded to 1.4s.
    private static let minInterval: TimeInterval = 1.4
    private static let requestTimeout: TimeInterval = 5
    private static let maxRateLimitWait: TimeInterval = 30

    /// Serializes requests across all provider instances so concurrent users
    /// (service + previews/tests) can't jointly exceed the rate limit.
    private actor Pacer {
        static let shared = Pacer()
        private var lastRequestAt = Date.distantPast

        func waitTurn(minInterval: TimeInterval) async {
            let gap = Date().timeIntervalSince(lastRequestAt)
            if gap < minInterval {
                try? await Task.sleep(nanoseconds: UInt64((minInterval - gap) * 1_000_000_000))
            }
            lastRequestAt = Date()
        }
    }

    func lookup(ips: [String]) async throws -> [GeoIPLocation] {
        var result: [GeoIPLocation] = []
        for chunk in ips.chunked(into: Self.maxBatch) {
            result.append(contentsOf: try await fetchChunk(chunk))
        }
        return result
    }

    private func fetchChunk(_ ips: [String]) async throws -> [GeoIPLocation] {
        // ip-api can localize country/region/city — follow the device language.
        let language = Locale.preferredLanguages.first?.hasPrefix("zh") == true ? "zh-CN" : "en"
        var components = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fields", value: GeoIPResponseParser.requiredFields),
            URLQueryItem(name: "lang", value: language),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ips)
        request.timeoutInterval = Self.requestTimeout

        await Pacer.shared.waitTurn(minInterval: Self.minInterval)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [] }
        if http.statusCode == 429 {
            // X-Ttl = seconds until the rate-limit window opens again.
            let ttl = TimeInterval(http.value(forHTTPHeaderField: "X-Ttl") ?? "") ?? Self.requestTimeout
            try? await Task.sleep(nanoseconds: UInt64(min(ttl, Self.maxRateLimitWait) * 1_000_000_000))
            await Pacer.shared.waitTurn(minInterval: Self.minInterval)
            let (retryData, retryResponse) = try await URLSession.shared.data(for: request)
            guard let retryHTTP = retryResponse as? HTTPURLResponse, retryHTTP.statusCode == 200
            else { return [] }
            return GeoIPResponseParser.parseBatch(retryData)
        }
        guard http.statusCode == 200 else { return [] }
        return GeoIPResponseParser.parseBatch(data)
    }
}

/// On-disk JSON cache: ~/Library/Application Support/Harbor/geoip-cache.json.
/// Atomic writes (staging file + replace), 0700 directory / 0600 file, 7-day
/// TTL. Fail entries are never cached — a failed lookup just refetches next
/// time. Cache corruption is silently dropped; the network rebuilds it.
actor GeoIPCacheStore {
    struct Entry: Codable, Equatable, Sendable {
        var location: GeoIPLocation
        var fetchedAt: Date
    }

    static let ttl: TimeInterval = 7 * 24 * 3600

    private let fileURL: URL
    private var entries: [String: Entry]?

    init(fileURL: URL = GeoIPCacheStore.defaultFileURL()) {
        self.fileURL = fileURL
    }

    static func defaultFileURL() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent("geoip-cache.json", isDirectory: false)
    }

    /// Fresh cached location for an IP, nil when absent or older than the TTL.
    func location(for ip: String) -> GeoIPLocation? {
        loadIfNeeded()
        guard let entry = entries?[ip],
              Date().timeIntervalSince(entry.fetchedAt) < Self.ttl else { return nil }
        return entry.location
    }

    func store(_ locations: [GeoIPLocation]) {
        loadIfNeeded()
        for location in locations {
            entries?[location.query] = Entry(location: location, fetchedAt: Date())
        }
        persist()
    }

    func clear() {
        entries = [:]
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        let decoded = (try? Data(contentsOf: fileURL))
            .flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        // Purge expired entries once at load so the file doesn't grow forever.
        let now = Date()
        entries = decoded.filter { now.timeIntervalSince($0.value.fetchedAt) < Self.ttl }
    }

    private func persist() {
        guard let entries, let data = try? JSONEncoder().encode(entries) else { return }
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let staging = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        defer { try? fileManager.removeItem(at: staging) }
        guard fileManager.createFile(
            atPath: staging.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { return }
        do {
            try data.write(to: staging)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: staging)
            } else {
                try fileManager.moveItem(at: staging, to: fileURL)
            }
        } catch {
            // Cache loss is never fatal — the next lookup refetches.
        }
    }
}

/// Coordinates GeoIP lookups for the UI: private-range short circuit, disk
/// cache, request coalescing (everything asked for within 150ms goes out as
/// ONE batch call), and per-IP published state.
///
/// All public API is on the main actor; network and disk work happen off it.
@MainActor
final class GeoIPService: ObservableObject {
    enum State: Equatable {
        case loading
        case loaded(GeoIPLocation)
        case failed
    }

    static let shared = GeoIPService()

    @Published private(set) var states: [String: State] = [:]

    /// Live view of the privacy toggle — labels observe GeoIPSettings directly.
    let settings: GeoIPSettings
    private let provider: GeoIPProvider
    private let cache: GeoIPCacheStore
    private var pending: Set<String> = []
    private var flushTask: Task<Void, Never>?

    init(
        provider: GeoIPProvider = IPWhoisProvider(),
        cache: GeoIPCacheStore = GeoIPCacheStore(),
        settings: GeoIPSettings? = nil
    ) {
        self.provider = provider
        self.cache = cache
        // Default resolved in the (MainActor-isolated) init body — a `.shared`
        // default ARGUMENT would be evaluated in the caller's nonisolated
        // context and trip strict-concurrency checks.
        self.settings = settings ?? GeoIPSettings.shared
    }

    var isEnabled: Bool { settings.isEnabled }

    func state(for ip: String) -> State? { states[ip] }

    /// Requests the location for an IP. Private/reserved addresses resolve
    /// locally to the 内网 marker with ZERO network traffic. No-op while the
    /// feature is disabled. Repeat calls for loaded/loading IPs are free.
    func request(_ rawIP: String) {
        guard isEnabled else { return }
        let ip = rawIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty else { return }
        if Self.isPrivateAddress(ip) {
            states[ip] = .loaded(.privateNetwork(query: ip))
            return
        }
        if case .loaded = states[ip] { return }
        if case .loading = states[ip] { return }
        states[ip] = .loading
        pending.insert(ip)
        scheduleFlush()
    }

    /// Drops the disk cache and all in-memory state (设置里的「清除缓存」).
    func clearCache() {
        states = [:]
        pending = []
        flushTask?.cancel()
        flushTask = nil
        Task { await cache.clear() }
    }

    // MARK: - Batching

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard let self, !Task.isCancelled else { return }
            self.flushTask = nil
            await self.flush()
        }
    }

    private func flush() async {
        let batch = Array(pending.prefix(100))
        pending.subtract(batch)
        guard !batch.isEmpty else { return }

        var toFetch: [String] = []
        for ip in batch {
            if let cached = await cache.location(for: ip) {
                states[ip] = .loaded(cached)
            } else {
                toFetch.append(ip)
            }
        }
        guard !toFetch.isEmpty else { return }
        do {
            let locations = try await provider.lookup(ips: toFetch)
            var resolved: Set<String> = []
            for location in locations {
                states[location.query] = .loaded(location)
                resolved.insert(location.query)
            }
            // The API said "fail" (or dropped the entry): mark failed, and
            // DON'T cache — the next request retries.
            for ip in toFetch where !resolved.contains(ip) {
                states[ip] = .failed
            }
            await cache.store(locations)
        } catch {
            for ip in toFetch { states[ip] = .failed }
        }
    }

    // MARK: - Address classification

    /// True for anything that should answer 内网 without a network call:
    /// RFC 1918 / loopback / link-local / CGNAT IPv4, plus IPv6 loopback,
    /// link-local and ULA.
    static func isPrivateAddress(_ ip: String) -> Bool {
        if let v4 = IPv4Address(dottedString: ip) {
            return v4.isPrivateOrReserved
        }
        guard ip.contains(":") else { return false }
        let lower = ip.lowercased()
        if lower == "::1" || lower == "::" { return true }
        // fe80::/10 → first hextet fe80–febf.
        if lower.hasPrefix("fe8") || lower.hasPrefix("fe9")
            || lower.hasPrefix("fea") || lower.hasPrefix("feb") { return true }
        // fc00::/7 (ULA) → first hextet starts fc or fd.
        if lower.hasPrefix("fc") || lower.hasPrefix("fd") { return true }
        return false
    }

    /// Resolves a hostname to its first IPv4 address, bounded by `timeout`.
    /// The blocking getaddrinfo runs on a GCD queue (never the cooperative
    /// pool); nil on failure — callers degrade silently.
    nonisolated static func resolveToIPv4(_ hostname: String, timeout: TimeInterval = 2) async -> String? {
        if IPv4Address(dottedString: hostname) != nil { return hostname }
        guard !hostname.contains(":") else { return nil }  // caller handles v6 directly
        return await withCheckedContinuation { continuation in
            let box = ResumeBox<String?>(continuation)
            DispatchQueue.global(qos: .utility).async {
                var hints = addrinfo()
                hints.ai_family = AF_INET
                hints.ai_socktype = SOCK_STREAM
                var result: UnsafeMutablePointer<addrinfo>?
                let rc = getaddrinfo(hostname, nil, &hints, &result)
                defer { if let result { freeaddrinfo(result) } }
                guard rc == 0 else {
                    box.resume(nil)
                    return
                }
                var cursor = result
                while let info = cursor {
                    defer { cursor = info.pointee.ai_next }
                    guard info.pointee.ai_family == AF_INET,
                          let sockaddr = info.pointee.ai_addr else { continue }
                    let dotted = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { ptr in
                        var sinAddr = ptr.pointee.sin_addr
                        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                        inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN))
                        return String(
                            decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                            as: UTF8.self
                        )
                    }
                    if IPv4Address(dottedString: dotted) != nil {
                        box.resume(dotted)
                        return
                    }
                }
                box.resume(nil)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                box.resume(nil)
            }
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var chunks: [[Element]] = []
        var index = startIndex
        while index < endIndex {
            let end = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<end]))
            index = end
        }
        return chunks
    }
}
