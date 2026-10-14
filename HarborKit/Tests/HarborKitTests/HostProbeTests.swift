import XCTest
import Network
@testable import HarborKit

final class HostProbeTests: XCTestCase {
    // MARK: - parseBanner (pure)

    func testParseBannerStandard() {
        XCTAssertEqual(HostProber.parseBanner(Data("SSH-2.0-OpenSSH_9.9\r\n".utf8)), "SSH-2.0-OpenSSH_9.9")
    }

    func testParseBannerWithoutNewline() {
        XCTAssertEqual(HostProber.parseBanner(Data("SSH-1.99-Cisco".utf8)), "SSH-1.99-Cisco")
    }

    func testParseBannerToleratesPreamble() {
        // RFC 4253 permits other lines before the identification string.
        let data = Data("note: maintenance tonight\r\nSSH-2.0-OpenSSH_8.4\r\n".utf8)
        XCTAssertEqual(HostProber.parseBanner(data), "SSH-2.0-OpenSSH_8.4")
    }

    func testParseBannerRejectsNonSSH() {
        XCTAssertNil(HostProber.parseBanner(Data("HTTP/1.1 200 OK\r\n".utf8)))
        XCTAssertNil(HostProber.parseBanner(Data()))
    }

    func testParseBannerCapsPreambleAt50Lines() {
        let preamble = (1...51).map { "line \($0)" }.joined(separator: "\n") + "\nSSH-2.0-late\n"
        XCTAssertNil(HostProber.parseBanner(Data(preamble.utf8)))
    }

    // MARK: - DNS

    func testResolveLocalhost() async {
        switch await HostProber.resolve(hostname: "localhost", timeout: 5) {
        case .success(let addresses):
            XCTAssertFalse(addresses.isEmpty)
            XCTAssertTrue(addresses.contains("127.0.0.1") || addresses.contains("::1"),
                          "unexpected addresses: \(addresses)")
        case .failure(let error):
            XCTFail("localhost must resolve: \(error)")
        }
    }

    func testResolveInvalidTLDFails() {
        // RFC 2606 reserves .invalid; resolution must fail. This needs a
        // working resolver to answer NXDOMAIN, so a timeout (fully offline
        // resolver) is also an acceptable failure outcome — just not success.
        let expectation = expectation(description: "resolve")
        Task {
            let result = await HostProber.resolve(hostname: "harbor-test.invalid", timeout: 10)
            switch result {
            case .success(let addresses):
                XCTFail(".invalid must not resolve: \(addresses)")
            case .failure(let error):
                if case .dnsFailed = error {} else if case .timeout = error {} else {
                    XCTFail("unexpected error: \(error)")
                }
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 15)
    }

    // MARK: - TCP + banner over loopback

    /// Minimal TCP server: sends a fixed payload to the first connection.
    private final class BannerServer {
        let listener: NWListener
        let port: Int

        init(payload: String) throws {
            listener = try NWListener(using: .tcp, on: .any)
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready.signal() }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: .global())
                connection.send(
                    content: Data(payload.utf8),
                    completion: .contentProcessed { _ in connection.cancel() }
                )
            }
            listener.start(queue: .global())
            guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port else {
                throw XCTSkip("loopback listener did not become ready")
            }
            self.port = Int(port.rawValue)
        }

        func stop() { listener.cancel() }
    }

    func testBannerFromLiveServer() async throws {
        let server = try BannerServer(payload: "SSH-2.0-HarborTest_1.0\r\n")
        defer { server.stop() }
        switch await HostProber.probe(host: "127.0.0.1", port: server.port, banner: true, timeout: 5) {
        case .success(let banner):
            XCTAssertEqual(banner, "SSH-2.0-HarborTest_1.0")
        case .failure(let error):
            XCTFail("banner probe failed: \(error)")
        }
    }

    func testNonSSHBannerIsRejected() async throws {
        let server = try BannerServer(payload: "HTTP/1.1 400 Bad Request\r\n")
        defer { server.stop() }
        switch await HostProber.probe(host: "127.0.0.1", port: server.port, banner: true, timeout: 5) {
        case .success(let banner):
            XCTFail("non-SSH banner must not pass: \(banner)")
        case .failure(let error):
            XCTAssertEqual(error, .notSSHServer)
        }
    }

    func testPlainTCPProbeSucceedsWithoutBanner() async throws {
        // RDP path: connect success is enough, no banner expected.
        let server = try BannerServer(payload: "")
        defer { server.stop() }
        switch await HostProber.probe(host: "127.0.0.1", port: server.port, banner: false, timeout: 5) {
        case .success:
            break
        case .failure(let error):
            XCTFail("plain TCP probe failed: \(error)")
        }
    }

    func testConnectionRefused() async throws {
        // Bind then drop a listener so its port is (almost certainly) closed.
        let server = try BannerServer(payload: "")
        let port = server.port
        server.stop()
        switch await HostProber.probe(host: "127.0.0.1", port: port, banner: false, timeout: 5) {
        case .success:
            XCTFail("a closed port must not connect")
        case .failure(let error):
            if case .connectFailed = error {} else {
                XCTFail("expected connectFailed, got \(error)")
            }
        }
    }

    func testInvalidPortRejected() async {
        let result = await HostProber.probe(host: "127.0.0.1", port: 0, banner: false, timeout: 1)
        XCTAssertEqual(result, .failure(.invalidPort))
    }
}
