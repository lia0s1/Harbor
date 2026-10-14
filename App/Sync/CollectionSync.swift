import Foundation
import HarborKit

/// Per-cycle inputs shared by all collections.
struct SyncCycleContext {
    let now: Date
    let deviceID: String
    /// Gates the merger's notes carve-out; mirrors the notes-strip preference.
    let preserveNonEmptyNotes: Bool
    /// Filled after the folders collection merges; hosts nil out dangling
    /// folder references against it at landing time. nil = folders unknown
    /// this cycle (collection disabled or no live store) — skip the cleanup.
    var validFolderIDs: Set<UUID>?
}

struct CollectionCycleOutcome<Payload: Codable & Sendable> {
    /// Section to persist in the envelope (after the file-bound transform).
    let sectionForFile: SyncCollection<Payload>
    /// True when the file section differs from what the remote already has.
    let needsWrite: Bool
}

/// Deterministic per-item encoding for change detection. `.iso8601` matches
/// the stores' own date strategy so hashes are stable across launches. All
/// encoding happens on the main actor; sharing the encoder is safe.
private enum SyncCanonicalCodec {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

/// One synced collection: diffs the store against the persisted per-record
/// state to derive timestamps and tombstones, runs the pure merger, lands the
/// result in the stores (via `applyRemote`, so no echo), and adopts the merged
/// metadata back into the state so the next cycle starts from the same base
/// every other device sees.
@MainActor
final class CollectionSync<Payload: Identifiable & Codable & Sendable> where Payload.ID == UUID {
    let collectionID: SyncCollectionID

    /// Landing-time fixups (folder order normalization, dangling folderID
    /// cleanup) applied to merged items before they reach the stores.
    var applyFixup: ((inout [Payload], SyncCycleContext) -> Void)?

    /// Transform applied only to the file-bound copy (notes stripping).
    /// Neither the stores nor the local state hashes ever see it.
    var filePayloadTransform: ((inout Payload) -> Void)?

    private struct WeakStore { weak var value: JSONFileStore<Payload>? }
    private var stores: [WeakStore] = []

    init(collectionID: SyncCollectionID) {
        self.collectionID = collectionID
    }

    func attach(_ store: JSONFileStore<Payload>) {
        guard !stores.contains(where: { $0.value === store }) else { return }
        stores.append(WeakStore(value: store))
    }

    /// A collection with no live store (its owning window is closed) must be
    /// skipped wholesale — an empty item list would otherwise read as "the
    /// user deleted everything" and push tombstones to every device.
    var hasLiveStore: Bool {
        stores.contains { $0.value != nil }
    }

    private var liveStores: [JSONFileStore<Payload>] {
        stores.compactMap(\.value)
    }

    // MARK: - Canonical hashing

    private static func canonicalHash(_ item: Payload) -> String {
        guard let data = try? SyncCanonicalCodec.encoder.encode(item) else { return "" }
        return SyncFileIO.sha256Hex(of: data)
    }

    // MARK: - Cycle

    func syncCycle(
        remote: SyncCollection<Payload>?,
        state: CollectionSyncState,
        ctx: SyncCycleContext
    ) -> (outcome: CollectionCycleOutcome<Payload>, newState: CollectionSyncState) {
        let items = liveStores.first?.items ?? []
        let remoteByID = Dictionary((remote?.records ?? []).map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })

        // 1. Reconcile store items against the persisted state: keep timestamps
        //    of unchanged records, bump genuinely edited ones, adopt the
        //    remote's metadata when its payload is byte-identical (survives a
        //    lost state file without rewriting every record's clock).
        var recordsByID: [UUID: SyncRecord<Payload>] = [:]
        var seenIDs = Set<UUID>()
        recordsByID.reserveCapacity(items.count)

        for item in items {
            seenIDs.insert(item.id)
            let hash = Self.canonicalHash(item)
            let key = item.id.uuidString
            let modifiedAt: Date
            let deviceID: String
            if let existing = state.records[key], existing.deletedAt == nil {
                if existing.contentHash == hash {
                    (modifiedAt, deviceID) = (existing.modifiedAt, existing.deviceID)
                } else {
                    (modifiedAt, deviceID) = (ctx.now, ctx.deviceID)
                }
            } else if let remoteRecord = remoteByID[item.id],
                      !remoteRecord.isTombstone,
                      let remotePayload = remoteRecord.payload,
                      Self.canonicalHash(remotePayload) == hash {
                (modifiedAt, deviceID) = (remoteRecord.modifiedAt, remoteRecord.deviceID)
            } else {
                (modifiedAt, deviceID) = (ctx.now, ctx.deviceID)
            }
            recordsByID[item.id] = SyncRecord(id: item.id, modifiedAt: modifiedAt, deviceID: deviceID, payload: item)
        }

