import Foundation

/// Wire-byte mapping for `SSHHost.BackspaceBehavior` (FinalShell-style
/// per-host backspace key sequence), plus the global-default resolution.
///
/// Pure data, no AppKit/SwiftTerm: the terminal layer reads `wireBytes` and
/// decides when to intercept the key.
extension SSHHost.BackspaceBehavior {

    /// Bytes the Backspace key should put on the wire for this behavior.
    ///
    /// `nil` for `.auto`: leave the terminal emulator's own default untouched
    /// (SwiftTerm sends DEL 0x7f, or honors kitty keyboard enhancement when the
    /// remote app requested it).
    public var wireBytes: [UInt8]? {
        switch self {
        case .auto:
            return nil
        case .asciiBackspace:
            return [0x08]                 // BS  (^H)
        case .asciiDelete:
            return [0x7F]                 // DEL (^?)
        case .vt220Delete:
            return [0x1B, 0x5B, 0x33, 0x7E] // ESC [ 3 ~
        }
    }

    /// Effective behavior for a session: a per-host choice other than `.auto`
    /// always wins; otherwise the global default from Settings applies. An
    /// unknown/empty global raw value falls back to `.auto`.
    public static func resolve(
        perHost: SSHHost.BackspaceBehavior,
        globalRawValue: String?
    ) -> SSHHost.BackspaceBehavior {
        guard perHost == .auto else { return perHost }
        guard let globalRawValue,
              let global = SSHHost.BackspaceBehavior(rawValue: globalRawValue)
        else { return .auto }
        return global
    }
}
