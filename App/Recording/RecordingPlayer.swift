import Combine
import Foundation
import SwiftTerm

/// Replays a Harbor session recording into a read-only `TerminalView`.
///
/// ## Recording format
/// `TerminalSession.startRecording()` appends the RAW terminal-output bytes to
/// `~/Library/Logs/Harbor/<host>-<stamp>.log` — no timestamps, no framing, just
/// the byte stream the child process emitted. Because there is no timing data,
/// playback cannot reproduce the *original* wall-clock pace; instead the stream
/// is fed at a steady synthetic rate (`baseBytesPerSecond`) that the speed
/// control multiplies. Terminal state is cumulative, so seeking rewinds by
/// resetting the emulator and replaying from the start up to the target offset.
///
/// The file is streamed in small chunks (never fully read into memory) so a
/// multi-megabyte log costs no more than a tiny buffer.
@MainActor
final class RecordingPlayer: ObservableObject {
    enum PlaybackState: Equatable {
        /// No recording loaded yet.
        case empty
        case playing
        case paused
        /// Reached the end of the stream.
        case finished
    }

    /// Playback speed multipliers offered in the transport bar.
    enum Speed: Double, CaseIterable, Identifiable {
        case x1 = 1, x2 = 2, x5 = 5, x10 = 10
        var id: Double { rawValue }
        var label: String { "\(Int(rawValue))×" }
    }

    struct SearchMatch: Identifiable, Equatable, Sendable {
        /// Byte offset in the raw recording stream. Raw recordings have no
        /// timestamps, so the byte position is the exact seek target.
        let offset: Int
        let preview: String

        var id: Int { offset }
    }

    @Published private(set) var state: PlaybackState = .empty
    /// Fraction of the recording that has been fed, 0.0 ... 1.0.
    @Published private(set) var progress: Double = 0
    /// File name of the loaded recording (for display); empty when none.
    @Published private(set) var fileName: String = ""
    /// Live speed; the next timer tick picks up a change automatically.
    @Published var speed: Speed = .x1
    @Published private(set) var searchMatches: [SearchMatch] = []
    @Published private(set) var selectedSearchMatchIndex: Int?
    @Published private(set) var isSearching = false

    /// The terminal the bytes are fed into. Owned by the view layer; a plain
    /// `TerminalView` with no `terminalDelegate` is inherently read-only, since
    /// keystrokes would only reach the (absent) delegate.
    weak var terminal: TerminalView?

    /// Bytes fed per second at 1× speed. Interactive sessions replay at a
    /// readable pace; the speed control and scrubber cover large logs.
    private let baseBytesPerSecond = 6_000
    private let ticksPerSecond = 60.0

    private var fileHandle: FileHandle?
    private var fileURL: URL?
    private var totalBytes = 0
    private var bytesFed = 0
    private var seekGeneration = 0
    /// `nonisolated(unsafe)` so the nonisolated `deinit` can invalidate it. It is
    /// only ever mutated from the main actor, and SwiftUI releases the owning
    /// `@StateObject` on the main thread, so the deinit call runs there too.
    private nonisolated(unsafe) var timer: Timer?
    private nonisolated(unsafe) var searchTask: Task<Void, Never>?

    deinit {
        // The file handle closes its descriptor when ARC releases it; only the
        // repeating timer (retained by the run loop) must be torn down here.
        timer?.invalidate()
        searchTask?.cancel()
    }

    // MARK: - Derived display values

    /// Intrinsic recording length in seconds (at 1× pace). Independent of the
    /// chosen speed, which only fast-forwards through this same length.
    var totalDuration: TimeInterval {
        totalBytes > 0 ? Double(totalBytes) / Double(baseBytesPerSecond) : 0
    }

    var currentTime: TimeInterval { totalDuration * progress }
    var isPlaying: Bool { state == .playing }
    var hasRecording: Bool { state != .empty }

    // MARK: - Loading