        // 2. Deletions: live in state, missing from the store → tombstone now.
        //    Existing tombstones carry over untouched until the merger GCs them.
        for (key, recordState) in state.records {
            guard let id = UUID(uuidString: key), !seenIDs.contains(id) else { continue }
            if let deletedAt = recordState.deletedAt {
                recordsByID[id] = SyncRecord(id: id, modifiedAt: recordState.modifiedAt, deviceID: recordState.deviceID, deletedAt: deletedAt)
            } else {
                recordsByID[id] = SyncRecord(id: id, modifiedAt: ctx.now, deviceID: ctx.deviceID, deletedAt: ctx.now)
            }
        }

        // 3. Order clock: bump only when the live id sequence actually changed.
        //    Exception: a rebuilt/stale state whose order is already consistent
        //    with the remote's adopts the remote order clock instead of
        //    claiming authorship — losing sync-state.json must not reshuffle
        //    or rewrite the shared order.
        let itemIDs = items.map(\.id)
        var orderModifiedAt = state.orderModifiedAt
        var orderDeviceID = state.orderDeviceID
        if state.orderSnapshot != itemIDs {
            let itemIDSet = Set(itemIDs)
            let remoteLiveOrder = (remote?.orderSnapshot ?? []).filter { id in
                itemIDSet.contains(id) && remoteByID[id]?.isTombstone == false
            }
            if let remote, !itemIDs.isEmpty, remoteLiveOrder == itemIDs {
                orderModifiedAt = remote.orderModifiedAt
                orderDeviceID = remote.orderDeviceID
            } else {
                orderModifiedAt = ctx.now
                orderDeviceID = ctx.deviceID
            }
        }

        let localSection = SyncCollection<Payload>(
            orderSnapshot: itemIDs,
            orderModifiedAt: orderModifiedAt,
            orderDeviceID: orderDeviceID,
            records: Array(recordsByID.values)
        )

        // 4. Merge.
        let result = SyncMerger.merge(
            local: localSection,
            remote: remote ?? .empty,
            now: ctx.now,
            preserveNonEmptyNotes: ctx.preserveNonEmptyNotes
        )

        // 5. Land: fixups first, then apply when the live set/order changed or
        //    a fixup rewrote a payload (dangling folderID cleanup runs even on
        //    cycles where the hosts metadata itself is unchanged).
        var landingItems = result.orderedItems
        applyFixup?(&landingItems, ctx)
        let fixupChangedPayloads = zip(landingItems, result.orderedItems).contains {
            Self.canonicalHash($0) != Self.canonicalHash($1)
        }
        if result.localNeedsApply || fixupChangedPayloads {
            for store in liveStores {
                store.applyRemote(landingItems)
            }
        }

        // 6. Adopt merged metadata into the state. Live records hash the
        //    APPLIED payload (post-fixup, post-notes-preservation) so the next
        //    cycle doesn't see a phantom edit.
        var finalRecords: [String: SyncRecordState] = [:]
        let appliedByID = Dictionary(landingItems.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for record in result.merged.records {
            if record.isTombstone {
                finalRecords[record.id.uuidString] = SyncRecordState(
                    modifiedAt: record.modifiedAt, deviceID: record.deviceID,
                    deletedAt: record.deletedAt, contentHash: ""
                )
            } else if let applied = appliedByID[record.id] {
                finalRecords[record.id.uuidString] = SyncRecordState(
                    modifiedAt: record.modifiedAt, deviceID: record.deviceID,
                    deletedAt: nil, contentHash: Self.canonicalHash(applied)
                )
            }
        }
        var newState = CollectionSyncState()
        newState.records = finalRecords
        newState.orderSnapshot = result.merged.orderSnapshot
        newState.orderModifiedAt = result.merged.orderModifiedAt
        newState.orderDeviceID = result.merged.orderDeviceID

        // 7. File-bound copy: notes stripping happens here and only here.
        var sectionForFile = result.merged
        if let transform = filePayloadTransform {
            for index in sectionForFile.records.indices where sectionForFile.records[index].payload != nil {
                var payload = sectionForFile.records[index].payload!
                transform(&payload)
                sectionForFile.records[index].payload = payload
            }
        }

        let needsWrite = result.remoteNeedsWrite
            || remote == nil
            || payloadSignature(of: sectionForFile) != payloadSignature(of: remote ?? .empty)

        return (CollectionCycleOutcome(sectionForFile: sectionForFile, needsWrite: needsWrite), newState)
    }

    /// Metadata + payload hashes per record: catches file-bound divergences
    /// (e.g. notes stripped on write) that the merger's metadata-only
    /// `remoteNeedsWrite` flag cannot see.
    private func payloadSignature(of section: SyncCollection<Payload>) -> [String: String] {
        var map: [String: String] = [:]
        for record in section.records {
            let payloadHash = record.payload.map { Self.canonicalHash($0) } ?? ""
            map[record.id.uuidString] = [
                record.modifiedAt.timeIntervalSince1970,
                record.deviceID,
                record.deletedAt?.timeIntervalSince1970 ?? 0,
                payloadHash,
            ].map { "\($0)" }.joined(separator: "|")
        }
        return map
    }
}
