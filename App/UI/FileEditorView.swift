import SwiftUI
import HarborKit

/// In-app text editor for a remote file: downloads the file's text, lets the
/// user edit it in a monospace editor, and writes it back over sftp on ⌘S /
/// 保存 — all inside Harbor, no external app.
struct FileEditorView: View {
    let entry: RemoteFileEntry
    @ObservedObject var service: FileService
    @Environment(\.dismiss) private var dismiss

    @State private var content = ""
    @State private var original = ""
    @State private var remoteVersion: RemoteFileVersion?
    @State private var phase: Phase = .loading
    @State private var saving = false
    @State private var saveError: String?
    @State private var savedFlash = false
    @State private var hasLoaded = false
    @State private var discardPresented = false

    private enum Phase: Equatable { case loading, ready, failed(String) }

    private var dirty: Bool { content != original }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: phase)
        }
        .frame(minWidth: 560, idealWidth: 760, minHeight: 420, idealHeight: 620)
        .onAppear {
            guard !hasLoaded else { return }
            load()
        }
        .interactiveDismissDisabled(dirty)
        .confirmationDialog(L("有未保存的更改"), isPresented: $discardPresented, titleVisibility: .visible) {
            Button(L("保存"), action: save)
            Button(L("放弃更改"), role: .destructive) { dismiss() }
            Button(L("取消"), role: .cancel) {}
        } message: {
            Text(verbatim: L("关闭前是否保存对 \"%@\" 的更改？", entry.name))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(entry.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if dirty {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                            .help(L("有未保存的更改"))
                    }
                }
                Text(service.absolutePath(of: entry))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: DS.Space.s)
            if let saveError {
                Text(saveError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if savedFlash {
                Label(L("已保存"), systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            } else if saving {
                ProgressView().controlSize(.small)
            }
            Button(L("保存")) { save() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(phase != .ready || saving || !dirty)
            Button(L("完成")) {
                if dirty { discardPresented = true } else { dismiss() }
            }
        }
        .padding(DS.Space.m)
    }

    @ViewBuilder
    private func body(for phase: Phase) -> some View {
        switch phase {
        case .loading:
            notice { ProgressView().controlSize(.small); Text(L("正在打开…")).foregroundStyle(.secondary) }
        case .failed(let reason):
            notice {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(.tertiary)
                Text(reason).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button(L("重试"), action: load).buttonStyle(.bordered).controlSize(.small)
            }
        case .ready:
            TextEditor(text: $content)
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .background(DS.Colors.fieldBackground)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func notice<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: DS.Space.s) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(DS.Space.l)
    }

    // MARK: Load / save

    private func load() {
        hasLoaded = true
        phase = .loading
        saveError = nil
        Task {
            switch await service.loadText(entry) {
            case .success(let loaded):
                content = loaded.text
                original = loaded.text
                remoteVersion = loaded.version
                phase = .ready
            case .failure(let error):
                phase = .failed(error.message)
            }
        }
    }

    private func save() {
        guard dirty, !saving, let remoteVersion else { return }
        saving = true
        saveError = nil
        let snapshot = content
        Task {
            switch await service.saveText(
                entry,
                content: snapshot,
                expectedVersion: remoteVersion
            ) {
            case .success(let savedVersion):
                saving = false
                original = snapshot
                self.remoteVersion = savedVersion
                withAnimation { savedFlash = true }
                try? await Task.sleep(nanoseconds: 1_600_000_000)
                withAnimation { savedFlash = false }
            case .failure(let error):
                saving = false
                saveError = error.message
            }
        }
    }
}
