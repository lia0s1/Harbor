import Foundation
import HarborKit

/// A non-destructive comparison between one local folder and the currently
/// visible remote folder. Only regular files are considered: directories and
/// symlinks need an explicit transfer action instead of being silently walked.
struct DirectorySyncPreview: Identifiable, Sendable {
    let localDirectory: URL
    let remoteDirectory: String
    let changes: [DirectorySyncChange]

    var id: String { "\(localDirectory.path)|\(remoteDirectory)" }

    /// The only local paths a confirmation is allowed to upload. Remote-only
    /// rows deliberately have no local URL, so this can never delete remotely.
    var uploadURLs: [URL] {
        changes.compactMap { change in
            switch change.kind {
            case .localOnly, .modified:
                return change.localURL
            case .remoteOnly:
                return nil
            }
        }
    }
}

struct DirectorySyncChange: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case localOnly
        case modified
        case remoteOnly
    }

    let name: String
    let kind: Kind
    let localURL: URL?
    let localSize: UInt64?
    let localMtime: Date?
    let remoteSize: UInt64?
    let remoteMtimeEpoch: Int?

    var id: String { "\(kind.rawValue)|\(name)" }
}

struct DirectorySyncPlanningError: Error, Sendable {
    let message: String
}

enum DirectorySyncPlanner {
    /// Builds a preview off the main actor. A one-second tolerance matches the
    /// remote listing's integer-second timestamps without hiding true changes.
    static func makePreview(
        localDirectory: URL,
        remoteDirectory: String,
        remoteEntries: [RemoteFileEntry]
    ) throws -> DirectorySyncPreview {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let localURLs: [URL]
        do {
            localURLs = try FileManager.default.contentsOfDirectory(
                at: localDirectory,
                includingPropertiesForKeys: Array(keys),
                options: []
            )
        } catch {
            throw DirectorySyncPlanningError(message: error.localizedDescription)
        }

        var localFiles: [String: (url: URL, size: UInt64, mtime: Date)] = [:]
        for url in localURLs {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
            let size = UInt64(values?.fileSize ?? 0)
            let mtime = values?.contentModificationDate ?? .distantPast
            localFiles[url.lastPathComponent] = (url, size, mtime)
        }

        let remoteFiles = Dictionary(uniqueKeysWithValues: remoteEntries
            .filter { !$0.isDirectory && !$0.isSymlink }
            .map { ($0.name, $0) })
        var changes: [DirectorySyncChange] = []

        for (name, local) in localFiles {
            guard let remote = remoteFiles[name] else {
                changes.append(DirectorySyncChange(
                    name: name,
                    kind: .localOnly,
                    localURL: local.url,
                    localSize: local.size,
                    localMtime: local.mtime,
                    remoteSize: nil,
                    remoteMtimeEpoch: nil
                ))
                continue
            }
            let localEpoch = Int(local.mtime.timeIntervalSince1970)
            if local.size != remote.sizeBytes || abs(localEpoch - remote.mtimeEpoch) > 1 {
                changes.append(DirectorySyncChange(
                    name: name,
                    kind: .modified,
                    localURL: local.url,
                    localSize: local.size,
                    localMtime: local.mtime,
                    remoteSize: remote.sizeBytes,
                    remoteMtimeEpoch: remote.mtimeEpoch
                ))
            }
        }

        for (name, remote) in remoteFiles where localFiles[name] == nil {
            changes.append(DirectorySyncChange(
                name: name,
                kind: .remoteOnly,
                localURL: nil,
                localSize: nil,
                localMtime: nil,
                remoteSize: remote.sizeBytes,
                remoteMtimeEpoch: remote.mtimeEpoch
            ))
        }

        changes.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return DirectorySyncPreview(
            localDirectory: localDirectory,
            remoteDirectory: remoteDirectory,
            changes: changes
        )
    }
}
