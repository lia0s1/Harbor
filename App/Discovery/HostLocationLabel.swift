import SwiftUI
import HarborKit

/// Bottom-bar style location chip for one host: resolves the host to an IP,
/// asks GeoIPService, renders "🇨🇳 中国 · 上海" — or "内网" for private
/// ranges, a subtle placeholder while resolving, and NOTHING when the feature
/// is disabled or the lookup fails (location is decoration, never an error).
///
///     HostLocationLabel(host: host.hostname)
///
/// The integrator drops this into host rows / the monitor header; the privacy
/// toggle lives in Settings (GeoIPSettings).
struct HostLocationLabel: View {
    let host: String

    @ObservedObject private var service: GeoIPService
    /// Observed too so toggling the switch re-renders visible labels at once.
    @ObservedObject private var settings: GeoIPSettings

    @State private var resolvedIP: String?
    @State private var resolutionFailed = false

    /// Designated initializer — pass both explicitly (previews/tests).
    init(host: String, service: GeoIPService, settings: GeoIPSettings) {
        self.host = host
        _service = ObservedObject(wrappedValue: service)
        _settings = ObservedObject(wrappedValue: settings)
    }

    /// Common case: shared singletons. @MainActor because `.shared` on a
    /// MainActor class can't be touched from a nonisolated default argument.
    @MainActor
    init(host: String) {
        self.init(
            host: host,
            service: GeoIPService.shared,
            settings: GeoIPService.shared.settings
        )
    }

    var body: some View {
        content
            .task(id: host) { await resolveAndRequest() }
    }

    @ViewBuilder
    private var content: some View {
        if !settings.isEnabled || resolutionFailed {
            EmptyView()
        } else if let ip = resolvedIP {
            locationView(for: ip)
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        Text("…")
            .font(.caption)
            .foregroundStyle(.tertiary)
    }

    @ViewBuilder
    private func locationView(for ip: String) -> some View {
        switch service.state(for: ip) {
        case .loaded(let location):
            if location.isPrivateNetwork {
                Text(L("内网"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !location.displayText.isEmpty {
                Text("\(location.flagEmoji) \(location.displayText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                EmptyView()
            }
        case .loading, .none:
            placeholder
        case .failed:
            EmptyView()
        }
    }

    private func resolveAndRequest() async {
        guard settings.isEnabled else { return }
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            resolutionFailed = true
            return
        }
        // Literal IPs go straight through; IPv6 is handed to the API as-is.
        if IPv4Address(dottedString: trimmed) != nil || trimmed.contains(":") {
            resolvedIP = trimmed
            service.request(trimmed)
            return
        }
        if let ip = await GeoIPService.resolveToIPv4(trimmed) {
            guard !Task.isCancelled else { return }
            resolvedIP = ip
            service.request(ip)
        } else {
            resolutionFailed = true
        }
    }
}
