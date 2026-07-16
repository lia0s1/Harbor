import Foundation
import CommonCrypto

/// RFC 6238 (TOTP) / RFC 4226 (HOTP) one-time-password generator.
///
/// Pure Swift + CommonCrypto (HMAC-SHA1) — no external dependencies. Defaults
/// match essentially every authenticator setup in the wild (Google
/// Authenticator, GitHub, etc.): 6 digits, 30-second period, SHA-1.
enum TOTPGenerator {
    /// Standard code length.
    static let digits = 6
    /// Standard step, in seconds.
    static let period: TimeInterval = 30

    // MARK: - Base32

    /// Decodes an RFC 4648 Base32 secret (the `otpauth://` encoding), tolerating
    /// lowercase, spaces, dashes and missing `=` padding. Returns nil for any
    /// character outside the Base32 alphabet, or for empty input.
    static func base32Decode(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var lookup = [Character: UInt8](minimumCapacity: 32)
        for (index, character) in alphabet.enumerated() {
            lookup[character] = UInt8(index)
        }

        let cleaned = input.uppercased().filter { $0 != " " && $0 != "=" && $0 != "-" }
        guard !cleaned.isEmpty else { return nil }

        var accumulator = 0
        var bits = 0
        var output = Data()
        output.reserveCapacity(cleaned.count * 5 / 8 + 1)
        for character in cleaned {
            guard let value = lookup[character] else { return nil }
            accumulator = (accumulator << 5) | Int(value)
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((accumulator >> bits) & 0xFF))
            }
        }
        return output.isEmpty ? nil : output
    }

    // MARK: - HOTP / TOTP

    /// The HOTP value for a specific counter (RFC 4226 §5).
    static func hotp(secret: Data, counter: UInt64, digits: Int = digits) -> String {
        precondition((1...9).contains(digits), "TOTPGenerator: digits must be between 1 and 9, got \(digits)")
        var counterBE = counter.bigEndian
        let message = Data(bytes: &counterBE, count: MemoryLayout<UInt64>.size)

        var mac = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        secret.withUnsafeBytes { keyBytes in
            message.withUnsafeBytes { messageBytes in
                CCHmac(
                    CCHmacAlgorithm(kCCHmacAlgSHA1),
                    keyBytes.baseAddress, secret.count,
                    messageBytes.baseAddress, message.count,
                    &mac
                )
            }
        }

        // Dynamic truncation (RFC 4226 §5.3): the low nibble of the last byte
        // selects a 4-byte window, whose top bit is masked off.
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let binary =
            (UInt32(mac[offset]     & 0x7F) << 24) |
            (UInt32(mac[offset + 1] & 0xFF) << 16) |
            (UInt32(mac[offset + 2] & 0xFF) <<  8) |
             UInt32(mac[offset + 3] & 0xFF)

        // Manual zero-padding avoids the CVarArg pitfalls of String(format:).
        let value = String(binary % pow10(digits))
        let padding = max(0, digits - value.count)
        return String(repeating: "0", count: padding) + value
    }

    /// The current TOTP code for a Base32 secret. Returns nil if the secret
    /// can't be decoded.
    static func code(
        base32Secret: String,
        at date: Date = Date(),
        digits: Int = digits,
        period: TimeInterval = period
    ) -> String? {
        guard let secret = base32Decode(base32Secret) else { return nil }
        let counter = UInt64(date.timeIntervalSince1970 / period)
        return hotp(secret: secret, counter: counter, digits: digits)
    }

    // MARK: - Timing

    /// Whole seconds remaining in the current period (1...period).
    static func secondsRemaining(at date: Date = Date(), period: TimeInterval = period) -> Int {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return max(1, Int((period - elapsed).rounded(.up)))
    }

    /// Fraction of the current period already elapsed (0...1), for a countdown ring.
    static func elapsedFraction(at date: Date = Date(), period: TimeInterval = period) -> Double {
        let elapsed = date.timeIntervalSince1970.truncatingRemainder(dividingBy: period)
        return elapsed / period
    }

    // MARK: - Input helpers

    /// Extracts the Base32 secret from an `otpauth://totp/...?secret=...` URL, or
    /// returns the trimmed input unchanged when it is already a bare secret. Lets
    /// the setup UI accept either a pasted QR-code payload or a hand-typed key.
    static func extractSecret(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: trimmed),
              let secret = components.queryItems?
                .first(where: { $0.name.lowercased() == "secret" })?.value,
              !secret.isEmpty
        else { return trimmed }
        return secret
    }

    /// True when a (possibly otpauth-wrapped) string yields usable key material.
    static func isValidSecret(_ secret: String) -> Bool {
        base32Decode(extractSecret(from: secret)) != nil
    }

    // MARK: - Private

    /// 10^exponent as UInt32. `digits` is small (≤9), so this stays in range.
    private static func pow10(_ exponent: Int) -> UInt32 {
        var result: UInt32 = 1
        for _ in 0..<exponent { result *= 10 }
        return result
    }
}
