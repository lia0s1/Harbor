//
//  ZmodemSession.swift
//  HarborKit
//
//  A complete ZModem sender (answers remote `rz` — uploads local files) and
//  receiver (answers remote `sz` — downloads into a local directory).
//
//  The session is a pure byte-in/byte-out state machine: it never touches a
//  PTY, socket, or terminal. Feed it bytes via `input(_:)`; it emits bytes to
//  the peer through `onSend` and lifecycle updates through `onEvent`. File
//  system access is limited to reading the upload files and writing received
//  files under the chosen directory.
//
//  Drive a session from ONE serial context (e.g. SwiftTerm's I/O queue or a
//  dedicated DispatchQueue). Callbacks fire synchronously on the caller.
//

import Foundation

public enum ZmodemRole: Sendable {
    /// Answer a remote `rz`: upload these local files.
    case send(files: [URL])
    /// Answer a remote `sz`: download into this directory (created if needed).
    case receive(directory: URL)
}

public enum ZmodemPhase: String, Equatable, Sendable {
    case idle           // created, waiting for the peer's opening frame
    case negotiating    // ZRINIT / ZFILE exchange in progress
    case transferring   // data subpackets flowing
    case finishing      // ZFIN handshake
    case completed
    case cancelled
    case failed
}

public struct ZmodemProgress: Equatable, Sendable {
    public var fileName: String
    public var fileIndex: Int
    public var fileCount: Int
    public var fileBytesTransferred: UInt64
    public var fileSize: UInt64
}

public enum ZmodemSessionEvent: Equatable, Sendable {
    case phaseChanged(ZmodemPhase)
    case progress(ZmodemProgress)
    case fileCompleted(name: String, localURL: URL)
}

public enum ZmodemError: Error, Equatable, Sendable {
    case cancelled
    case abortedByPeer
    case protocolError(String)
    case fileIO(String)
    /// Peer frames kept failing CRC / arriving garbled past the retry budget.
    case tooManyErrors
    /// ZModem positions are 32-bit; files >= 4 GiB are refused.
    case fileTooLarge(String)
}

public final class ZmodemSession: @unchecked Sendable {

    // MARK: - Public surface

    public let role: ZmodemRole
    /// Bytes to write toward the remote rz/sz process.
    public var onSend: (@Sendable (Data) -> Void)?
    public var onEvent: (@Sendable (ZmodemSessionEvent) -> Void)?

    /// Payload bytes per data subpacket. 1024 matches lrzsz defaults.
    public var chunkSize: Int
    /// Consecutive garbled frames tolerated before the session gives up.
    public var maxErrorCount: Int

    /// Optional backpressure hook (sender role). Called between chunks; return
    /// true to pause the pump when the downstream write queue is full, then
    /// call `resumePump()` once it drains. Without it the whole file is
    /// blasted synchronously (fine over a PTY for moderate sizes).
    public var shouldPauseSending: (@Sendable () -> Bool)?

    /// Continues a pump paused by `shouldPauseSending`.
    public func resumePump() {
        guard pumping, isActive else { return }
        pump()
    }

    public private(set) var phase: ZmodemPhase = .idle
    public private(set) var error: ZmodemError?

    public var isActive: Bool {
        phase != .completed && phase != .cancelled && phase != .failed
    }

    public init(role: ZmodemRole, chunkSize: Int = 1024, maxErrorCount: Int = 10) {
        self.role = role
        self.chunkSize = max(64, min(chunkSize, 8192))
        self.maxErrorCount = max(1, maxErrorCount)
        switch role {
        case .send(let files):
            self.sendQueue = files
            self.receiveDirectory = nil
        case .receive(let directory):
            self.sendQueue = []
            self.receiveDirectory = directory
        }
    }

    deinit {
        try? sendHandle?.close()
        try? receiveHandle?.close()
    }

    /// Feed bytes received from the peer.
    public func input(_ data: Data) {
        inputSlice(ArraySlice(data))
    }

    public func input(_ slice: ArraySlice<UInt8>) {
        inputSlice(slice)
    }

