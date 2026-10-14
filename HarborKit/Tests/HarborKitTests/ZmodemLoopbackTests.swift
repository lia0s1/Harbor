//
//  ZmodemLoopbackTests.swift
//  HarborKitTests
//
//  In-process loopback: a Harbor sender session wired directly to a Harbor
//  receiver session, each side's onSend feeding the other's input.
//

import CryptoKit
import XCTest
@testable import HarborKit

final class ZmodemLoopbackTests: XCTestCase {

    private let Z = ZmodemConstants.self
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zmodem-loopback-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Harness

    private func makeFile(_ name: String, _ bytes: Data) -> URL {
        let url = tempDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: bytes)
        return url
    }

    private func randomBytes(_ count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Bytes that all need ZDLE escaping, densely packed, plus a sweep of the
    /// whole byte range.
    private var escapeHeavyBytes: Data {
        var data = Data()
        for _ in 0..<64 {
            data.append(contentsOf: [0x00, 0x10, 0x11, 0x13, 0x18, 0x0D, 0x8D, 0x90, 0x91, 0x93])
        }
        for _ in 0..<32 { data.append(contentsOf: 0...255) }
        return data
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private final class Wire {
        var sender: ZmodemSession
        var receiver: ZmodemSession
        /// Test hook: mutate one sender->receiver chunk (used once).
        var corruptFirstLargeChunk = false
        private var corruptionSpent = false
        private(set) var events: [ZmodemSessionEvent] = []

        init(files: [URL], directory: URL) {
            sender = ZmodemSession(role: .send(files: files))
            receiver = ZmodemSession(role: .receive(directory: directory))
            sender.onSend = { [weak self, weak receiver] data in
                guard let self, let receiver else { return }
                var data = data
                if self.corruptFirstLargeChunk, !self.corruptionSpent, data.count > 500 {
                    // Flip a bit in the trailing CRC bytes: structure stays
                    // intact, the checksum must fail.
                    data[data.count - 1] ^= 0xFF
                    self.corruptionSpent = true
                }
                receiver.input(data)
            }
            receiver.onSend = { [weak sender] data in
                sender?.input(data)
            }
            sender.onEvent = { [weak self] in self?.events.append($0) }
            receiver.onEvent = { [weak self] in self?.events.append($0) }
        }

        /// Simulate the already-running `rz` side kicking the transfer off.
        func kickoffUpload() {
            sender.input(ZmodemFraming.encodeHeader(type: ZmodemConstants.zrqinit, position: 0, format: .hex))
        }

        /// Simulate `sz` having sent ZRQINIT: our receiver answers ZRINIT,
        /// which kicks the sender — the spec-ordered handshake.
        func kickoffDownload() {
            receiver.input(ZmodemFraming.encodeHeader(type: ZmodemConstants.zrqinit, position: 0, format: .hex))
        }
    }

    // MARK: - Happy paths

    func testUploadRandomBinary() {
        let original = randomBytes(256 * 1024 + 123)
        let src = makeFile("random.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        let received = try! Data(contentsOf: dir.appendingPathComponent("random.bin"))
        XCTAssertEqual(received, original)
        XCTAssertEqual(sha256(received), sha256(original))
    }

    func testDownloadKickoffHandshake() {
        let original = randomBytes(33_000)
        let src = makeFile("download.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffDownload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        let received = try! Data(contentsOf: dir.appendingPathComponent("download.bin"))
        XCTAssertEqual(received, original)
    }

    func testUploadEscapeHeavyFile() {
        let original = escapeHeavyBytes
        let src = makeFile("escape.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("escape.bin")), original)
    }

    func testUploadEmptyFile() {
        let src = makeFile("empty.bin", Data())
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("empty.bin")), Data())
    }

    func testUploadMultipleFiles() {
        let files = [
            makeFile("one.bin", randomBytes(1_024)),
            makeFile("two.bin", Data()),
            makeFile("three.bin", escapeHeavyBytes),
        ]
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: files, directory: dir)

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        for f in files {
            XCTAssertEqual(
                try! Data(contentsOf: dir.appendingPathComponent(f.lastPathComponent)),
                try! Data(contentsOf: f),
                f.lastPathComponent
            )
        }
    }

    func testUploadOneMegabyte() {
        let original = randomBytes(1_048_576)
        let src = makeFile("big.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(sha256(try! Data(contentsOf: dir.appendingPathComponent("big.bin"))), sha256(original))
    }

    // MARK: - Resume and recovery

    func testResumeFromExistingPartialFile() {
        let original = randomBytes(100_000)
        let src = makeFile("resume.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Pretend a previous transfer died after 40 000 bytes.
        let partial = original.prefix(40_000)
        try! partial.write(to: dir.appendingPathComponent("resume.bin"))

        let wire = Wire(files: [src], directory: dir)
        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("resume.bin")), original)
    }

    func testCompleteExistingFileIsNoOpTransfer() {
        let original = randomBytes(10_000)
        let src = makeFile("done.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! original.write(to: dir.appendingPathComponent("done.bin"))

        let wire = Wire(files: [src], directory: dir)
        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("done.bin")), original)
    }

    func testCorruptedChunkRecoversViaZRPOS() {
        let original = randomBytes(200_000)
        let src = makeFile("corrupt.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)
        wire.corruptFirstLargeChunk = true

        wire.kickoffUpload()

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("corrupt.bin")), original)
    }

    // MARK: - Backpressure

    func testBackpressurePauseResume() {
        let original = randomBytes(100_000)
        let src = makeFile("paced.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)
        var chunkCount = 0
        wire.sender.shouldPauseSending = {
            chunkCount += 1
            return chunkCount % 3 == 0   // pause every third chunk
        }

        wire.kickoffUpload()

        var guardCount = 0
        while wire.sender.phase != .completed && guardCount < 1_000 {
            wire.sender.resumePump()
            guardCount += 1
        }

        XCTAssertEqual(wire.sender.phase, .completed)
        XCTAssertEqual(wire.receiver.phase, .completed)
        XCTAssertEqual(try! Data(contentsOf: dir.appendingPathComponent("paced.bin")), original)
    }

    // MARK: - Events

    func testProgressAndCompletionEvents() {
        let original = randomBytes(50_000)
        let src = makeFile("events.bin", original)
        let dir = tempDir.appendingPathComponent("downloads")
        let wire = Wire(files: [src], directory: dir)

        wire.kickoffUpload()

        let progresses = wire.events.compactMap { event -> ZmodemProgress? in
            if case .progress(let p) = event { return p }
            return nil
        }
        XCTAssertFalse(progresses.isEmpty)
        XCTAssertEqual(progresses.last?.fileBytesTransferred, UInt64(original.count))
        XCTAssertEqual(progresses.last?.fileSize, UInt64(original.count))

        let completions = wire.events.compactMap { event -> String? in
            if case .fileCompleted(let name, _) = event { return name }
            return nil
        }
        XCTAssertTrue(completions.contains("events.bin"))
    }
}
