import XCTest
@testable import HarborKit

final class SSHCommandBuilderTests: XCTestCase {

    // MARK: - Basics & destination ordering

    func testMinimalHostUsesDefaultsAndDestinationLast() throws {
        let host = SSHHost(hostname: "example.com")
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertEqual(args, ["-o", "ServerAliveInterval=30", "-o", "ConnectTimeout=10", "example.com"])
        XCTAssertEqual(args.last, "example.com")
    }

    func testUsernameProducesUserAtHostDestination() throws {
        let host = SSHHost(hostname: "example.com", username: "alice")
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertEqual(args.last, "alice@example.com")
    }

    func testDestinationIsAlwaysLastEvenWithEverythingSet() throws {
        let host = SSHHost(
            hostname: "example.com",
            port: 2222,
            username: "alice",
            identityFile: "~/.ssh/id_ed25519",
            extraArgs: ["-v", "-o", "Compression=yes"],
            portForwards: [
                PortForward(kind: .local, bindPort: 8080, targetHost: "db", targetPort: 5432)
            ]
        )
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertEqual(args.last, "alice@example.com")
        // extraArgs must come after built-in flags but before the destination.
        let vIndex = try XCTUnwrap(args.firstIndex(of: "-v"))
        let iIndex = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertGreaterThan(vIndex, iIndex)
        XCTAssertEqual(args.firstIndex(of: "alice@example.com"), args.count - 1)
    }

    func testCommandPrependsExecutablePath() throws {
        let host = SSHHost(hostname: "example.com")
        let argv = try SSHCommandBuilder.command(for: host)
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertEqual(argv.last, "example.com")
    }

    // MARK: - Port