    /// Abort the transfer: emit a ZCAN burst (8 CAN + 8 BS) and stop.
    public func cancel() {
        guard isActive else { return }
        emit(ZmodemFraming.encodeCancel())
        terminate(.cancelled, error: .cancelled)
    }

    // MARK: - Internal state

    private enum Machine: Equatable {
        case idle
        case senderAwaitFileResponse   // ZFILE sent, expecting ZRPOS/ZSKIP/ZCRC
        case senderAwaitFileAck        // ZEOF sent, expecting ZRINIT
        case senderAwaitFin            // ZFIN sent, expecting ZFIN
        case receiverAwaitFile         // ZRINIT sent / between files
        case receiverReceiving         // ZRPOS sent, data arriving
    }

    private let parser = ZmodemParser()
    private var machine: Machine = .idle
    private var errorCount = 0

    /// Negotiated capabilities (sender learns them from the peer's ZRINIT).
    private var peerCanCRC32 = false
    private var peerEscctl = false
    /// Mirrors the CRC width of binary frames the peer actually sends us, so
    /// our replies stay in a format the peer demonstrably parses.
    private var peerSentCRC32 = false

    // Sender state
    private let sendQueue: [URL]
    private var sendIndex = 0
    private var sendHandle: FileHandle?
    private var sendFileSize: UInt64 = 0
    private var sendFileName = ""
    private var sendOffset: UInt64 = 0

    // Receiver state
    private let receiveDirectory: URL?
    private var receiveHandle: FileHandle?
    private var receiveURL: URL?
    private var receiveName = ""
    private var receiveOffset: UInt64 = 0
    private var receiveAnnouncedSize: UInt64?
    private var receiveCompletedCount = 0
    private var awaitingFileInfo = false
    private var discardData = false

    // MARK: - Input handling

    private func inputSlice(_ slice: ArraySlice<UInt8>) {
        guard isActive else { return }
        for event in parser.input(slice) {
            guard isActive else { return }
            switch event {
            case .header(let header):
                if header.format == .bin32 { peerSentCRC32 = true }
                if header.format == .bin16 { peerSentCRC32 = false }
                handleHeader(header)
            case .dataSubpacket(let data, let terminator, let crcValid):
                handleSubpacket(data, terminator: terminator, crcValid: crcValid)
            case .corruptFrame:
                noteErrorAndResend()
            case .cancel:
                terminate(.cancelled, error: .cancelled)
            }
        }
    }

