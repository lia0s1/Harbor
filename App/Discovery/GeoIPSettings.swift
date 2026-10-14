import Foundation
import Combine

/// Privacy-first toggle for IP geolocation (设置 → 隐私 wires here).
/// Off by default: until the user opts in, no host IP ever leaves the machine.
///
/// Stored in UserDefaults rather than read via @AppStorage in views so the
/// GeoIPService can consult it without a view hierarchy.
@MainActor
final class GeoIPSettings: ObservableObject {
    static let shared = GeoIPSettings()

    static let storageKey = "harbor.geoipEnabled"

    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.storageKey) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // object(forKey:) so "never set" is distinguishable and defaults to off.
        self.isEnabled = defaults.object(forKey: Self.storageKey) as? Bool ?? false
    }
}