    func testDefaultPortOmitsDashP() throws {
        let args = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 22))
        XCTAssertFalse(args.contains("-p"))
    }

    func testNonDefaultPortEmitsDashP() throws {
        let args = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 2222))
        let idx = try XCTUnwrap(args.firstIndex(of: "-p"))
        XCTAssertEqual(args[idx + 1], "2222")
    }

    func testInvalidPortThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 0)))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 70000)))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: -1)))
    }

    // MARK: - Identity file

    func testIdentityFileEmitsDashI() throws {
        let host = SSHHost(hostname: "h", identityFile: "~/.ssh/id_ed25519")
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertEqual(args[idx + 1], "~/.ssh/id_ed25519")
    }

    func testNilOrEmptyIdentityFileOmitsDashI() throws {
        XCTAssertFalse(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h")).contains("-i"))
        XCTAssertFalse(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", identityFile: "  ")).contains("-i"))
    }

    func testIdentityFileWithSpacesIsAllowed() throws {
        // Paths may legitimately contain spaces; argv elements are not shell-split.
        let host = SSHHost(hostname: "h", identityFile: "/Users/me/My Keys/id_rsa")
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertTrue(args.contains("/Users/me/My Keys/id_rsa"))
    }

    // MARK: - Port forwards

    func testLocalForward() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 8080, targetHost: "db.internal", targetPort: 5432)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-L"))
        XCTAssertEqual(args[idx + 1], "8080:db.internal:5432")
    }

    func testLocalForwardWithBindAddress() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindAddress: "127.0.0.1", bindPort: 8080, targetHost: "db", targetPort: 5432)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-L"))
        XCTAssertEqual(args[idx + 1], "127.0.0.1:8080:db:5432")
    }

    func testRemoteForward() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .remote, bindPort: 9000, targetHost: "localhost", targetPort: 3000)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-R"))
        XCTAssertEqual(args[idx + 1], "9000:localhost:3000")
    }

    func testDynamicForwardIgnoresTargetFields() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .dynamic, bindPort: 1080, targetHost: "ignored", targetPort: 99)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-D"))
        XCTAssertEqual(args[idx + 1], "1080")
        XCTAssertFalse(args.contains { $0.contains("ignored") })
    }

    func testDynamicForwardWithBindAddress() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .dynamic, bindAddress: "0.0.0.0", bindPort: 1080)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let idx = try XCTUnwrap(args.firstIndex(of: "-D"))
        XCTAssertEqual(args[idx + 1], "0.0.0.0:1080")
    }

    func testMultipleForwardsPreserveOrder() throws {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 1111, targetHost: "a", targetPort: 1),
            PortForward(kind: .remote, bindPort: 2222, targetHost: "b", targetPort: 2),
            PortForward(kind: .dynamic, bindPort: 3333)
        ])
        let args = try SSHCommandBuilder.arguments(for: host)
        let l = try XCTUnwrap(args.firstIndex(of: "-L"))
        let r = try XCTUnwrap(args.firstIndex(of: "-R"))
        let d = try XCTUnwrap(args.firstIndex(of: "-D"))
        XCTAssertLessThan(l, r)
        XCTAssertLessThan(r, d)
    }

    func testForwardWithEmptyTargetHostThrows() {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 8080, targetHost: "", targetPort: 80)
        ])
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: host))
    }

    func testForwardWithInvalidPortsThrows() {
        let badBind = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 0, targetHost: "a", targetPort: 80)
        ])
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: badBind))

        let badTarget = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 8080, targetHost: "a", targetPort: 99999)
        ])
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: badTarget))
    }

    // MARK: - extraArgs

    func testExtraArgsAppendedBeforeDestination() throws {
        let host = SSHHost(hostname: "h", extraArgs: ["-o", "Compression=yes", "-v"])
        let args = try SSHCommandBuilder.arguments(for: host)
        XCTAssertEqual(Array(args.suffix(4)), ["-o", "Compression=yes", "-v", "h"])
    }

    // MARK: - Injection rejection

    func testHostnameStartingWithDashThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "-oProxyCommand=evil"))) { error in
            guard case SSHCommandError.unsafeValue(let field, _)? = error as? SSHCommandError else {
                return XCTFail("expected unsafeValue, got \(error)")
            }
            XCTAssertEqual(field, "hostname")
        }
    }

    func testUsernameStartingWithDashThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", username: "-bad")))
    }

    func testIdentityFileStartingWithDashThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", identityFile: "-bad")))
    }

    func testHostnameWithWhitespaceThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "evil host")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "evil\thost")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "evil\nhost")))
    }

    func testUsernameWithWhitespaceThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", username: "a b")))
    }

    func testControlCharactersThrow() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h\u{0007}x")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", username: "u\u{001B}x")))
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", identityFile: "/tmp/\u{0000}key")))
        // NUL byte in hostname
        XCTAssertThrowsError(
            try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h\u{0000}x"))
        )
        // NUL byte in username
        XCTAssertThrowsError(
            try SSHCommandBuilder.arguments(for: SSHHost(hostname: "host", username: "u\u{0000}x"))
        )
    }

    func testBindAddressStartingWithDashThrows() {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindAddress: "-evil", bindPort: 8080, targetHost: "a", targetPort: 80)
        ])
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: host))
    }

    func testForwardTargetHostStartingWithDashThrows() {
        let host = SSHHost(hostname: "h", portForwards: [
            PortForward(kind: .local, bindPort: 8080, targetHost: "-evil", targetPort: 80)
        ])
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: host))
    }

    func testEmptyHostnameThrows() {
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: ""))) { error in
            XCTAssertEqual(error as? SSHCommandError, .emptyHostname)
        }
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "   ")))
    }

    // MARK: - ControlMaster multiplexing

    func testControlSocketPathAddsMultiplexingOptionsInOrder() throws {
        let host = SSHHost(hostname: "example.com", username: "alice")
        let socket = "/Users/me/.cache/harbor/cm-c8226096af42e418"
        let args = try SSHCommandBuilder.arguments(for: host, controlSocketPath: socket)
        XCTAssertEqual(args, [
            "-o", "ServerAliveInterval=30",
            "-o", "ConnectTimeout=10",
            "-o", "ControlMaster=auto",
            "-o", "ControlPath=\(socket)",
            "-o", "ControlPersist=no",
            "alice@example.com",
        ])
    }

    func testNilOrBlankControlSocketPathOmitsMultiplexing() throws {
        let host = SSHHost(hostname: "example.com")
        let plain = try SSHCommandBuilder.arguments(for: host)
        XCTAssertFalse(plain.contains { $0.hasPrefix("ControlMaster") || $0.hasPrefix("ControlPath") })
        let blank = try SSHCommandBuilder.arguments(for: host, controlSocketPath: "   ")
        XCTAssertEqual(blank, plain)
    }

    func testMultiplexingOptionsComeBeforePortAndIdentity() throws {
        let host = SSHHost(hostname: "example.com", port: 2222, identityFile: "/k")
        let args = try SSHCommandBuilder.arguments(for: host, controlSocketPath: "/tmp/cm-x")
        let persist = try XCTUnwrap(args.firstIndex(of: "ControlPersist=no"))
        let p = try XCTUnwrap(args.firstIndex(of: "-p"))
        let i = try XCTUnwrap(args.firstIndex(of: "-i"))
        XCTAssertLessThan(persist, p)
        XCTAssertLessThan(p, i)
        XCTAssertEqual(args.last, "example.com")
    }

    func testDestinationHelperMatchesArgumentsDestination() throws {
        XCTAssertEqual(SSHCommandBuilder.destination(for: SSHHost(hostname: "h", username: "u")), "u@h")
        XCTAssertEqual(SSHCommandBuilder.destination(for: SSHHost(hostname: " h ", username: "  ")), "h")
        let host = SSHHost(hostname: "example.com", username: "alice")
        let args = try SSHCommandBuilder.arguments(for: host, controlSocketPath: "/tmp/cm-x")
        XCTAssertEqual(args.last, SSHCommandBuilder.destination(for: host))
    }

    func testAuxiliaryCommandShapeKeepsScriptAsSingleArgvElement() {
        let script = "uname -s; echo @@HARBOR@@; cat /proc/uptime"
        let argv = SSHCommandBuilder.auxiliaryCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "alice@example.com",
            remoteScript: script
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-o", "ControlMaster=no",
            "-o", "ControlPath=/tmp/cm-x",
            "-o", "BatchMode=yes",
            "alice@example.com",
            script,
        ])
        XCTAssertEqual(argv.last, script) // never split, never shell-quoted locally
    }

    func testAuxiliaryCommandIncludesNonDefaultPort() {
        let argv = SSHCommandBuilder.auxiliaryCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "h",
            remoteScript: "true",
            port: 2222
        )
        let p = argv.firstIndex(of: "-p")
        XCTAssertNotNil(p)
        XCTAssertEqual(argv[argv.index(after: p!)], "2222")
        XCTAssertEqual(Array(argv.suffix(2)), ["h", "true"])

        let defaultPort = SSHCommandBuilder.auxiliaryCommand(
            controlSocketPath: "/tmp/cm-x", destination: "h", remoteScript: "true", port: 22
        )
        XCTAssertFalse(defaultPort.contains("-p"))
    }

    func testControlCheckCommandShape() {
        let argv = SSHCommandBuilder.controlCheckCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "alice@example.com"
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-o", "ControlPath=/tmp/cm-x",
            "-O", "check",
            "alice@example.com",
        ])
    }

    func testCommandForwardsControlSocketPath() throws {
        let host = SSHHost(hostname: "example.com")
        let argv = try SSHCommandBuilder.command(for: host, controlSocketPath: "/tmp/cm-x")
        XCTAssertEqual(argv.first, "/usr/bin/ssh")
        XCTAssertTrue(argv.contains("ControlPath=/tmp/cm-x"))
    }

    // MARK: - Live forward control commands

    func testControlForwardCommandLocal() throws {
        let forward = PortForward(kind: .local, bindPort: 8080, targetHost: "db", targetPort: 5432)
        let argv = try SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "alice@example.com",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "forward",
            "-L", "8080:db:5432",
            "alice@example.com",
        ])
    }

    func testControlForwardCommandRemote() throws {
        let forward = PortForward(kind: .remote, bindPort: 9000, targetHost: "localhost", targetPort: 3000)
        let argv = try SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "u@h",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "forward",
            "-R", "9000:localhost:3000",
            "u@h",
        ])
    }

    func testControlForwardCommandDynamic() throws {
        let forward = PortForward(kind: .dynamic, bindPort: 1080)
        let argv = try SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "h",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "forward",
            "-D", "1080",
            "h",
        ])
    }

    func testControlForwardCommandWithBindAddress() throws {
        let forward = PortForward(kind: .local, bindAddress: "127.0.0.1", bindPort: 8080, targetHost: "db", targetPort: 5432)
        let argv = try SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "h",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "forward",
            "-L", "127.0.0.1:8080:db:5432",
            "h",
        ])
    }

    func testControlCancelForwardCommand() throws {
        let forward = PortForward(kind: .local, bindPort: 8080, targetHost: "db", targetPort: 5432)
        let argv = try SSHCommandBuilder.controlCancelForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "alice@example.com",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "cancel",
            "-L", "8080:db:5432",
            "alice@example.com",
        ])
    }

    func testControlCancelForwardCommandRemote() throws {
        let forward = PortForward(kind: .remote, bindPort: 9000, targetHost: "localhost", targetPort: 3000)
        let argv = try SSHCommandBuilder.controlCancelForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "u@h",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "cancel",
            "-R", "9000:localhost:3000",
            "u@h",
        ])
    }

    func testControlCancelForwardCommandDynamic() throws {
        let forward = PortForward(kind: .dynamic, bindPort: 1080)
        let argv = try SSHCommandBuilder.controlCancelForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "h",
            forward: forward
        )
        XCTAssertEqual(argv, [
            "/usr/bin/ssh",
            "-S", "/tmp/cm-x",
            "-O", "cancel",
            "-D", "1080",
            "h",
        ])
    }

    func testControlForwardRejectsInvalidForward() {
        let badForward = PortForward(kind: .local, bindPort: 0, targetHost: "a", targetPort: 80)
        XCTAssertThrowsError(try SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: "/tmp/cm-x",
            destination: "h",
            forward: badForward
        ))
    }

    // MARK: - IPv6 hostnames

    func testIPv6LiteralHostnameIsValid() throws {
        // IPv6 literals should pass validation — colons are not rejected.
        let args1 = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "fe80::1"))
        XCTAssertTrue(args1.contains("fe80::1"))

        let args2 = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "2001:db8::1"))
        XCTAssertTrue(args2.contains("2001:db8::1"))

        let args3 = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "::1"))
        XCTAssertTrue(args3.contains("::1"))
    }

    // MARK: - Shell field

    func testShellFieldValidation() throws {
        // Valid shell: "-t" is inserted before the destination, shell appears after.
        let host = SSHHost(hostname: "example.com", username: "alice", shell: "powershell.exe")
        let args = try SSHCommandBuilder.arguments(for: host)
        let destIndex = try XCTUnwrap(args.firstIndex(of: "alice@example.com"))
        let tIndex = try XCTUnwrap(args.firstIndex(of: "-t"))
        XCTAssertLessThan(tIndex, destIndex)
        XCTAssertEqual(args.last, "powershell.exe")

        // Shell starting with "-" should throw.
        XCTAssertThrowsError(
            try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", shell: "-bash"))
        )

        // Shell containing a control character should throw.
        XCTAssertThrowsError(
            try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", shell: "bash\u{01}"))
        )

        // Empty shell should NOT insert a "-t" flag.
        let noShell = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", shell: ""))
        XCTAssertFalse(noShell.contains("-t"))

        // Whitespace-only shell also collapses to empty — no "-t".
        let blankShell = try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", shell: "   "))
        XCTAssertFalse(blankShell.contains("-t"))
    }

    // MARK: - extraArgs allowlist

    func testExtraArgsAllowSafeOptionsAndStandaloneFlags() {
        XCTAssertNoThrow(try SSHCommandBuilder.arguments(for: SSHHost(
            hostname: "h",
            extraArgs: ["-v", "-C", "-o", "Compression=yes", "-oLogLevel=DEBUG"]
        )))
    }

    func testExtraArgsRejectLocalExecutionAndLibraryLoadingOptions() {
        for option in [
            "ProxyCommand=/usr/bin/true",
            "PermitLocalCommand=yes",
            "LocalCommand=/usr/bin/true",
            "KnownHostsCommand=/usr/bin/true",
            "PKCS11Provider=/tmp/provider.dylib",
            "SecurityKeyProvider=/tmp/provider.dylib",
            "XAuthLocation=/tmp/xauth",
            "IdentityAgent=/tmp/agent.sock",
            "CertificateFile=/tmp/user-cert.pub",
            "AddKeysToAgent=yes",
            "SendEnv=AWS_SECRET_ACCESS_KEY",
            "Include=/tmp/ssh.conf",
        ] {
            XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(
                hostname: "h", extraArgs: ["-o", option]
            )), "must reject \(option)")
        }
    }

    func testExtraArgsRejectHostVerificationAndConnectionRedirection() {
        for option in [
            "StrictHostKeyChecking=no",
            "UserKnownHostsFile=/dev/null",
            "GlobalKnownHostsFile=/dev/null",
            "HostKeyAlias=trusted.example",
            "Hostname=evil.example",
            "ProxyJump=bastion",
            "ControlPath=/tmp/other-socket",
            "RemoteCommand=true",
        ] {
            XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(
                hostname: "h", extraArgs: ["-o", option]
            )), "must reject \(option)")
        }
        for flag in ["-F/tmp/config", "-I/tmp/provider.dylib", "-Jbastion", "-S/tmp/socket", "-E/tmp/log"] {
            XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(
                hostname: "h", extraArgs: [flag]
            )), "must reject \(flag)")
        }
    }

    func testExtraArgsRejectUnknownMalformedOrWhitespaceTokens() {
        let bad: [[String]] = [
            ["-o"],
            ["-o", "Compression"],
            ["-o", "UnknownFutureOption=yes"],
            ["-oCompression"],
            ["Compression=yes"],
            ["-o", "Compression=yes now"],
        ]
        for args in bad {
            XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(
                hostname: "h", extraArgs: args
            )), "must reject \(args)")
        }
    }

    // MARK: - Port boundary values

    func testPortBoundaryValues() {
        // Minimum valid port.
        XCTAssertNoThrow(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 1)))

        // Maximum valid port.
        XCTAssertNoThrow(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 65535)))

        // Port 0 is invalid.
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 0)))

        // Port 65536 is one past the maximum and must be rejected.
        XCTAssertThrowsError(try SSHCommandBuilder.arguments(for: SSHHost(hostname: "h", port: 65536)))
    }
}