    private func handleHeader(_ h: ZmodemHeader) {
        let Z = ZmodemConstants.self

        // Frames with the same meaning in every state.
        switch h.type {
        case Z.zchallenge:
            // Spec answer: echo the challenge number back in a ZACK.
            sendHeader(type: Z.zack, position: h.position, format: .hex)
            return
        case Z.zabort, Z.zferr:
            fail(.abortedByPeer)
            return
        case Z.zcan:
            terminate(.cancelled, error: .cancelled)
            return
        case Z.zcompl:
            return
        case Z.zsinit, Z.zcommand:
            // ZSINIT carries an attention string we never act on; ZCOMMAND
            // would ask us to execute a remote command — refuse both without
            // breaking the session. (ZCOMMAND is a deliberate non-feature.)
            sendHeader(type: Z.zcompl, position: 0, format: .hex)
            return
        case Z.zfreecnt:
            sendHeader(type: Z.zcompl, position: 0, format: .hex)
            return
        default:
            break
        }

        switch machine {

        // MARK: sender states
        case .idle:
            switch (role, h.type) {
            case (.send, Z.zrqinit):
                // rz already running: it repeats ZRQINIT until a ZFILE shows up.
                startSendingCurrentFile()
            case (.send, Z.zrinit):
                noteCaps(h)
                startSendingCurrentFile()
            case (.receive, Z.zrqinit):
                sendZRINIT()
            case (.receive, Z.zfile):
                // sz skipped the ZRQINIT dance (or we joined mid-stream).
                awaitingFileInfo = true
                machine = .receiverAwaitFile
            case (.receive, Z.zfin):
                sendZFIN()
                complete()
            default:
                break
            }

        case .senderAwaitFileResponse:
            switch h.type {
            case Z.zrpos:
                sendDataFrom(offset: UInt64(min(h.position, UInt32(sendFileSize))))
            case Z.zskip:
                advanceToNextFile()
            case Z.zcrc:
                sendFileCRC()
            case Z.zrinit:
                noteCaps(h)
                sendCurrentFileHeader()
            case Z.zrqinit, Z.znak:
                sendCurrentFileHeader()
            default:
                break
            }

        case .senderAwaitFileAck:
            switch h.type {
            case Z.zrinit:
                noteCaps(h)
                advanceToNextFile()
            case Z.zrpos:
                // Receiver lost data; resume from where it actually got to.
                sendDataFrom(offset: UInt64(min(h.position, UInt32(sendFileSize))))
            case Z.znak, Z.zrqinit:
                sendEOF()
            default:
                break
            }

        case .senderAwaitFin:
            switch h.type {
            case Z.zfin:
                emit(ZmodemFraming.encodeOverAndOut())
                complete()
            case Z.zrqinit, Z.zrinit:
                sendZFIN()
            default:
                break
            }

        // MARK: receiver states
        case .receiverAwaitFile:
            switch h.type {
            case Z.zrqinit:
                sendZRINIT()
            case Z.zfile:
                awaitingFileInfo = true
            case Z.zfin:
                sendZFIN()
                complete()
            case Z.znak:
                sendZRINIT()
            default:
                break
            }

        case .receiverReceiving:
            switch h.type {
            case Z.zdata:
                if UInt64(h.position) == receiveOffset {
                    discardData = false
                } else {
                    // Sender started somewhere unexpected; swallow this frame
                    // and tell it where to really resume.
                    discardData = true
                    sendZRPOS(receiveOffset)
                }
            case Z.zeof:
                if !discardData && UInt64(h.position) == receiveOffset {
                    finishReceivedFile()
                } else {
                    sendZRPOS(receiveOffset)
                }
            case Z.zfin:
                // Peer gave up mid-file: keep the partial file, end cleanly.
                closeReceiveHandle()
                sendZFIN()
                complete()
            case Z.zfile:
                // Sender restarted the file: drop state and take the new info.
                closeReceiveHandle()
                discardData = false
                awaitingFileInfo = true
                machine = .receiverAwaitFile
            case Z.zrqinit:
                sendZRPOS(receiveOffset)
            default:
                break
            }
        }
    }

    private func handleSubpacket(_ data: Data, terminator: UInt8, crcValid: Bool) {
        let Z = ZmodemConstants.self

        if awaitingFileInfo {
            guard crcValid else {
                // Garbled ZFILE info: ask the sender to resend the file header.
                errorCount += 1
                if errorCount > maxErrorCount {
                    emit(ZmodemFraming.encodeCancel())
                    fail(.tooManyErrors)
                    return
                }
                sendHeader(type: ZmodemConstants.znak, position: 0, format: receiverBinaryFormat)
                return
            }
            awaitingFileInfo = false
            beginReceivingFile(ZmodemFraming.parseFileInfo(data))
            return
        }

        guard machine == .receiverReceiving else { return }

        guard crcValid else {
            // Bad data: force the sender back to the last good byte.
            discardData = true
            sendZRPOS(receiveOffset)
            errorCount += 1
            if errorCount > maxErrorCount {
                emit(ZmodemFraming.encodeCancel())
                fail(.tooManyErrors)
            }
            return
        }
        guard !discardData else { return }
        guard let handle = receiveHandle else { return }
        do {
            try handle.write(contentsOf: data)
            receiveOffset += UInt64(data.count)
            errorCount = 0   // real progress resets the retry budget
            if phase != .transferring { setPhase(.transferring) }
            onEvent?(.progress(ZmodemProgress(
                fileName: receiveName,
                fileIndex: receiveCompletedCount,
                fileCount: receiveCompletedCount + 1,
                fileBytesTransferred: receiveOffset,
                fileSize: receiveAnnouncedSize ?? 0
            )))
            if terminator == Z.zcrcq || terminator == Z.zcrcw {
                sendHeader(type: Z.zack, position: UInt32(truncatingIfNeeded: receiveOffset), format: .hex)
            }
        } catch {
            fail(.fileIO("write failed: \(error.localizedDescription)"))
        }
    }

    // MARK: - Sender flow

