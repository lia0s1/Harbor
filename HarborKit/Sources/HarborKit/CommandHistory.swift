import Foundation

/// FinalShell-style command-input history: entries are stored oldest-first
/// (newest last), capped at `limit` by dropping the oldest, with consecutive
/// duplicates collapsed. Pure data — persistence belongs to the app layer.
public struct CommandHistory: Equatable, Sendable {
    /// FinalShell advertises "unlimited" history; we keep a large, sane cap so
    /// UserDefaults can't grow without bound.
    public static let defaultLimit = 2000

    /// Oldest first, newest last.
    public private(set) var entries: [String]
    public let limit: Int

    public init(entries: [String] = [], limit: Int = CommandHistory.defaultLimit) {
        self.limit = max(1, limit)
        self.entries = Array(entries.suffix(self.limit))
    }

    /// Records a sent command. Whitespace-only commands are ignored; a command
    /// identical to the most recent entry is not recorded twice in a row
    /// (non-consecutive repeats are kept, matching shell history behavior).
    public mutating func record(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entries.last != trimmed else { return }
        entries.append(trimmed)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// The most recent `count` commands, newest first (for the history menu).
    public func recent(_ count: Int) -> [String] {
        entries.suffix(max(0, count)).reversed()
    }

    /// The most recent command that begins with `prefix` and extends it — the
    /// command bar's inline autosuggestion (zsh-autosuggestions style). Returns
    /// nil for an empty/whitespace-only prefix or when no longer entry shares it.
    /// Matching is case-sensitive, like the shell; the newest match wins (entries
    /// are scanned newest-first).
    public func autosuggestion(forPrefix prefix: String) -> String? {
        guard !prefix.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        for entry in entries.reversed() where entry.count > prefix.count && entry.hasPrefix(prefix) {
            return entry
        }
        return nil
    }
}

/// Up/down-arrow cursor over a `CommandHistory` while editing a draft.
///
/// The cursor starts "below" the history on the in-progress draft. `older`
/// (↑) stashes the draft and walks toward the oldest entry, stopping there;
/// `newer` (↓) walks back toward the newest and finally restores the draft.
/// Reset whenever a command is sent or text is inserted programmatically.
public struct CommandHistoryNavigator: Equatable, Sendable {
    /// Index into `entries` currently shown; nil = editing the draft.
    private var index: Int?
    private var draft = ""

    public init() {}

    /// Move one entry older (↑). `current` is the field text right now; it is
    /// stashed as the draft when leaving it. Returns the text to display, or
    /// nil when there is nothing older (caller leaves the field unchanged).
    public mutating func older(in history: CommandHistory, current: String) -> String? {
        guard !history.entries.isEmpty else { return nil }
        if var i = index {
            // History may have shrunk while navigating; clamp defensively.
            i = min(i, history.entries.count)
            guard i > 0 else { return nil }
            i -= 1
            index = i
            return history.entries[i]
        }
        draft = current
        index = history.entries.count - 1
        return history.entries[history.entries.count - 1]
    }

    /// Move one entry newer (↓); past the newest entry the stashed draft is
    /// restored. Returns nil when already on the draft.
    public mutating func newer(in history: CommandHistory) -> String? {
        guard let i = index else { return nil }
        if i + 1 < history.entries.count {
            index = i + 1
            return history.entries[i + 1]
        }
        index = nil
        return draft
    }

    public mutating func reset() {
        index = nil
        draft = ""
    }
}

/// Recent remote-directory history for the file panel: the same oldest-first,
/// capped, consecutive-dupe-collapsing list as `CommandHistory`, but for the
/// absolute paths the user has browsed to. Kept as a parallel type (rather than
/// reusing `CommandHistory`) so the two histories stay conceptually distinct
/// and can diverge later (e.g. a path-specific recall UI). Pure data —
/// persistence belongs to the app layer.
public struct PathHistory: Equatable, Sendable {
    /// Matches the command-history cap; FinalShell advertises "unlimited", so a
    /// large, sane bound keeps UserDefaults from growing without limit.
    public static let defaultLimit = 2000

    /// Oldest first, newest last.
    public private(set) var entries: [String]
    public let limit: Int

    public init(entries: [String] = [], limit: Int = PathHistory.defaultLimit) {
        self.limit = max(1, limit)
        self.entries = Array(entries.suffix(self.limit))
    }

    /// Records a browsed absolute path. Whitespace-only paths are ignored; a
    /// path identical to the most recent entry is not recorded twice in a row
    /// (non-consecutive repeats are kept, so the recall menu reflects the order
    /// the user actually visited directories).
    public mutating func record(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entries.last != trimmed else { return }
        entries.append(trimmed)
        if entries.count > limit {
            entries.removeFirst(entries.count - limit)
        }
    }

    /// The most recent `count` paths, newest first (for the history menu).
    public func recent(_ count: Int) -> [String] {
        entries.suffix(max(0, count)).reversed()
    }
}
