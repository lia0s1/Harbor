//
//  ZmodemDetector.swift
//  HarborKit
//
//  Watches the raw PTY output stream for a ZRQINIT hex header — the signal
//  that someone on the remote side ran `rz` (wants files from us) or `sz`
//  (wants to send us files).
//
//  Direction heuristic: lrzsz `sz` emits the literal bytes "rz\r" (its rz
//  auto-invocation string) IMMEDIATELY before the ZRQINIT frame; `rz` does
//  not. The shell's own echo of a typed `rz<Return>` is "rz\r\n", so requiring
//  the frame to directly follow "rz\r" — with no LF in between — separates a
//  real sz invocation from command echo. Blind spot: `sz -q` suppresses the
//  invocation string and looks identical to `rz`; the integrator should offer
//  a manual "receive instead" escape hatch for that case.
//

import Foundation

public enum ZmodemTrigger: String, Equatable, Sendable {
    /// Remote ran `rz` — it expects us to SEND files (upload).
    case upload
    /// Remote ran `sz` — it expects us to RECEIVE files (download).
    case download
}

public final class ZmodemDetector: @unchecked Sendable {
    // @unchecked: fed exclusively from SwiftTerm's serial I/O context (one
    // byte stream, in order). No internal locking by design — callers must
    // keep that serial discipline, same as the TOTP detector beside it.

    /// Safety cap for the captured frame; a well-formed ZRQINIT hex line is
    /// ~21 bytes.
    private static let maxCapture = 64

    private enum State: Equatable {
        case idle
        case star1
        case star2
        case zdle
        case hexLead
        case typeFirstZero
        case capture
    }

    private var state: State = .idle
    /// Rolling window of the last 3 bytes seen outside a candidate match.
    private var history: [UInt8] = []
    /// Snapshot of `history` at the moment the current candidate started.
    private var prefix: [UInt8] = []
    private var frame = Data()
    private var fired = false

    public init() {}

    public func reset() {
        state = .idle
        history = []
        prefix = []
        frame = Data()
        fired = false
    }

    /// Feed one output chunk. Returns nil until a complete ZRQINIT frame has
    /// been seen, then returns the trigger direction and the captured frame
    /// bytes (ZPAD through LF), ready to replay into `ZmodemSession.input(_:)`.
    /// Fires at most once; create a fresh detector after a transfer.
    public func feed(_ bytes: ArraySlice<UInt8>) -> (trigger: ZmodemTrigger, frame: Data)? {
        if fired { return nil }
        let pad = ZmodemConstants.pad
        var i = bytes.startIndex
        while i < bytes.endIndex {
            if state == .idle {
                // Bulk path: a candidate frame always starts with ZPAD ('*'),
                // so while idle skip straight to the next one instead of
                // running the per-byte machine (and its per-byte history
                // append/trim) over the whole chunk. The history window only
                // ever needs the 3 bytes immediately preceding a candidate,
                // so a skipped run contributes just its suffix(3). This keeps
                // bulk output (cat, build logs) cheap even when the chunk
                // happens to contain a stray '*'.
                guard let next = bytes[i...].firstIndex(of: pad) else {
                    history.append(contentsOf: bytes[i...].suffix(3))
                    if history.count > 3 { history.removeFirst(history.count - 3) }
                    return nil
                }
                history.append(contentsOf: bytes[i..<next].suffix(3))
                if history.count > 3 { history.removeFirst(history.count - 3) }
                i = next
            }
            if let result = step(bytes[i]) {
                fired = true
                return result
            }
            i = bytes.index(after: i)
        }
        return nil
    }

    public func feed(_ data: Data) -> (trigger: ZmodemTrigger, frame: Data)? {
        feed(ArraySlice(data))
    }

    private func step(_ b: UInt8) -> (ZmodemTrigger, Data)? {
        let Z = ZmodemConstants.self
        switch state {
        case .idle:
            if b == Z.pad {
                prefix = history
                frame = Data([b])
                state = .star1
            }

        case .star1:
            if b == Z.pad {
                frame.append(b)
                state = .star2
            } else {
                state = .idle
            }

        case .star2:
            if b == Z.zdle {
                frame.append(b)
                state = .zdle
            } else if b == Z.pad {
                frame.append(b) // tolerate extra pads
            } else {
                state = .idle
            }

        case .zdle:
            if b == Z.hex {
                frame.append(b)
                state = .hexLead
            } else {
                state = .idle
            }

        case .hexLead:
            // First hex digit of the frame type: ZRQINIT is "00".
            if b == UInt8(ascii: "0") {
                frame.append(b)
                state = .typeFirstZero
            } else {
                state = .idle
            }

        case .typeFirstZero:
            if b == UInt8(ascii: "0") {
                frame.append(b)
                state = .capture
            } else {
                state = .idle
            }

        case .capture:
            frame.append(b)
            if b == Z.lf || frame.count >= ZmodemDetector.maxCapture {
                state = .idle
                let looksLikeSz = prefix == [UInt8(ascii: "r"), UInt8(ascii: "z"), Z.cr]
                return (looksLikeSz ? .download : .upload, frame)
            }
        }
        return nil
    }
}
