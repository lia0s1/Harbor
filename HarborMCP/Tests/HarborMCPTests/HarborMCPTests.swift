import XCTest
import HarborKit
@testable import HarborMCP

final class HarborMCPTests: XCTestCase {
    func testBoundedLineReaderRejectsOversizedLineAndRecovers() throws {
        let pipe = Pipe()
        XCTAssertTrue(writeAll(
            fd: pipe.fileHandleForWriting.fileDescriptor,
            data: Data("12345\nok\n".utf8)
        ))
        try pipe.fileHandleForWriting.close()

        var reader = BoundedLineReader(
            fd: pipe.fileHandleForReading.fileDescriptor,
            maxBytes: 4
        )
        guard case .tooLong? = try reader.next() else {
            return XCTFail("expected oversized line")
        }
        guard case .line(let line)? = try reader.next() else {
            return XCTFail("expected recovery line")
        }
        XCTAssertEqual(String(decoding: line, as: UTF8.self), "ok")
        XCTAssertNil(try reader.next())
    }

    func testWriteAllTransfersCompleteBuffer() throws {
        let pipe = Pipe()
        let expected = Data(repeating: 0x5a, count: 256 * 1_024)
        let received = LockedData()
        let finished = DispatchSemaphore(value: 0)

        DispatchQueue.global().async {
            defer { finished.signal() }
            let handle = pipe.fileHandleForReading
            do {
                while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
                    received.append(chunk)
                }
            } catch {
                return
            }
        }

