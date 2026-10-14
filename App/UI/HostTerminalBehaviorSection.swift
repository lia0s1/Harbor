import SwiftUI
import HarborKit

/// Display labels for the backspace wire behaviors, shared by the global
/// default picker (Settings → 终端) and the per-host override section.
extension SSHHost.BackspaceBehavior {
    /// Short label for picker rows. `auto` reads as "terminal default" in the
    /// global picker and as "follow the global default" per host — callers
    /// present that slot with their own surrounding context.
    @MainActor var wireLabel: String {
        switch self {
        case .auto: return L("终端默认")
        case .asciiBackspace: return "ASCII Backspace (^H, 0x08)"
        case .asciiDelete: return "ASCII Delete (^?, 0x7F)"
        case .vt220Delete: return "VT220 Delete (ESC [3~)"
        }
    }
}

/// Per-host terminal behavior section for the host editor (退格键映射,
/// FinalShell-style backspace_key_sequence). Standalone on purpose: the host
/// editor lives in another file — drop `HostTerminalBehaviorSection(host: …)`
/// into its Form and the binding does the rest.
///
/// Two bindings are accepted: the whole `SSHHost` (writes
/// `host.backspaceBehavior`) or the bare `SSHHost.BackspaceBehavior`
/// (for editors that build the host from scalar draft fields).
struct HostTerminalBehaviorSection: View {
    @Binding private var behavior: SSHHost.BackspaceBehavior

    init(host: Binding<SSHHost>) {
        _behavior = host.backspaceBehavior
    }

    init(behavior: Binding<SSHHost.BackspaceBehavior>) {
        _behavior = behavior
    }

    private var globalDefault: SSHHost.BackspaceBehavior {
        let raw = UserDefaults.standard.string(forKey: BackspacePreference.globalDefaultKey)
        return SSHHost.BackspaceBehavior(rawValue: raw ?? "") ?? .auto
    }

    var body: some View {
        Section(L("终端行为")) {
            Picker(L("退格键发送"), selection: $behavior) {
                Text(L("跟随全局默认（%@）", globalDefault.wireLabel))
                    .tag(SSHHost.BackspaceBehavior.auto)
                ForEach(SSHHost.BackspaceBehavior.allCases.filter { $0 != .auto }, id: \.self) { option in
                    Text(verbatim: option.wireLabel).tag(option)
                }
            }
            Text(L("远端退格行为异常（删不掉字符、显示 ^H 或 ^?）时在这里修正；重连后生效。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
