import SwiftUI
import HarborKit

/// Detail-pane placeholder shown when no terminal sessions are open.
///
/// Two flavors: a first-run welcome with add/import calls to action when the
/// host list is empty, otherwise quick connect plus recently used hosts.
struct EmptyStateView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager

    var body: some View {
        ZStack {
            DS.Colors.panelBackground.ignoresSafeArea()
            VStack(spacing: DS.Space.l) {
                glyph
                if hostStore.hosts.isEmpty {
                    welcome
                } else {
                    noSession
                }
            }
            .frame(maxWidth: 340)
            .padding(DS.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var glyph: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 96, height: 96)
            Image(systemName: "sailboat.fill")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(Color.accentColor.gradient)
        }
    }

    // MARK: - First run: no hosts yet

    private var welcome: some View {
        VStack(spacing: DS.Space.m) {
            Text(verbatim: L("欢迎使用 Harbor"))
                .font(.title2.weight(.semibold))
            Text(verbatim: L("保存常用的 SSH 主机，在标签页中打开会话。"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            QuickConnectField(placement: .emptyState)
                .frame(maxWidth: 300)
                .padding(.top, DS.Space.xs)

            GlassEffectContainer(spacing: DS.Space.s + 2) {
                HStack(spacing: DS.Space.s + 2) {
                    Button {
                        NotificationCenter.default.post(name: .harborNewHost, object: nil)
                    } label: {
                        Label(L("添加主机"), systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .help(L("添加主机 (⌘N)"))

                    Button {
                        NotificationCenter.default.post(name: .harborImportConfig, object: nil)
                    } label: {
                        Label(L("从 ~/.ssh/config 导入"), systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.glass)
                }
            }
            .padding(.top, DS.Space.xs)
        }
    }

    // MARK: - Hosts exist, nothing open

    private var noSession: some View {
        VStack(spacing: DS.Space.m) {
            Text(verbatim: L("没有打开的会话"))
                .font(.title2.weight(.semibold))
            Text(verbatim: L("双击侧栏中的主机，或直接快速连接："))
                .font(.callout)
                .foregroundStyle(.secondary)

            QuickConnectField(placement: .emptyState)
                .frame(maxWidth: 300)

            if !recentHosts.isEmpty {
                recentsSection
                    .padding(.top, DS.Space.m)
            }
        }
    }

    private var recentsSection: some View {
        GlassEffectContainer(spacing: 6) {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: L("最近连接"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                ForEach(recentHosts) { host in
                    Button {
                        sessionManager.openSession(host: host)
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            HostAvatarView(name: host.displayName, size: 22)
                            Text(host.displayName)
                                .lineLimit(1)
                            Spacer(minLength: DS.Space.m)
                            Text(connectionSummary(for: host))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, DS.Space.s + 2)
                    .padding(.vertical, 6)
                    .glassCard()
                    .help(L("连接到 %@", host.displayName))
                }
            }
        }
        .frame(maxWidth: 300)
    }

    /// Recently connected hosts that still exist in the store (ad-hoc
    /// quick-connect targets and deleted hosts drop out naturally).
    private var recentHosts: [SSHHost] {
        sessionManager.recentHostIDs.compactMap { hostStore.host(withID: $0) }
    }

    private func connectionSummary(for host: SSHHost) -> String {
        var text = host.username.isEmpty ? host.hostname : "\(host.username)@\(host.hostname)"
        if host.port != SSHHost.defaultPort {
            text += ":\(host.port)"
        }
        return text
    }
}
