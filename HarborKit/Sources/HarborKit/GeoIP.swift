import Foundation

/// One resolved IP geolocation. `query` echoes the IP that was looked up so
/// batch responses can be matched back to requesters without trusting order.
///
/// `isPrivateNetwork` entries are synthesized locally (never from the API) for
/// RFC 1918 / loopback / link-local addresses — the UI renders them as 内网
/// and no request ever leaves the machine for them.
public struct GeoIPLocation: Codable, Equatable, Sendable {
    public var query: String
    public var country: String
    public var countryCode: String
    public var regionName: String
    public var city: String
    public var isPrivateNetwork: Bool

    public init(
        query: String,
        country: String,
        countryCode: String,
        regionName: String,
        city: String,
        isPrivateNetwork: Bool
    ) {
        self.query = query
        self.country = country
        self.countryCode = countryCode
        self.regionName = regionName
        self.city = city
        self.isPrivateNetwork = isPrivateNetwork
    }

    /// Marker location for private/reserved addresses.
    public static func privateNetwork(query: String) -> GeoIPLocation {
        GeoIPLocation(
            query: query, country: "", countryCode: "",
            regionName: "", city: "", isPrivateNetwork: true
        )
    }

    /// "CN" → "🇨🇳" via regional indicator symbols. Empty for anything that
    /// isn't a two-letter ASCII code (private entries, API gaps).
    public var flagEmoji: String {
        let code = countryCode.uppercased()
        guard code.count == 2,
              code.unicodeScalars.allSatisfy({ $0.isASCII && ($0.value >= 65 && $0.value <= 90) })
        else { return "" }
        var scalars = String.UnicodeScalarView()
        for scalar in code.unicodeScalars {
            guard let flag = Unicode.Scalar(0x1F1E6 + (scalar.value - 65)) else { return "" }
            scalars.append(flag)
        }
        return String(scalars)
    }

    /// "country · regionName · city" with empties and duplicates dropped
    /// (ip-api often repeats region and city). Empty for private entries —
    /// localization of 内网 is the app's job, not the model layer's.
    public var displayText: String {
        guard !isPrivateNetwork else { return "" }
        var parts: [String] = []
        for value in [country, regionName, city] {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty && !parts.contains(trimmed) {
                parts.append(trimmed)
            }
        }
        return parts.joined(separator: " · ")
    }
}

/// Parsers for GeoIP provider responses. Only successful entries are
/// returned; failures (private/reserved range, invalid query) become nil /
/// are dropped — the caller marks those IPs as failed so they are retried on
/// demand instead of poisoned into the cache.
public enum GeoIPResponseParser {
    /// The `fields` parameter the ip-api.com batch parser expects.
    public static let requiredFields = "status,message,country,countryCode,regionName,city,query"
    /// The `fields` parameter the ipwho.is single-IP parser expects. `ip` must
    /// be included so the response self-identifies its query.
    public static let ipWhoisFields = "ip,success,country,country_code,region,city"

    private struct Item: Decodable {
        let status: String
        let country: String?
        let countryCode: String?
        let regionName: String?
        let city: String?
        let query: String?
    }

    /// ip-api.com batch response: an array of
    /// `{"status":"success",…,"query":"1.2.3.4"}` /
    /// `{"status":"fail","message":"private range",…}` objects.
    public static func parseBatch(_ data: Data) -> [GeoIPLocation] {
        guard let items = try? JSONDecoder().decode([Item].self, from: data) else { return [] }
        return items.compactMap { item in
            guard item.status == "success", let query = item.query, !query.isEmpty
            else { return nil }
            return GeoIPLocation(
                query: query,
                country: item.country ?? "",
                countryCode: item.countryCode ?? "",
                regionName: item.regionName ?? "",
                city: item.city ?? "",
                isPrivateNetwork: false
            )
        }
    }

    /// ipwho.is single-IP response (`GET https://ipwho.is/<ip>?fields=ip,success,…`):
    ///
    ///     {"ip":"8.8.8.8","success":true,"country":"United States",
    ///      "country_code":"US","region":"California","city":"San Jose"}
    ///
    /// Failures are `{"ip":"10.0.0.1","success":false,"message":"Reserved range"}`
    /// → nil. The echoed `ip` field is required: it is what matches the
    /// location back to its query.
    public static func parseIPWhois(_ data: Data) -> GeoIPLocation? {
        struct Entry: Decodable {
            let ip: String?
            let success: Bool?
            let country: String?
            let country_code: String?
            let region: String?
            let city: String?
        }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.success == true,
              let query = entry.ip, !query.isEmpty else { return nil }
        return GeoIPLocation(
            query: query,
            country: entry.country ?? "",
            countryCode: entry.country_code ?? "",
            regionName: entry.region ?? "",
            city: entry.city ?? "",
            isPrivateNetwork: false
        )
    }
}
