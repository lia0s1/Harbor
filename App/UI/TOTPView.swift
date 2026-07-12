import SwiftUI
import AppKit
import HarborKit

// MARK: - Setup / edit sheet

/// Add or edit the TOTP secret for a host. Accepts a hand-typed Base32 key or a
/// pasted `otpauth://` QR-code payload (no camera needed on the Mac), and offers
/// a live "test" that shows the code the secret currently produces. The secret
/// is written to the Keychain via `TOTPStore` — never to a plain-text file.
struct TOTPSetupView: View {
    let hostID: UUID
    /// Display name of the host, for the explanatory copy.
    let hostName: String

    @Environment(\.dismiss) private var dismiss

    @State private var secretInput = ""
    @State private var testCode: String?
    @State private var testError: String?
    @State private var hasExisting = false

    /// The secret unwrapped from any pasted otpauth URL.
    private var normalizedSecret: String {
        TOTPGenerator.extractSecret(from: secretInput)
    }

    private var canSave: Bool {
        TOTPGenerator.isValidSecret(secretInput)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(L("两步验证（TOTP）"))
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.top, .horizontal], 20)
                .padding(.bottom, 8)

            Form {
                Section {
                    Text(L("为 %@ 配置基于时间的一次性验证码。密钥安全保存在系统钥匙串中。", hostName))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section(L("密钥")) {
                    TextField(
                        L("Base32 密钥"),
                        text: $secretInput,
                        prompt: Text(verbatim: "JBSWY3DPEHPK3PXP"),
                        axis: .vertical
                    )
                    .lineLimit(1...3)
                    .font(.system(.body, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: secretInput) { resetTest() }

                    Button {
                        pasteFromClipboard()
                    } label: {
                        Label(L("从剪贴板粘贴（二维码链接或密钥）"), systemImage: "doc.on.clipboard")
                    }
                    .buttonStyle(.link)

                    Text(L("在其他设备扫码时，可复制 otpauth:// 链接粘贴到此处，Harbor 会自动提取密钥。"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Section(L("测试")) {
                    Button(L("测试当前验证码")) { runTest() }
                        .disabled(secretInput.trimmingCharacters(in: .whitespaces).isEmpty)

                    if let testCode {
                        HStack {
                            Text(L("当前验证码"))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(verbatim: testCode)
                                .font(.system(.title3, design: .monospaced).weight(.semibold))
                                .textSelection(.enabled)
                        }
                    }
                    if let testError {
                        Text(testError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            footer
        }
        .frame(width: 460, height: 500)
        .onAppear {
            if let existing = TOTPStore.load(for: hostID) {
                secretInput = existing
                hasExisting = true
            }
        }
    }

    private var footer: some View {
        HStack {
            if hasExisting {
                Button(L("删除"), role: .destructive) {
                    TOTPStore.delete(for: hostID)
                    dismiss()
                }
                .buttonStyle(.glass)
            }
            Spacer()
            Button(L("取消"), role: .cancel) { dismiss() }
                .buttonStyle(.glass)
                .keyboardShortcut(.cancelAction)
            Button(L("保存")) { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(20)
    }

    private func pasteFromClipboard() {
        guard let pasted = NSPasteboard.general.string(forType: .string) else { return }
        secretInput = TOTPGenerator.extractSecret(from: pasted)
        resetTest()
    }

    private func runTest() {
        guard let code = TOTPGenerator.code(base32Secret: normalizedSecret) else {
            testCode = nil
            testError = L("密钥无效，无法生成验证码。")
            return
        }
        testError = nil
        testCode = TOTPStatusView.grouped(code)
    }

    private func resetTest() {
        testCode = nil
        testError = nil
    }

    private func save() {
        guard canSave else { return }
        TOTPStore.save(secret: normalizedSecret, for: hostID)
        dismiss()
    }
}

// MARK: - Inline status widget

/// Compact inline widget: the current 6-digit code, a 30-second countdown ring,
/// a copy button and a "send to terminal" action. The secret is loaded from the
/// Keychain on appear and released on disappear; only the derived code is shown.
struct TOTPStatusView: View {
    let hostID: UUID
    /// Called with the current code when the user taps 发送到终端. The caller
    /// decides whether to append a newline (`sendText(code + "\n")`).
    var onSend: ((String) -> Void)?

    @State private var secret: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .onAppear { secret = TOTPStore.load(for: hostID) }
        .onDisappear { secret = nil }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        if let secret, let code = TOTPGenerator.code(base32Secret: secret, at: now) {
            HStack(spacing: DS.Space.m) {
                CountdownRing(
                    elapsed: TOTPGenerator.elapsedFraction(at: now),
                    remaining: TOTPGenerator.secondsRemaining(at: now)
                )

                Text(verbatim: TOTPStatusView.grouped(code))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .contentTransition(.numericText())

                Spacer(minLength: DS.Space.s)

                Button {
                    copy(code)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help(L("复制验证码"))

                if let onSend {
                    Button(L("发送到终端")) { onSend(code) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .padding(DS.Space.m)
            .statCard()
        } else {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "shield.slash")
                    .foregroundStyle(.secondary)
                Text(L("未配置两步验证"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .statCard()
        }
    }

    private func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
    }

    /// "123456" → "123 456" for readability. Non-6-digit codes are left as-is.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let mid = code.index(code.startIndex, offsetBy: 3)
        return "\(code[..<mid]) \(code[mid...])"
    }
}

/// 30-second countdown ring with the whole-seconds-remaining count in the
/// center. Steps once per second (no cross-rollover animation, which would
/// otherwise sweep backwards when the period resets).
private struct CountdownRing: View {
    /// Fraction of the period elapsed, 0...1.
    let elapsed: Double
    /// Whole seconds remaining.
    let remaining: Int
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            Circle()
                .stroke(DS.Colors.barTrack, lineWidth: 3)
            Circle()
                .trim(from: 0, to: max(0.02, 1 - elapsed))
                .stroke(ringColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(remaining)")
                .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .frame(width: size, height: size)
    }

    private var ringColor: Color {
        remaining <= 5 ? DS.Colors.statusError : Color.accentColor
    }
}

// MARK: - Auto-fill banner

/// Slim notification bar shown when a 2FA prompt is detected in the terminal.
/// Meant to sit inline (e.g. above the terminal), not as a covering overlay.
/// Auto-dismisses after `autoDismiss` seconds.
struct TOTPAutoFillBanner: View {
    /// The current code to offer.
    let code: String
    /// Send the code to the terminal.
    var onSend: () -> Void
    /// Dismiss the banner (also called on auto-dismiss).
    var onDismiss: () -> Void
    var autoDismiss: TimeInterval = 10

    var body: some View {
        HStack(spacing: DS.Space.m) {
            Image(systemName: "shield.lefthalf.filled")
                .foregroundStyle(.orange)
                .font(.title3)

            VStack(alignment: .leading, spacing: 1) {
                Text(L("检测到验证码请求，点击发送"))
                    .font(.callout.weight(.medium))
                Text(verbatim: TOTPStatusView.grouped(code))
                    .font(.system(.title3, design: .monospaced).weight(.semibold))
            }

            Spacer(minLength: DS.Space.s)

            Button(L("发送")) { onSend() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(L("关闭"))
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.medium, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .task {
            try? await Task.sleep(nanoseconds: UInt64(autoDismiss * 1_000_000_000))
            onDismiss()
        }
    }
}