    /// Opens a recording and starts playing from the beginning. Streams the
    /// file; only small chunks are ever held in memory.
    func load(url: URL) {
        stopTimer()
        clearSearch()
        seekGeneration += 1
        try? fileHandle?.close()
        fileHandle = nil

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            resetToEmpty()
            return
        }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: 0)

        fileHandle = handle
        fileURL = url
        totalBytes = Int(end)
        bytesFed = 0
        progress = 0
        fileName = url.lastPathComponent

        resetTerminal()
        if totalBytes == 0 {
            state = .finished
        } else {
            state = .playing
            startTimer()
        }
    }

    // MARK: - Transport

    func play() {
        guard hasRecording else { return }
        // Hitting play after the end replays from the top. Reset directly here
        // rather than calling seek(toFraction:) because seek now returns before
        // its background work completes, so the state writes below would race.
        if state == .finished {
            resetTerminal()
            try? fileHandle?.seek(toOffset: 0)
            bytesFed = 0
            progress = 0
        }
        state = .playing
        startTimer()
    }

    func pause() {
        guard state == .playing else { return }
        state = .paused
        stopTimer()
    }

    func togglePlayPause() {
        isPlaying ? pause() : play()
    }

    /// Reposition to `fraction` (0...1). Because terminal state is cumulative,
    /// this resets the emulator and replays the byte stream from the start up
    /// to the target offset, then restores the prior transport state.
    ///
    /// The byte-replay loop runs on a background thread via `Task.detached` so
    /// it never blocks the main actor; the terminal feed and state updates are
    /// dispatched back to the main actor when the background work finishes.
    /// Recordings larger than this limit cannot be seeked: loading all bytes
    /// up to the target offset into a single Data buffer would exhaust memory.
    private static let seekMemoryLimitBytes = 100 * 1024 * 1024

    func seek(toFraction fraction: Double) {
        guard hasRecording, totalBytes > 0, let handle = fileHandle else { return }
        guard totalBytes <= Self.seekMemoryLimitBytes else { return }
        let wasPlaying = state == .playing
        stopTimer()
        seekGeneration += 1
        let seekGen = seekGeneration

        let clamped = min(max(fraction, 0), 1)
        let target = Int((clamped * Double(totalBytes)).rounded())
        resetTerminal()

        // Capture URL so we can detect if load() replaces the file while
        // the background seek is in flight (REC-2: seek/load race condition).
        let seekURL = fileURL

        Task {
            // Collect all bytes up to `target` on a background thread.
            let collected: Data = await Task.detached(priority: .userInitiated) {
                try? handle.seek(toOffset: 0)
                var result = Data()
                result.reserveCapacity(target)
                var remaining = target
                let bufferSize = 64 * 1024
                while remaining > 0 {
                    let chunk = (try? handle.read(upToCount: min(bufferSize, remaining))) ?? Data()
                    if chunk.isEmpty { break }
                    result.append(chunk)
                    remaining -= chunk.count
                }
                return result
            }.value

            // Discard stale results if load() was called while we were seeking.
            guard self.fileURL == seekURL else { return }
            guard self.seekGeneration == seekGen else { return }

            // Back on the main actor: feed the terminal and restore playback state.
            self.feed(collected)
            self.bytesFed = collected.count
            try? handle.seek(toOffset: UInt64(collected.count))
            self.progress = self.totalBytes > 0 ? Double(self.bytesFed) / Double(self.totalBytes) : 0

            if self.bytesFed >= self.totalBytes {
                self.state = .finished
            } else if wasPlaying {
                self.state = .playing
                self.startTimer()
            } else {
                self.state = .paused
            }
        }
    }

    // MARK: - Search

    /// Finds raw text matches without loading the complete recording into
    /// memory. Selecting a result reuses the existing seek path so playback
    /// state is reconstructed exactly at the match's byte offset.
    func search(_ query: String) {
        searchTask?.cancel()
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let fileURL, !needle.isEmpty else {
            clearSearch()
            return
        }

        isSearching = true
        let searchURL = fileURL
        searchTask = Task { [weak self] in
            let matches = await Task.detached(priority: .userInitiated) {
                Self.findMatches(in: searchURL, needle: needle, limit: 200)
            }.value
            guard let self, !Task.isCancelled, self.fileURL == searchURL else { return }
            self.searchMatches = matches
            self.selectedSearchMatchIndex = matches.isEmpty ? nil : 0
            self.isSearching = false
        }
    }

    func selectNextSearchMatch() {
        selectSearchMatch(advancing: 1)
    }

    func selectPreviousSearchMatch() {
        selectSearchMatch(advancing: -1)
    }

    func selectSearchMatch(at index: Int) {
        guard searchMatches.indices.contains(index) else { return }
        selectedSearchMatchIndex = index
        seek(toByteOffset: searchMatches[index].offset)
    }

    private func selectSearchMatch(advancing delta: Int) {
        guard !searchMatches.isEmpty else { return }
        let current = selectedSearchMatchIndex ?? 0
        let next = (current + delta + searchMatches.count) % searchMatches.count
        selectedSearchMatchIndex = next
        seek(toByteOffset: searchMatches[next].offset)
    }

    private func seek(toByteOffset offset: Int) {
        guard totalBytes > 0 else { return }
        seek(toFraction: Double(min(max(offset, 0), totalBytes)) / Double(totalBytes))
    }

    private func clearSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchMatches = []
        selectedSearchMatchIndex = nil
        isSearching = false
    }

    private nonisolated static func findMatches(in url: URL, needle: String, limit: Int) -> [SearchMatch] {
        let needleData = Data(needle.utf8)
        guard !needleData.isEmpty, let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        let chunkSize = 64 * 1024
        var fileOffset = 0
        var carry = Data()
        var matches: [SearchMatch] = []

        while matches.count < limit, let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var combined = carry
            combined.append(chunk)
            let stableEnd = max(0, combined.count - needleData.count + 1)
            var searchStart = 0

            while searchStart < stableEnd, matches.count < limit,
                  let range = combined.range(of: needleData, options: [], in: searchStart..<stableEnd) {
                let absoluteOffset = fileOffset - carry.count + range.lowerBound
                matches.append(SearchMatch(offset: absoluteOffset, preview: preview(in: combined, around: range)))
                searchStart = range.upperBound
            }

            let carryCount = min(max(needleData.count - 1, 0), combined.count)
            carry = carryCount == 0 ? Data() : Data(combined.suffix(carryCount))
            fileOffset += chunk.count
        }
        return matches
    }

    private nonisolated static func preview(in data: Data, around range: Range<Int>) -> String {
        let lower = max(0, range.lowerBound - 48)
        let upper = min(data.count, range.upperBound + 96)
        let raw = String(decoding: data[lower..<upper], as: UTF8.self)
        let compact = raw.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? " " : String($0)
        }.joined()
        return compact.replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Timer feeding

    private func startTimer() {
        stopTimer()
        let t = Timer(timeInterval: 1.0 / ticksPerSecond, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so feeding keeps running while the scrubber or a menu tracks.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    /// Bytes to feed on each tick at the current speed.
    private var bytesPerTick: Int {
        max(1, Int((Double(baseBytesPerSecond) * speed.rawValue / ticksPerSecond).rounded()))
    }

    private func tick() {
        guard state == .playing, let handle = fileHandle else { return }
        let data = (try? handle.read(upToCount: bytesPerTick)) ?? Data()
        if data.isEmpty {
            finish()
            return
        }
        feed(data)
        bytesFed += data.count
        progress = totalBytes > 0 ? min(1, Double(bytesFed) / Double(totalBytes)) : 1
        if bytesFed >= totalBytes { finish() }
    }

    private func finish() {
        stopTimer()
        progress = 1
        state = .finished
    }

    // MARK: - Terminal plumbing

    private func feed(_ data: Data) {
        guard let terminal, !data.isEmpty else { return }
        let bytes = [UInt8](data)
        terminal.feed(byteArray: bytes[...])
    }

    private func resetTerminal() {
        terminal?.getTerminal().resetToInitialState()
    }

    private func resetToEmpty() {
        clearSearch()
        fileURL = nil
        totalBytes = 0
        bytesFed = 0
        progress = 0
        fileName = ""
        state = .empty
    }
}
