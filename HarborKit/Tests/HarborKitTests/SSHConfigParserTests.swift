import XCTest
@testable import HarborKit

final class SSHConfigParserTests: XCTestCase {

    private let home = "/Users/test"

    private func parse(_ text: String) -> [SSHHost] {
        SSHConfigParser.parse(text, homeDirectory: home)
    }

    // MARK: - Basics

    func testSingleHostWithAllSupportedKeys() throws {
        let config = """
        Host web
            HostName web.example.com
            User alice
            Port 2222
            IdentityFile ~/.ssh/id_ed25519
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.name, "web")
        XCTAssertEqual(host.hostname, "web.example.com")
        XCTAssertEqual(host.username, "alice")
        XCTAssertEqual(host.port, 2222)
        XCTAssertEqual(host.identityFile, "/Users/test/.ssh/id_ed25519")
    }

    func testHostnameDefaultsToAliasWhenNoHostNameKey() throws {
        let hosts = parse("Host bastion.example.com\n  User root")
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "bastion.example.com")
        XCTAssertEqual(hosts[0].name, "bastion.example.com")
        XCTAssertEqual(hosts[0].username, "root")
        XCTAssertEqual(hosts[0].port, SSHHost.defaultPort)
        XCTAssertNil(hosts[0].identityFile)
    }

    func testMultipleHostBlocks() {
        let config = """
        Host a
            HostName a.example.com
        Host b
            HostName b.example.com
            Port 2200
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.map(\.name), ["a", "b"])
        XCTAssertEqual(hosts.map(\.hostname), ["a.example.com", "b.example.com"])
        XCTAssertEqual(hosts.map(\.port), [22, 2200])
    }

    func testEmptyInputProducesNoHosts() {
        XCTAssertEqual(parse(""), [])
        XCTAssertEqual(parse("\n\n   \n"), [])
    }

    func testCRLFLineEndingsProduceCleanValues() throws {
        let config = "Host crlf\r\n    HostName web.example.com\r\n    User deploy\r\n    Port 2200\r\n    IdentityFile ~/.ssh/id_ed25519\r\n"
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        let host = try XCTUnwrap(hosts.first)
        XCTAssertEqual(host.name, "crlf")
        XCTAssertEqual(host.hostname, "web.example.com")
        XCTAssertEqual(host.username, "deploy")
        XCTAssertEqual(host.port, 2200)
        XCTAssertEqual(host.identityFile, "/Users/test/.ssh/id_ed25519")
        // The imported host must survive injection-safety validation
        // (a trailing "\r" would be rejected as a control character).
        XCTAssertNoThrow(try SSHCommandBuilder.arguments(for: host))
    }

    // MARK: - Multi-alias Host lines

    func testMultiAliasHostLineCreatesOneEntryPerAlias() {
        let config = """
        Host web1 web2 web3
            HostName shared.example.com
            User deploy
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.map(\.name), ["web1", "web2", "web3"])
        XCTAssertEqual(Set(hosts.map(\.hostname)), ["shared.example.com"])
        XCTAssertEqual(Set(hosts.map(\.username)), ["deploy"])
    }

    func testMultiAliasMixedWithWildcardKeepsOnlyConcreteAliases() {
        let config = """
        Host web *.example.com db-? !prod
            User admin
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.map(\.name), ["web"])
        XCTAssertEqual(hosts[0].username, "admin")
    }

    // MARK: - Wildcard skipping

    func testWildcardOnlyBlocksAreSkipped() {
        let config = """
        Host *
            User root
        Host *.internal
            Port 2222
        Host db-??
            User dba
        """
        XCTAssertEqual(parse(config), [])
    }

    func testKeysFromSkippedWildcardBlockDoNotLeakIntoNextHost() throws {
        let config = """
        Host *
            User root
            Port 9999
        Host web
            HostName web.example.com
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].name, "web")
        XCTAssertEqual(hosts[0].username, "")
        XCTAssertEqual(hosts[0].port, SSHHost.defaultPort)
    }

    // MARK: - Case-insensitivity & syntax variants

    func testKeysAreCaseInsensitive() throws {
        let config = """
        hOsT web
            HOSTNAME web.example.com
            uSeR alice
            PORT 2222
            identityFILE ~/.ssh/key
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].username, "alice")
        XCTAssertEqual(hosts[0].port, 2222)
        XCTAssertEqual(hosts[0].identityFile, "/Users/test/.ssh/key")
    }

    func testEqualsSignSyntax() throws {
        let config = """
        Host web
            HostName=web.example.com
            Port = 2222
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertEqual(hosts[0].port, 2222)
    }

    func testQuotedIdentityFileWithSpaces() throws {
        let config = """
        Host web
            IdentityFile "~/.ssh/my key"
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.first?.identityFile, "/Users/test/.ssh/my key")
    }

    // MARK: - Tilde expansion

    func testTildeSlashExpansion() {
        let hosts = parse("Host a\n IdentityFile ~/.ssh/id_rsa")
        XCTAssertEqual(hosts.first?.identityFile, "/Users/test/.ssh/id_rsa")
    }

    func testBareTildeExpansion() {
        let hosts = parse("Host a\n IdentityFile ~")
        XCTAssertEqual(hosts.first?.identityFile, "/Users/test")
    }

    func testOtherUserTildeIsLeftAlone() {
        let hosts = parse("Host a\n IdentityFile ~bob/.ssh/id_rsa")
        XCTAssertEqual(hosts.first?.identityFile, "~bob/.ssh/id_rsa")
    }

    func testAbsoluteIdentityFileIsUntouched() {
        let hosts = parse("Host a\n IdentityFile /etc/ssh/key")
        XCTAssertEqual(hosts.first?.identityFile, "/etc/ssh/key")
    }

    // MARK: - Port parsing

    func testInvalidPortValuesFallBackToDefault() {
        for bad in ["abc", "0", "65536", "-22", "2 2"] {
            let hosts = parse("Host a\n Port \(bad)")
            XCTAssertEqual(hosts.first?.port, SSHHost.defaultPort, "Port \(bad) should be ignored")
        }
    }

    func testFirstValueWinsForRepeatedKeys() throws {
        let config = """
        Host web
            Port 2222
            Port 3333
            HostName first.example.com
            HostName second.example.com
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.first?.port, 2222)
        XCTAssertEqual(hosts.first?.hostname, "first.example.com")
    }

    // MARK: - Garbage tolerance & ignored constructs

    func testCommentsAndBlankLinesAreIgnored()  {
        let config = """
        # global comment

        Host web
            # inline comment line
            HostName web.example.com

        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
    }

    func testGarbageLinesNeverCrashAndAreSkipped() {
        let config = """
        ��� total garbage ���
        Host web
            HostName web.example.com
            ThisKeyDoesNotExist whatever
            keywithoutvalue
            = = = =
            "unbalanced quote
        Host
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
    }

    func testMatchBlockKeysDoNotLeak() {
        let config = """
        Host a
            HostName a.example.com
        Match user bob
            Port 2222
            User bob
        Host b
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.map(\.name), ["a", "b"])
        XCTAssertEqual(hosts[1].port, SSHHost.defaultPort)
        XCTAssertEqual(hosts[1].username, "")
    }

    func testSettingsBeforeFirstHostAreIgnored() {
        let config = """
        User globaluser
        Port 9999
        Host web
            HostName web.example.com
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].username, "")
        XCTAssertEqual(hosts[0].port, SSHHost.defaultPort)
    }

    func testIncludeAndUnknownKeysAreIgnored() {
        let config = """
        Include ~/.ssh/other_config
        Host web
            HostName web.example.com
            ProxyJump bastion
            ForwardAgent yes
        """
        let hosts = parse(config)
        XCTAssertEqual(hosts.count, 1)
        XCTAssertEqual(hosts[0].hostname, "web.example.com")
        XCTAssertTrue(hosts[0].extraArgs.isEmpty)
    }

    func testParsedHostsBuildValidSSHCommands() throws {
        let config = """
        Host web db
            HostName internal.example.com
            User deploy
            Port 2222
        """
        for host in parse(config) {
            let args = try SSHCommandBuilder.arguments(for: host)
            XCTAssertEqual(args.last, "deploy@internal.example.com")
        }
    }
}