    private func noteCaps(_ h: ZmodemHeader) {
        peerCanCRC32 = (h.position & ZmodemConstants.canfc32) != 0
        peerEscctl = (h.position & ZmodemConstants.escctl) != 0
    }

    /// Binary headers we send: prefer 32-bit CRC once the peer advertised or
    /// demonstrated support; otherwise stay on the universally supported
    /// 16-bit format.
    private var senderBinaryFormat: ZmodemHeader.Format {
        (peerCanCRC32 || peerSentCRC32) ? .bin32 : .bin16
    }

    private var receiverBinaryFormat: ZmodemHeader.Format {
        peerSentCRC32 ? .bin32 : .bin16
    }

    private func startSendingCurrentFile() {
        guard sendIndex < sendQueue.count else {
            machine = .senderAwaitFin
            setPhase(.finishing)
            sendZFIN()
            return
        }
        let url = sendQueue[sendIndex]
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let sizeNumber = attrs[.size] as? NSNumber else {
                throw ZmodemError.fileIO("cannot stat \(url.lastPathComponent)")
            }
            let size = sizeNumber.uint64Value
            guard size <= UInt64(UInt32.max) else {
                throw ZmodemError.fileTooLarge(url.lastPathComponent)
            }
            let handle = try FileHandle(forReadingFrom: url)
            try? sendHandle?.close()
            sendHandle = handle
            sendFileSize = size
            sendFileName = url.lastPathComponent
            sendOffset = 0
            resumeCount = 0
            errorCount = 0
            // Mark the ZFILE as in flight BEFORE emitting it: on a synchronous
            // wire (loopback, or a PTY write that immediately echoes back a
            // response) the peer's ZRPOS can arrive re-entrantly from inside
            // the emit call, and it must land in senderAwaitFileResponse.
            machine = .senderAwaitFileResponse
            sendCurrentFileHeader()
            if phase == .idle { setPhase(.negotiating) }
        } catch let e as ZmodemError {
            fail(e)
        } catch {
            fail(.fileIO("cannot open \(url.lastPathComponent): \(error.localizedDescription)"))
        }
    }

    private func sendCurrentFileHeader() {
        let format = senderBinaryFormat
        sendHeader(type: ZmodemConstants.zfile, position: 0, format: format)

        var mtime: UInt64 = 0
        var mode: UInt32 = 0o100644
        if let attrs = try? FileManager.default.attributesOfItem(atPath: sendQueue[sendIndex].path) {
            if let date = attrs[.modificationDate] as? Date {
                mtime = UInt64(max(0, date.timeIntervalSince1970))
            }
            if let perm = attrs[.posixPermissions] as? NSNumber {
                mode = 0o100000 | perm.uint32Value
            }
        }
        let info = ZmodemFraming.encodeFileInfo(
            name: sendFileName,
            size: sendFileSize,
            modificationTime: mtime,
            mode: mode,
            filesRemaining: sendQueue.count - sendIndex
        )
        emit(ZmodemFraming.encodeDataSubpacket(
            info,
            terminator: ZmodemConstants.zcrcw,
            crc32: format == .bin32,
            escctl: peerEscctl
        ))
    }

    /// True while `sendDataFrom` is blasting chunks. A ZRPOS arriving
    /// re-entrantly (error recovery callback on our own send path) is deferred
    /// to the end of the current pump instead of recursing.
    private var pumping = false
    private var pendingRepump: UInt64?
    /// Per-file resume counter: a peer that keeps bouncing us with ZRPOS must
    /// not loop the transfer forever.
    private var resumeCount = 0
    private var pumpRemaining: UInt64 = 0
    private var pumpCRC32 = false
    private var pumpEmittedAny = false

    private func sendDataFrom(offset: UInt64) {
        if pumping {
            pendingRepump = offset
            return
        }
        resumeCount += 1
        if resumeCount > maxErrorCount * 2 {
            emit(ZmodemFraming.encodeCancel())
            fail(.tooManyErrors)
            return
        }
        guard let handle = sendHandle else {
            fail(.protocolError("ZRPOS before ZFILE"))
            return
        }
        do {
            try handle.seek(toOffset: offset)
        } catch {
            fail(.fileIO("seek failed: \(error.localizedDescription)"))
            return
        }
        sendOffset = offset
        // Mark data-in-flight BEFORE the pump starts: anything arriving
        // re-entrantly during the blast (error-recovery ZRPOS, an early
        // ZRINIT) is then handled by the awaitFileAck rules, and a deferred
        // repump supersedes the stale stream.
        machine = .senderAwaitFileAck
        pumpCRC32 = senderBinaryFormat == .bin32
        pumpRemaining = sendFileSize - offset
        pumpEmittedAny = false
        pumping = true
        sendHeader(type: ZmodemConstants.zdata, position: UInt32(offset), format: senderBinaryFormat)
        if phase != .transferring { setPhase(.transferring) }
        pump()
    }

    /// Emits data subpackets until the file is done or `shouldPauseSending`
    /// asks for a break. Safe to re-enter via `resumePump()`.
    private func pump() {
        guard let handle = sendHandle else { pumping = false; return }
        while pumpRemaining > 0 {
            guard isActive else { pumping = false; return }
            let want = Int(min(UInt64(chunkSize), pumpRemaining))
            let chunk: Data
            do {
                guard let read = try handle.read(upToCount: want), read.count == want else {
                    fail(.fileIO("short read on \(sendFileName)"))
                    pumping = false
                    return
                }
                chunk = read
            } catch {
                fail(.fileIO("read failed: \(error.localizedDescription)"))
                pumping = false
                return
            }
            let last = UInt64(chunk.count) == pumpRemaining
            emit(ZmodemFraming.encodeDataSubpacket(
                chunk,
                terminator: last ? ZmodemConstants.zcrce : ZmodemConstants.zcrcg,
                crc32: pumpCRC32,
                escctl: peerEscctl
            ))
            pumpEmittedAny = true
            sendOffset += UInt64(chunk.count)
            pumpRemaining -= UInt64(chunk.count)
            onEvent?(.progress(ZmodemProgress(
                fileName: sendFileName,
                fileIndex: sendIndex,
                fileCount: sendQueue.count,
                fileBytesTransferred: sendOffset,
                fileSize: sendFileSize
            )))
            if shouldPauseSending?() == true { return }
        }
        finishPump()
    }

    private func finishPump() {
        pumping = false
        guard isActive else { return }
        if let repump = pendingRepump {
            pendingRepump = nil
            sendDataFrom(offset: repump)
            return
        }
        if !pumpEmittedAny {
            // Empty file (or a fully-satisfied resume): still terminate the
            // ZDATA frame so the receiver returns to header scanning.
            emit(ZmodemFraming.encodeDataSubpacket(
                Data(),
                terminator: ZmodemConstants.zcrce,
                crc32: pumpCRC32,
                escctl: peerEscctl
            ))
        }
        sendEOF()
    }

    private func sendEOF() {
        sendHeader(type: ZmodemConstants.zeof, position: UInt32(sendFileSize), format: senderBinaryFormat)
    }

    private func sendFileCRC() {
        guard let handle = sendHandle else { return }
        do {
            let saved = try handle.offset()
            try handle.seek(toOffset: 0)
            var crc = ZmodemCRC32()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                crc.update(contentsOf: chunk)
            }
            try handle.seek(toOffset: saved)
            sendHeader(type: ZmodemConstants.zcrc, position: crc.value, format: senderBinaryFormat)
        } catch {
            fail(.fileIO("crc pass failed: \(error.localizedDescription)"))
        }
    }

    private func advanceToNextFile() {
        try? sendHandle?.close()
        sendHandle = nil
        onEvent?(.fileCompleted(name: sendFileName, localURL: sendQueue[sendIndex]))
        sendIndex += 1
        startSendingCurrentFile()
    }

    // MARK: - Receiver flow

    private func beginReceivingFile(_ info: ZmodemFraming.FileInfo) {
        guard let directory = receiveDirectory else { return }
        let fallback = "zmodem-download-\(Int(Date().timeIntervalSince1970))"
        let name = ZmodemFraming.sanitizeFileName(info.name) ?? fallback
        receiveName = name
        receiveAnnouncedSize = info.size

        let dest = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            var offset: UInt64 = 0
            if FileManager.default.fileExists(atPath: dest.path) {
                let attrs = try FileManager.default.attributesOfItem(atPath: dest.path)
                let existing = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
                if let announced = info.size, existing <= announced {
                    offset = existing   // resume (or no-op when already complete)
                } else {
                    offset = 0          // overwrite a longer/garbled local file
                }
            } else {
                guard FileManager.default.createFile(
                    atPath: dest.path, contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw ZmodemError.fileIO("cannot create \(name)")
                }
            }

            let handle = try FileHandle(forWritingTo: dest)
            try handle.truncate(atOffset: offset)
            try handle.seek(toOffset: offset)

            try? receiveHandle?.close()
            receiveHandle = handle
            receiveURL = dest
            receiveOffset = offset
            discardData = false
            errorCount = 0
            machine = .receiverReceiving
            if phase == .idle || phase == .negotiating { setPhase(.negotiating) }
            sendZRPOS(offset)
        } catch let e as ZmodemError {
            fail(e)
        } catch {
            fail(.fileIO("cannot open \(name): \(error.localizedDescription)"))
        }
    }

    private func finishReceivedFile() {
        if let handle = receiveHandle {
            try? handle.synchronize()
            try? handle.close()
        }
        receiveHandle = nil
        receiveCompletedCount += 1
        if let url = receiveURL {
            onEvent?(.fileCompleted(name: receiveName, localURL: url))
        }
        machine = .receiverAwaitFile
        sendZRINIT()
    }

    private func closeReceiveHandle() {
        try? receiveHandle?.close()
        receiveHandle = nil
    }

    // MARK: - Frame emitters

    private func sendHeader(type: UInt8, position: UInt32, format: ZmodemHeader.Format) {
        emit(ZmodemFraming.encodeHeader(
            type: type, position: position, format: format, escctl: peerEscctl
        ))
    }

    private func sendZRINIT() {
        sendHeader(type: ZmodemConstants.zrinit, position: ZmodemConstants.harborCaps, format: .hex)
        if phase == .idle { setPhase(.negotiating) }
        if machine == .idle { machine = .receiverAwaitFile }
    }

    private func sendZRPOS(_ offset: UInt64) {
        sendHeader(
            type: ZmodemConstants.zrpos,
            position: UInt32(truncatingIfNeeded: offset),
            format: receiverBinaryFormat
        )
    }

    private func sendZFIN() {
        sendHeader(type: ZmodemConstants.zfin, position: 0, format: .hex)
    }

    private func emit(_ data: Data) {
        onSend?(data)
    }

    // MARK: - Lifecycle

    /// Garbled frame: resend whatever the peer is most likely waiting for and
    /// count it against the retry budget.
    private func noteErrorAndResend() {
        errorCount += 1
        if errorCount > maxErrorCount {
            emit(ZmodemFraming.encodeCancel())
            fail(.tooManyErrors)
            return
        }
        switch machine {
        case .senderAwaitFileResponse: sendCurrentFileHeader()
        case .senderAwaitFileAck: sendEOF()
        case .senderAwaitFin: sendZFIN()
        case .receiverAwaitFile: sendZRINIT()
        case .receiverReceiving: sendZRPOS(receiveOffset)
        case .idle: break
        }
    }

    private func setPhase(_ new: ZmodemPhase) {
        guard phase != new else { return }
        phase = new
        onEvent?(.phaseChanged(new))
    }

    private func complete() {
        pumping = false
        pendingRepump = nil
        try? sendHandle?.close()
        sendHandle = nil
        closeReceiveHandle()
        setPhase(.completed)
    }

    private func fail(_ e: ZmodemError) {
        guard isActive else { return }
        error = e
        pumping = false
        pendingRepump = nil
        try? sendHandle?.close()
        sendHandle = nil
        closeReceiveHandle()
        setPhase(.failed)
    }

    private func terminate(_ phase: ZmodemPhase, error: ZmodemError) {
        guard isActive else { return }
        self.error = error
        pumping = false
        pendingRepump = nil
        try? sendHandle?.close()
        sendHandle = nil
        closeReceiveHandle()
        setPhase(phase)
    }
}
