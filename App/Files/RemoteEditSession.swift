import Foundation
import AppKit
import HarborKit

/// An opaque optimistic-concurrency token for one remote regular file. GNU
/// `stat` supplies the device/inode, size, and nanosecond-resolution mtime and
/// ctime. Keeping it opaque avoids reparsing locale-sensitive timestamps.
struct RemoteFileVersion: Equatable, Sendable {
    let token: String
}

enum RemoteEditFailure: Error, Equatable, Sendable {
    case conflict
    case symlink
    case message(String)

    @MainActor var message: String {
        switch self {
        case .conflict:
            return L("远程文件已被其他程序修改；为避免覆盖，保存已停止。")
        case .symlink:
            return L("为避免替换符号链接，远程编辑不支持符号链接文件。")
        case .message(let message):
            return message
        }
    }
}

private let remoteVersionMarker = "HARBOR_EDIT_VERSION_CONFLICT"
private let remoteSymlinkMarker = "HARBOR_EDIT_SYMLINK"
private let remoteVersionFormat = "%d|%i|%s|%y|%z"

/// Reads a version token without following a symbolic link supplied as the
/// path itself. The file panel is Linux-only, so GNU `stat` is already part of
/// its supported-server contract.
@MainActor
func readRemoteFileVersion(
    using exec: RemoteExec,
    path: String,
    timeout: TimeInterval = 20
) async -> Result<RemoteFileVersion, RemoteEditFailure> {
    let script = """
    if [ -L \(sq(path)) ]; then
      printf '%s\\n' '\(remoteSymlinkMarker)' >&2
      exit 73
    fi
    LC_ALL=C stat -Lc '\(remoteVersionFormat)' -- \(sq(path))
    """
    let output = await exec.run(script, timeout: timeout)
    guard !output.timedOut, output.exitCode == 0 else {
        return .failure(remoteEditFailure(from: output))
    }
    let token = output.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !token.contains("\n") else {
        return .failure(.message(L("无法读取远程文件版本。")))
    }
    return .success(RemoteFileVersion(token: token))
}

/// Uploads to a unique sibling and only then replaces the destination. The
/// second version comparison happens immediately before `mv`, which prevents a
/// slow upload from overwriting edits made after the caller's first check.
@MainActor
func atomicRemoteUpload(
    localURL: URL,
    remotePath: String,
    expectedVersion: RemoteFileVersion,
    using exec: RemoteExec,
    timeout: TimeInterval
) async -> Result<RemoteFileVersion, RemoteEditFailure> {
    let parent = RemotePath.parent(of: remotePath)
    let stagedPath = RemotePath.join(parent, ".harbor-edit-\(UUID().uuidString).part")

    let put = await exec.runSFTPBatch(
        SFTPBatch.put(local: localURL.path, remote: stagedPath),
        timeout: timeout
    )
    guard !put.timedOut, put.exitCode == 0 else {
        await removeRemoteEditStaging(stagedPath, using: exec)
        return .failure(remoteEditFailure(from: put))
    }
    guard !Task.isCancelled else {
        await removeRemoteEditStaging(stagedPath, using: exec)
        return .failure(.message(L("操作已取消；远程文件未被替换。")))
    }

    let script = """
    set -eu
    if [ -L \(sq(remotePath)) ]; then
      printf '%s\\n' '\(remoteSymlinkMarker)' >&2
      exit 73
    fi
    current=$(LC_ALL=C stat -Lc '\(remoteVersionFormat)' -- \(sq(remotePath))) || exit 74
    if [ "$current" != \(sq(expectedVersion.token)) ]; then
      printf '%s\\n' '\(remoteVersionMarker)' >&2
      exit 75
    fi
    chmod --reference=\(sq(remotePath)) -- \(sq(stagedPath))
    mv -fT -- \(sq(stagedPath)) \(sq(remotePath))
    LC_ALL=C stat -Lc '\(remoteVersionFormat)' -- \(sq(remotePath))
    """
    let commit = await exec.run(script, timeout: timeout)
    guard !commit.timedOut, commit.exitCode == 0 else {
        await removeRemoteEditStaging(stagedPath, using: exec)
        return .failure(remoteEditFailure(from: commit))
    }
    let token = commit.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, !token.contains("\n") else {
        return .failure(.message(L("远程文件已替换，但无法确认新版本；请刷新后再编辑。")))
    }
    return .success(RemoteFileVersion(token: token))
}

private func removeRemoteEditStaging(_ path: String, using exec: RemoteExec) async {
    // Cleanup must still run when the caller was cancelled; otherwise a closed
    // tab can leave a sibling `.part` file on the server.
    let cleanup = Task.detached {
        _ = await exec.run("rm -f -- \(sq(path))", timeout: 20)
    }
    _ = await cleanup.value
}

@MainActor
private func remoteEditFailure(from output: AuxProcess.Output) -> RemoteEditFailure {
    let stderr = output.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
    if stderr.contains(remoteSymlinkMarker) { return .symlink }
    if stderr.contains(remoteVersionMarker) { return .conflict }
    if output.timedOut { return .message(L("操作超时")) }
    if let line = stderr.split(separator: "\n").last(where: {
        !$0.trimmingCharacters(in: .whitespaces).isEmpty
    }) {
        return .message(String(line))
    }
    return .message(L("命令执行失败（退出码 %lld）", Int(output.exitCode)))
}

