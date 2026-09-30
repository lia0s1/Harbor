import Foundation

/// Watches a stream of terminal output for two-factor / OTP prompts and fires a
/// callback so the UI can offer to auto-fill the current TOTP code.
///
/// Feed it raw output slices (from `HarborTerminalView.dataInterceptor`). It
/// keeps a small rolling text window so a prompt split across two reads is still
/// matched, and debounces so a single prompt does not fire repeatedly while the
/// server redraws the line.
final class TOTPPromptDetector: @unchecked Sendable {
    /// Fired on the main queue when a 2FA prompt is newly detected.
    var onPromptDetected: (@MainActor @Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _onPromptDetected
        }
        set {
            lock.lock()
            _onPromptDetected = newValue
            lock.unlock()
        }
    }
    private var _onPromptDetected: (@MainActor @Sendable () -> Void)?

    /// Case-insensitive phrases, kept lowercase and matched against a
    /// lowercased window. These are long enough that a raw `contains` is safe.
    private static let phrases: [String] = [
        "verification code",
        "authentication code",
        "one-time password",
        "one time password",
        "authenticator",
        "6-digit code",
        "验证码",
        "两步验证",
        "动态口令"
    ]

    /// Short tokens only match at a non-alphanumeric boundary so `hotpath`
    /// / `totpauth` / `otpauth` do not light the banner.
    private static let boundedTokens: [String] = [
        "2fa",
        "otp",
        "totp"
    ]

    private static let alphanumerics = CharacterSet.alphanumerics

    /// Rolling lowercased window (bounded) carried across feeds so a prompt that
    /// straddles two chunks still matches.
    private var window = ""
    private let maxWindow = 512

    /// Suppress re-detections within this interval after a fire.
    private let debounceInterval: TimeInterval
    private var lastFired: Date?
    /// Guards `window` / `lastFired`: feeds arrive on SwiftTerm's output thread.
    private let lock = NSLock()

    init(debounceInterval: TimeInterval = 8) {
        self.debounceInterval = debounceInterval
    }

    /// Feeds a chunk of raw terminal output. Safe to call off the main thread.
    func feed(_ slice: ArraySlice<UInt8>) {
        guard !slice.isEmpty else { return }
        // Only the tail can complete a (short) prompt, so cap decoding to bound
        // allocations during bulk output. A cut multibyte char at the front
        // becomes a replacement char, harmless for the words we match on.
        let tail = slice.count > maxWindow ? slice.suffix(maxWindow) : slice
        let text = String(decoding: tail, as: UTF8.self).lowercased()

        var callback: (@MainActor @Sendable () -> Void)?
        lock.lock()
        window += text
        if window.count > maxWindow {
            window = String(window.suffix(maxWindow))
        }
        if TOTPPromptDetector.matches(window) {
            let now = Date()
            if lastFired.map({ now.timeIntervalSince($0) >= debounceInterval }) ?? true {
                lastFired = now
                callback = _onPromptDetected
                // Clear so the same buffered prompt text can't immediately re-match.
                window = ""
            }
        }
        lock.unlock()

        if let callback {
            Task { @MainActor in callback() }
        }
    }

    /// Clears the buffer and debounce state (e.g. on reconnect).
    func reset() {
        lock.lock()
        window = ""
        lastFired = nil
        lock.unlock()
    }

    private static func matches(_ window: String) -> Bool {
        if phrases.contains(where: { window.contains($0) }) {
            return true
        }
        return boundedTokens.contains(where: { containsBoundedToken(window, token: $0) })
    }

    /// True when `token` appears in `window` with a non-alphanumeric (or
    /// start/end-of-string) boundary on both sides.
    private static func containsBoundedToken(_ window: String, token: String) -> Bool {
        var searchFrom = window.startIndex
        while searchFrom < window.endIndex,
              let range = window.range(of: token, range: searchFrom..<window.endIndex) {
            let beforeOK: Bool
            if range.lowerBound == window.startIndex {
                beforeOK = true
            } else {
                let previous = window[window.index(before: range.lowerBound)]
                beforeOK = previous.unicodeScalars.allSatisfy { !alphanumerics.contains($0) }
            }
            let afterOK: Bool
            if range.upperBound == window.endIndex {
                afterOK = true
            } else {
                let next = window[range.upperBound]
                afterOK = next.unicodeScalars.allSatisfy { !alphanumerics.contains($0) }
            }
            if beforeOK && afterOK { return true }
            searchFrom = range.upperBound
        }
        return false
    }
}