        XCTAssertTrue(writeAll(fd: pipe.fileHandleForWriting.fileDescriptor, data: expected))
        try pipe.fileHandleForWriting.close()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(received.value(), expected)
    }

    func testResolutionOnlyAllowsUniqueSavedSSHHosts() throws {
        let host = SSHHost(name: "alpha", hostname: "example.test", username: "alice")
        let server = try makeServer(hosts: [host])

        XCTAssertEqual(try server.resolve("alpha").host.id, host.id)
        XCTAssertEqual(try server.resolve("example.test").host.id, host.id)
        XCTAssertThrowsError(try server.resolve("bob@unknown.test:2222"))

        let duplicate = SSHHost(name: "other", hostname: "example.test")
        let ambiguousServer = try makeServer(hosts: [host, duplicate])
        XCTAssertThrowsError(try ambiguousServer.resolve("example.test"))

        var rdp = host
        rdp.connectionProtocol = .rdp
        let rdpServer = try makeServer(hosts: [rdp])
        XCTAssertThrowsError(try rdpServer.resolve("alpha"))
    }

    func testSavedHostsAreValidatedBeforeUse() throws {
        let unsafe = SSHHost(
            name: "unsafe",
            hostname: "example.test",
            extraArgs: ["-F", "/tmp/attacker-config"]
        )
        let server = try makeServer(hosts: [unsafe])
        XCTAssertThrowsError(try server.loadHosts())
    }

    func testSSHArgvUsesBuilderAndStrictKnownHosts() throws {
        let host = SSHHost(
            name: "alpha",
            hostname: "example.test",
            username: "alice",
            extraArgs: ["-o", "BatchMode=no"]
        )
        let server = try makeServer(hosts: [host])
        let resolved = try server.resolve("alpha")
        let argv = try server.sshArgv(for: resolved, command: "id")

        XCTAssertEqual(argv.first, SSHCommandBuilder.executablePath)
        XCTAssertTrue(argv.contains("StrictHostKeyChecking=yes"))
        XCTAssertFalse(argv.contains(where: { $0.contains("accept-new") }))
        XCTAssertEqual(argv.last, "id")
        XCTAssertLessThan(
            try XCTUnwrap(argv.firstIndex(of: "BatchMode=yes")),
            try XCTUnwrap(argv.firstIndex(of: "BatchMode=no"))
        )
        XCTAssertTrue(resolved.socketPath.contains("strict-cm-"))
    }

    func testSSHArgvDropsInteractiveOptionsThatBreakMCPPipes() throws {
        let host = SSHHost(
            name: "alpha",
            hostname: "example.test",
            extraArgs: [
                "-n", "-N", "-t", "-vvv", "-C",
                "-o", "RequestTTY=force",
                "-o", "Compression=yes",
            ]
        )
        let server = try makeServer(hosts: [host])
        let argv = try server.sshArgv(for: server.resolve("alpha"), command: "id")

        for blocked in ["-n", "-N", "-t", "-vvv", "RequestTTY=force"] {
            XCTAssertFalse(argv.contains(blocked))
        }
        XCTAssertTrue(argv.contains("-C"))
        XCTAssertTrue(argv.contains("Compression=yes"))
    }

    func testToolFailuresUseMCPIsErrorAndInvalidParamsUseRPCError() throws {
        let server = try makeServer()
        let toolResponse = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": ["name": "unknown", "arguments": [:] as [String: Any]],
        ]))
        let toolResult = try XCTUnwrap(toolResponse["result"] as? [String: Any])
        XCTAssertEqual(toolResult["isError"] as? Bool, true)

        let rpcResponse = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "tools/call",
            "params": ["name": "run_command", "arguments": "bad"],
        ]))
        let rpcError = try XCTUnwrap(rpcResponse["error"] as? [String: Any])
        XCTAssertEqual(rpcError["code"] as? Int, -32602)
    }

    func testDefaultAuthorizationExposesNoRemoteTools() throws {
        let server = try makeServer(hosts: [SSHHost(name: "alpha", hostname: "example.test")])
        XCTAssertEqual(try toolNames(server), [])

        let result = server.callTool("run_command", args: [
            "host": "alpha",
            "command": "id",
        ])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains(MCPAuthorization.allowedHostsVariable))
    }

    func testAuthorizationRestrictsHostsAndDestructiveCapabilities() throws {
        let alpha = SSHHost(name: "alpha", hostname: "alpha.example.test")
        let beta = SSHHost(name: "beta", hostname: "beta.example.test")
        let readOnly = MCPAuthorization(
            allowedHosts: ["ALPHA"],
            allowsRunCommand: false,
            allowsWriteFile: false
        )
        let server = try makeServer(hosts: [alpha, beta], authorization: readOnly)

        XCTAssertEqual(
            try toolNames(server),
            Set(["list_hosts", "list_files", "read_file", "get_system_info"])
        )
        let listed = server.callTool("list_hosts", args: [:])
        XCTAssertFalse(listed.isError)
        XCTAssertTrue(listed.text.contains("alpha"))
        XCTAssertFalse(listed.text.contains("beta"))

        let blockedHost = server.callTool("list_files", args: ["host": "beta"])
        XCTAssertTrue(blockedHost.isError)
        XCTAssertTrue(blockedHost.text.contains(MCPAuthorization.allowedHostsVariable))

        let blockedCommand = server.callTool("run_command", args: [
            "host": "alpha",
            "command": "id",
        ])
        XCTAssertTrue(blockedCommand.isError)
        XCTAssertTrue(blockedCommand.text.contains(MCPAuthorization.runCommandVariable))

        let blockedWrite = server.callTool("write_file", args: [
            "host": "alpha",
            "path": "/tmp/harbor-audit",
            "content": "x",
        ])
        XCTAssertTrue(blockedWrite.isError)
        XCTAssertTrue(blockedWrite.text.contains(MCPAuthorization.writeFileVariable))

        let destructive = MCPAuthorization(
            allowedHosts: ["alpha.example.test"],
            allowsRunCommand: true,
            allowsWriteFile: true
        )
        let destructiveServer = try makeServer(hosts: [alpha], authorization: destructive)
        XCTAssertEqual(
            try toolNames(destructiveServer),
            Set(["list_hosts", "list_files", "read_file", "get_system_info", "run_command", "write_file"])
        )
    }

    func testProcessDrainsInputOutputAndStderrWithoutDataRaces() throws {
        let server = try makeServer(limits: limits(
            processInput: 256 * 1_024,
            processOutput: 256 * 1_024,
            processError: 256 * 1_024
        ))
        let input = Data(repeating: 0x61, count: 128 * 1_024)
        let echoed = try server.exec(argv: ["/bin/cat"], stdin: input, timeout: 2)
        XCTAssertEqual(Data(echoed.out.utf8), input)
        XCTAssertEqual(echoed.status, 0)

        let both = try server.exec(
            argv: [
                "/bin/sh", "-c",
                "head -c 65536 /dev/zero; head -c 65536 /dev/zero >&2",
            ],
            timeout: 2
        )
        XCTAssertEqual(both.out.utf8.count, 65_536)
        XCTAssertEqual(both.err.utf8.count, 65_536)
        XCTAssertEqual(both.status, 0)
    }

    func testProcessEnforcesAllStreamLimits() throws {
        let outputServer = try makeServer(limits: limits(
            processInput: 16,
            processOutput: 128,
            processError: 128
        ))
        XCTAssertThrowsError(try outputServer.exec(
            argv: ["/bin/sh", "-c", "head -c 4096 /dev/zero"],
            timeout: 2
        ))
        XCTAssertThrowsError(try outputServer.exec(
            argv: ["/bin/sh", "-c", "head -c 4096 /dev/zero >&2"],
            timeout: 2
        ))
        XCTAssertThrowsError(try outputServer.exec(
            argv: ["/bin/cat"],
            stdin: Data(repeating: 0, count: 17),
            timeout: 2
        ))
    }

    func testProcessTimeoutTerminatesCommand() throws {
        let server = try makeServer()
        let start = Date()
        XCTAssertThrowsError(try server.exec(
            argv: ["/bin/sh", "-c", "trap '' TERM; sleep 10"],
            timeout: 0.05
        ))
        XCTAssertLessThan(Date().timeIntervalSince(start), 3)
    }

    func testNonzeroExitIsReportedAndSuccessfulBytesAreNotTrimmed() throws {
        let server = try makeServer()
        let failed = try server.exec(
            argv: ["/bin/sh", "-c", "printf output; printf failure >&2; exit 7"],
            timeout: 2
        )
        XCTAssertEqual(failed.status, 7)
        XCTAssertThrowsError(try server.checkedSSHOutput(failed))

        let exact = MCPServer.ExecutionResult(out: "  value\n", err: "", status: 0)
        XCTAssertEqual(try server.checkedSSHOutput(exact), "  value\n")
    }

    func testAtomicWritePreservesExactContentWithoutAddedNewline() throws {
        let server = try makeServer()
        let directory = try temporaryDirectory()
        let target = directory.appendingPathComponent("target ' file")
        let content = "no trailing newline\u{0}尾"
        let request = try server.remoteWriteRequest([
            "host": "alpha",
            "path": target.path,
            "content": content,
        ])

        XCTAssertEqual(request.input, Data(content.utf8))
        XCTAssertTrue(request.command.contains("mktemp"))
        XCTAssertTrue(request.command.contains("mv -f"))
        XCTAssertTrue(request.command.contains("-L \"$target\""))
        let result = try server.exec(
            argv: ["/bin/sh", "-c", request.command],
            stdin: request.input,
            timeout: 2
        )
        XCTAssertEqual(result.status, 0, result.err)
        XCTAssertEqual(try Data(contentsOf: target), request.input)
    }

    func testHostStoreAndWriteContentHaveHardLimits() throws {
        let tiny = limits(
            hostStore: 8,
            processInput: 4,
            processOutput: 128,
            processError: 128
        )
        let server = try makeServer(hosts: [SSHHost(name: "a", hostname: "b")], limits: tiny)
        XCTAssertThrowsError(try server.loadHosts())
        XCTAssertThrowsError(try server.remoteWriteRequest([
            "host": "a", "path": "/tmp/a", "content": "12345",
        ]))
    }

    // MARK: - Helpers

    private func makeServer(
        hosts: [SSHHost] = [],
        limits: MCPLimits = .production,
        authorization: MCPAuthorization = .denyAll
    ) throws -> MCPServer {
        let directory = try temporaryDirectory()
        let hostsURL = directory.appendingPathComponent("hosts.json")
        try HostStoreCodec.encode(hosts).write(to: hostsURL)
        return MCPServer(
            socketDir: directory.appendingPathComponent("sockets").path,
            hostsURL: hostsURL,
            limits: limits,
            authorization: authorization
        )
    }

    private func toolNames(_ server: MCPServer) throws -> Set<String> {
        let response = try XCTUnwrap(server.handle([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/list",
        ]))
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let tools = try XCTUnwrap(result["tools"] as? [[String: Any]])
        return Set(try tools.map { try XCTUnwrap($0["name"] as? String) })
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborMCPTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func limits(request: Int = 1_024,
                        hostStore: Int = 1_024,
                        processInput: Int = 1_024,
                        processOutput: Int = 1_024,
                        processError: Int = 1_024) -> MCPLimits {
        MCPLimits(
            requestBytes: request,
            hostStoreBytes: hostStore,
            processInputBytes: processInput,
            processOutputBytes: processOutput,
            processErrorBytes: processError
        )
    }
}

private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func value() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
