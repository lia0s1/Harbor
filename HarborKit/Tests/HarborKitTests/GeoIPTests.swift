import XCTest
@testable import HarborKit

final class GeoIPTests: XCTestCase {
    // MARK: - Batch response parsing

    /// Real ip-api.com /batch shape with fields=status,message,country,
    /// countryCode,regionName,city,query.
    private let batchFixture = """
    [
      {"status":"success","country":"China","countryCode":"CN","regionName":"Shanghai","city":"Shanghai","query":"203.0.113.10"},
      {"status":"fail","message":"private range","query":"10.0.0.1"},
      {"status":"success","country":"United States","countryCode":"US","regionName":"California","city":"Mountain View","query":"8.8.8.8"}
    ]
    """

    func testParsesSuccessfulEntries() {
        let locations = GeoIPResponseParser.parseBatch(Data(batchFixture.utf8))
        XCTAssertEqual(locations.count, 2)
        XCTAssertEqual(locations[0].query, "203.0.113.10")
        XCTAssertEqual(locations[0].country, "China")
        XCTAssertEqual(locations[0].countryCode, "CN")
        XCTAssertEqual(locations[1].query, "8.8.8.8")
        XCTAssertEqual(locations[1].city, "Mountain View")
    }

    /// Failed entries (private range, invalid query) are dropped so the caller
    /// can mark them failed and never cache them.
    func testFailedEntriesDropped() {
        let locations = GeoIPResponseParser.parseBatch(Data(batchFixture.utf8))
        XCTAssertFalse(locations.contains { $0.query == "10.0.0.1" })
        XCTAssertFalse(locations.contains { $0.isPrivateNetwork })
    }

    func testMalformedDataReturnsEmpty() {
        XCTAssertTrue(GeoIPResponseParser.parseBatch(Data("not json".utf8)).isEmpty)
        XCTAssertTrue(GeoIPResponseParser.parseBatch(Data("{}".utf8)).isEmpty)
        XCTAssertTrue(GeoIPResponseParser.parseBatch(Data("[{\"unexpected\":1}]".utf8)).isEmpty)
    }

    func testMissingOptionalFieldsTolerated() {
        let locations = GeoIPResponseParser.parseBatch(Data("""
        [{"status":"success","query":"1.1.1.1"}]
        """.utf8))
        XCTAssertEqual(locations.count, 1)
        XCTAssertEqual(locations[0].country, "")
        XCTAssertEqual(locations[0].flagEmoji, "")
    }

    // MARK: - ipwho.is single-IP parsing

    /// Real ipwho.is response shape (fields=ip,success,country,country_code,region,city).
    func testIPWhoisSuccess() {
        let location = GeoIPResponseParser.parseIPWhois(Data("""
        {"ip":"8.8.8.8","success":true,"country":"United States","country_code":"US","region":"California","city":"San Jose"}
        """.utf8))
        XCTAssertEqual(location?.query, "8.8.8.8")
        XCTAssertEqual(location?.country, "United States")
        XCTAssertEqual(location?.countryCode, "US")
        XCTAssertEqual(location?.regionName, "California")
        XCTAssertEqual(location?.city, "San Jose")
        XCTAssertEqual(location?.isPrivateNetwork, false)
    }

    func testIPWhoisLocalizedSample() {
        let location = GeoIPResponseParser.parseIPWhois(Data("""
        {"ip":"1.1.1.1","success":true,"country":"澳大利亚","country_code":"AU","region":"昆士蘭州","city":"布里斯班"}
        """.utf8))
        XCTAssertEqual(location?.displayText, "澳大利亚 · 昆士蘭州 · 布里斯班")
        XCTAssertEqual(location?.flagEmoji, "🇦🇺")
    }

    /// The private-range short circuit: ipwho.is answers success:false for
    /// reserved space. Parser must return nil so the caller marks the IP
    /// failed instead of caching a phantom.
    func testIPWhoisReservedRangeFails() {
        XCTAssertNil(GeoIPResponseParser.parseIPWhois(Data("""
        {"ip":"10.0.0.1","success":false,"message":"Reserved range"}
        """.utf8)))
        XCTAssertNil(GeoIPResponseParser.parseIPWhois(Data("""
        {"ip":"not-an-ip","success":false,"message":"invalid IP address"}
        """.utf8)))
    }

    func testIPWhoisMalformedReturnsNil() {
        XCTAssertNil(GeoIPResponseParser.parseIPWhois(Data("not json".utf8)))
        XCTAssertNil(GeoIPResponseParser.parseIPWhois(Data("{}".utf8)))
        // success without the echoed ip can't be matched back to a query.
        XCTAssertNil(GeoIPResponseParser.parseIPWhois(Data("""
        {"success":true,"country":"X"}
        """.utf8)))
    }

    func testIPWhoisMissingOptionalFieldsTolerated() {
        let location = GeoIPResponseParser.parseIPWhois(Data("""
        {"ip":"1.1.1.1","success":true}
        """.utf8))
        XCTAssertEqual(location?.query, "1.1.1.1")
        XCTAssertEqual(location?.country, "")
        XCTAssertEqual(location?.flagEmoji, "")
    }

    // MARK: - Flag emoji

    func testFlagEmoji() {
        XCTAssertEqual(flag("CN"), "🇨🇳")
        XCTAssertEqual(flag("US"), "🇺🇸")
        XCTAssertEqual(flag("jp"), "🇯🇵")  // case-insensitive
        XCTAssertEqual(flag(""), "")
        XCTAssertEqual(flag("C"), "")
        XCTAssertEqual(flag("C1"), "")
        XCTAssertEqual(flag("CHN"), "")
    }

    private func flag(_ code: String) -> String {
        GeoIPLocation(
            query: "1.2.3.4", country: "X", countryCode: code,
            regionName: "", city: "", isPrivateNetwork: false
        ).flagEmoji
    }

    // MARK: - Display text

    func testDisplayTextDeduplicatesRegionAndCity() {
        let location = GeoIPLocation(
            query: "1.2.3.4", country: "中国", countryCode: "CN",
            regionName: "上海", city: "上海", isPrivateNetwork: false
        )
        XCTAssertEqual(location.displayText, "中国 · 上海")
    }

    func testDisplayTextKeepsDistinctParts() {
        let location = GeoIPLocation(
            query: "1.2.3.4", country: "中国", countryCode: "CN",
            regionName: "浙江", city: "杭州", isPrivateNetwork: false
        )
        XCTAssertEqual(location.displayText, "中国 · 浙江 · 杭州")
    }

    func testDisplayTextEmptyForPrivate() {
        XCTAssertEqual(GeoIPLocation.privateNetwork(query: "10.0.0.1").displayText, "")
        XCTAssertEqual(GeoIPLocation.privateNetwork(query: "10.0.0.1").flagEmoji, "")
    }

    // MARK: - Codable (disk cache round-trip)

    func testCodableRoundTrip() throws {
        let location = GeoIPLocation(
            query: "8.8.8.8", country: "United States", countryCode: "US",
            regionName: "California", city: "Mountain View", isPrivateNetwork: false
        )
        let data = try JSONEncoder().encode(location)
        let decoded = try JSONDecoder().decode(GeoIPLocation.self, from: data)
        XCTAssertEqual(decoded, location)
    }
}
