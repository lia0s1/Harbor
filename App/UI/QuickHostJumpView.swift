import SwiftUI
import HarborKit

/// Spotlight-style overlay for quickly connecting to any saved host (⌘P).
/// Shown as a floating card centered in the window with a dimmed background.
/// Dismiss by pressing Escape, clicking outside, or successfully connecting.
struct QuickHostJumpView: View {
    @EnvironmentObject private var hostStore: HostStore
    @EnvironmentObject private var sessionManager: SessionManager
    @Binding var isPresented: Bool
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var suppressHover = false
    @FocusState private var fieldFocused: Bool

    private var filtered: [SSHHost] {
        guard !query.isEmpty else { return hostStore.hosts }
        let q = query.lowercased()
        return hostStore.hosts.filter {
            $0.displayName.lowercased().contains(q)
            || $0.hostname.lowercased().contains(q)
            || $0.username.lowercased().contains(q)
            || $0.tags.joined(separator: " ").lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            // Dimmed backdrop — tap anywhere outside to dismiss.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Search field
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("跳转到主机…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit { connect() }
                        .onChange(of: query) { _, _ in selectedIndex = 0 }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

                Divider()

                if filtered.isEmpty {
                    Text("没有匹配的主机")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                        .padding(20)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, host in
                                    QuickJumpRow(host: host, isSelected: idx == selectedIndex)
                                        .id(idx)
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            selectedIndex = idx
                                            connect()
                                        }
                                        .onHover { hovering in
                                            if hovering && !suppressHover { selectedIndex = idx }
                                        }
                                }
                            }
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: selectedIndex) { _, idx in
                            withAnimation(.none) { proxy.scrollTo(idx, anchor: .center) }
                        }
                    }
                }
            }
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator, lineWidth: 0.5))
            .shadow(radius: 24)
            .frame(width: 520)
            .padding(.top, -80) // bias toward the upper half
            .onKeyPress(.upArrow) {
                selectedIndex = max(0, selectedIndex - 1)
                suppressHover = true
                Task { try? await Task.sleep(nanoseconds: 300_000_000); suppressHover = false }
                return .handled
            }
            .onKeyPress(.downArrow) {
                selectedIndex = min(filtered.count - 1, selectedIndex + 1)
                suppressHover = true
                Task { try? await Task.sleep(nanoseconds: 300_000_000); suppressHover = false }
                return .handled
            }
            .onKeyPress(.escape) { dismiss(); return .handled }
        }
        .onAppear { fieldFocused = true }
    }

    private func connect() {
        guard selectedIndex < filtered.count else { dismiss(); return }
        let host = filtered[selectedIndex]
        sessionManager.openSession(host: host)
        dismiss()
    }

    private func dismiss() {
        query = ""
        selectedIndex = 0
        isPresented = false
    }
}

private struct QuickJumpRow: View {
    let host: SSHHost
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.connectionProtocol == .rdp ? "desktopcomputer" : "server.rack")
                .font(.system(size: 15))
                .foregroundStyle(isSelected ? .white : .accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(isSelected ? .white : .primary)
                Text("\(host.username.isEmpty ? "" : host.username + "@")\(host.hostname):\(host.port)")
                    .font(.caption)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.75) : .secondary)
            }
            Spacer()
            if !host.tags.isEmpty {
                Text(host.tags.prefix(2).joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.65) : Color.secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
    }
}
