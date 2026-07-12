import SwiftUI
import HarborKit

// MARK: - Remote file entry icon

/// File-type icon view for a single remote file entry in the table.
struct RemoteFileEntryIcon: View {
    let entry: RemoteFileEntry

    var body: some View {
        Image(systemName: Self.iconName(for: entry))
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Self.iconColor(for: entry))
            .frame(width: 16)
    }

    /// File-type icon picked by extension.
    static func iconName(for entry: RemoteFileEntry) -> String {
        if entry.isSymlink { return "arrowshape.turn.up.right.fill" }
        if entry.isDirectory { return "folder.fill" }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "sh", "bash", "zsh", "py", "js", "ts", "rb", "pl", "go", "rs", "c", "cpp", "java", "php":
            return "chevron.left.forwardslash.chevron.right"
        case "zip", "gz", "tar", "tgz", "xz", "bz2", "7z", "rar", "zst":
            return "doc.zipper"
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "ico":
            return "photo"
        case "mp4", "mkv", "mov", "avi", "webm", "flv":
            return "film"
        case "mp3", "wav", "flac", "ogg", "m4a":
            return "music.note"
        case "txt", "md", "log", "csv", "rtf":
            return "doc.text"
        case "json", "yaml", "yml", "toml", "conf", "cfg", "ini", "xml", "env":
            return "gearshape.fill"
        case "pdf":
            return "doc.richtext"
        default:
            return "doc.fill"
        }
    }

    static func iconColor(for entry: RemoteFileEntry) -> Color {
        if entry.isSymlink { return Color(nsColor: .systemTeal) }
        if entry.isDirectory { return Color(nsColor: .systemBlue) }
        switch (entry.name as NSString).pathExtension.lowercased() {
        case "sh", "bash", "zsh", "py", "js", "ts", "rb", "pl", "go", "rs", "c", "cpp", "java", "php":
            return Color(nsColor: .systemGreen)
        case "zip", "gz", "tar", "tgz", "xz", "bz2", "7z", "rar", "zst":
            return Color(nsColor: .systemOrange)
        case "png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "heic", "ico":
            return Color(nsColor: .systemPurple)
        case "mp4", "mkv", "mov", "avi", "webm", "flv":
            return Color(nsColor: .systemPink)
        case "mp3", "wav", "flac", "ogg", "m4a":
            return Color(nsColor: .systemIndigo)
        case "json", "yaml", "yml", "toml", "conf", "cfg", "ini", "xml", "env":
            return Color(nsColor: .systemGray)
        default:
            return Color(nsColor: .secondaryLabelColor)
        }
    }
}