/// "Edit a remote file" via an EXTERNAL editor: the file is downloaded to a temp
/// copy under a unique `harbor-edit-<UUID>/` dir and opened in the user's default
/// editor; this session watches the temp copy and uploads it back on every save
/// (polling the modification time, so it works however the editor writes — in
/// place or atomic replace).
///
/// Lifetime is owned by `FileService`, which holds the session and calls
/// `cancel()` when the SSH session exits (otherwise the poll timer would keep
/// firing sftp uploads over a dead ControlMaster socket, and the saves would
/// silently fail). The session also ends itself if the temp file disappears.
/// Ending invalidates the timer. A fully-synced temp tree is removed; a failed
/// or conflicting edit is deliberately preserved so teardown cannot destroy
/// the user's only current copy.
@MainActor
final class RemoteEditSession {
    private let localURL: URL
    private let remotePath: String
    private let exec: RemoteExec
    private let onUpload: (Result<Void, RemoteEditFailure>) -> Void
    /// Invoked when the session ends on its OWN (temp file gone) so the owner can
    /// release it. Not called by `cancel()` — the owner initiated that.
    private let onEnd: (RemoteEditSession) -> Void

    private var timer: Timer?
    private var uploadTask: Task<Void, Never>?
    private var lastModified: Date?
    private var expectedVersion: RemoteFileVersion
    private var uploading = false
    private var pending = false
    private var stopped = false
    /// A failed/conflicting upload must never cause teardown to delete the only
    /// copy of the user's latest local edits.
    private var hasUnsyncedChanges = false
    /// Consecutive idle ticks (no detected change). Drives the poll back-off.
    private var idleTicks = 0
    /// false while the timer runs at the fast interval, true once backed off.
    private var slowPolling = false

    /// Fast cadence right after activity; slow cadence once the file sits idle,
    /// so a config left open in an external editor all session long isn't stat'd
    /// every 1.2s forever.
    private static let activeInterval: TimeInterval = 1.2
    private static let idleInterval: TimeInterval = 6
    /// Idle ticks at the fast cadence before backing off (~10s of no changes).
    private static let idleThreshold = 8

    init(
        localURL: URL,
        remotePath: String,
        expectedVersion: RemoteFileVersion,
        exec: RemoteExec,
        onUpload: @escaping (Result<Void, RemoteEditFailure>) -> Void,
        onEnd: @escaping (RemoteEditSession) -> Void
    ) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.expectedVersion = expectedVersion
        self.exec = exec
        self.onUpload = onUpload
        self.onEnd = onEnd
    }

    func start() {
        lastModified = modifiedDate()
        NSWorkspace.shared.open(localURL)
        scheduleTimer(interval: Self.activeInterval)
    }

    /// Owner-initiated stop (the SSH session exited / tab closed): stop syncing
    /// and clean up. Idempotent.
    func cancel() {
        teardown()
    }

    private func scheduleTimer(interval: TimeInterval) {
        timer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
    }

    private func tick() {
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            teardown()      // temp file gone: nothing left to sync.
            onEnd(self)     // let the owner drop its reference.
            return
        }
        let modified = modifiedDate()
        if let modified, modified != lastModified {
            lastModified = modified
            hasUnsyncedChanges = true
            idleTicks = 0
            if slowPolling { slowPolling = false; scheduleTimer(interval: Self.activeInterval) }
            upload()
        } else if !slowPolling {
            idleTicks += 1
            if idleTicks >= Self.idleThreshold {
                slowPolling = true
                scheduleTimer(interval: Self.idleInterval)
            }
        }
    }

    private func upload() {
        if uploading { pending = true; return }
        uploading = true
        let uploadedModificationDate = modifiedDate()
        let exec = self.exec
        uploadTask = Task { [weak self] in
            guard let self else { return }
            let result = await atomicRemoteUpload(
                localURL: self.localURL,
                remotePath: self.remotePath,
                expectedVersion: self.expectedVersion,
                using: exec,
                timeout: 600
            )
            guard !self.stopped else { return }
            self.uploading = false
            switch result {
            case .success(let newVersion):
                self.expectedVersion = newVersion
                let changedDuringUpload = self.modifiedDate() != uploadedModificationDate
                self.hasUnsyncedChanges = self.pending || changedDuringUpload
                self.onUpload(.success(()))
                if self.pending || changedDuringUpload {
                    self.pending = false
                    self.upload()
                }
            case .failure(let failure):
                self.hasUnsyncedChanges = true
                self.onUpload(.failure(.message(L(
                    "%@ 本地副本保留在：%@", failure.message, self.localURL.path))))
                if failure == .conflict || failure == .symlink {
                    // Automatic retries would repeatedly overwrite nothing and
                    // hide the conflict among transfer rows. Preserve the local
                    // copy and stop this sync session until the user reconnects.
                    self.timer?.invalidate()
                    self.timer = nil
                    self.pending = false
                }
            }
        }
    }

    private func modifiedDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.modificationDate]) as? Date
    }

    /// Stops the timer and removes the whole `harbor-edit-<UUID>/` temp dir.
    /// Idempotent.
    private func teardown() {
        guard !stopped else { return }
        stopped = true
        timer?.invalidate()
        timer = nil
        // Cancel any in-flight upload so its sftp child is SIGTERM'd at once
        // (via AuxProcess's cancellation handler) instead of clinging to the
        // dead ControlMaster socket until the 600s timeout.
        uploadTask?.cancel()
        uploadTask = nil
        if !hasUnsyncedChanges {
            try? FileManager.default.removeItem(at: localURL.deletingLastPathComponent())
        }
    }
}
