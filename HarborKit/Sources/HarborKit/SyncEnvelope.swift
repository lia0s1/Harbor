import Foundation

// MARK: - Envelope models

/// One synced record: the payload plus the sync metadata that never touches
/// the model itself. A record with `deletedAt != nil` is a tombstone — its
/// payload is always nil on the wire and after merging.
public struct SyncRecord<Payload: Codable & Sendable>: Codable, Sendable {
    public var id: UUID
    /// Last-modified time of the winning writer. For tombstones this equals
    /// the deletion time; LWW compares it against live edits for resurrection.
    public var modifiedAt: Date
    /// Stable per-install device UUID of the writer; lexicographic tiebreak
    /// when two `modifiedAt` timestamps are exactly equal.
    public var deviceID: String
    public var deletedAt: Date?
    public var payload: Payload?

    public init(id: UUID, modifiedAt: Date, deviceID: String, deletedAt: Date? = nil, payload: Payload? = nil) {
        self.id = id
        self.modifiedAt = modifiedAt
        self.deviceID = deviceID
        self.deletedAt = deletedAt
        self.payload = payload
    }

    public var isTombstone: Bool { deletedAt != nil }

    // Tolerant decoding, mirroring the store codecs: a record missing metadata
    // falls back to harmless defaults (epoch timestamp loses every LWW) instead
    // of aborting the whole section decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        modifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .modifiedAt)) ?? Date(timeIntervalSince1970: 0)
        deviceID = (try? c.decodeIfPresent(String.self, forKey: .deviceID)) ?? ""
        deletedAt = try? c.decodeIfPresent(Date.self, forKey: .deletedAt)
        payload = deletedAt == nil ? try? c.decodeIfPresent(Payload.self, forKey: .payload) : nil
    }
}

/// One synced collection: the record set plus the list order, which is
/// collection-level state (sidebar order, folder order) that record-level LWW
/// cannot express and therefore gets its own `(orderModifiedAt, orderDeviceID)`
/// clock.
public struct SyncCollection<Payload: Codable & Sendable>: Codable, Sendable {
    public var orderSnapshot: [UUID]
    public var orderModifiedAt: Date
    public var orderDeviceID: String
    public var records: [SyncRecord<Payload>]

    public init(
        orderSnapshot: [UUID] = [],
        orderModifiedAt: Date = Date(timeIntervalSince1970: 0),
        orderDeviceID: String = "",
        records: [SyncRecord<Payload>] = []
    ) {
        self.orderSnapshot = orderSnapshot
        self.orderModifiedAt = orderModifiedAt
        self.orderDeviceID = orderDeviceID
        self.records = records
    }

    public static var empty: SyncCollection { SyncCollection() }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        orderSnapshot = (try? c.decodeIfPresent([UUID].self, forKey: .orderSnapshot)) ?? []
        orderModifiedAt = (try? c.decodeIfPresent(Date.self, forKey: .orderModifiedAt)) ?? Date(timeIntervalSince1970: 0)
        orderDeviceID = (try? c.decodeIfPresent(String.self, forKey: .orderDeviceID)) ?? ""
        records = (try? c.decodeIfPresent([SyncRecord<Payload>].self, forKey: .records)) ?? []
    }
}

/// Payloads carrying a free-text notes field. Only `SSHHost` conforms today.
/// Used by the single field-level merge rule: an empty winner notes must not
/// wipe a non-empty loser notes when the winning device strips notes from its
/// outgoing envelope.
public protocol SyncNotesCarrier {
    var syncNotes: String { get }
    func withSyncNotes(_ notes: String) -> Self
}

extension SSHHost: SyncNotesCarrier {
    public var syncNotes: String { notes }
    public func withSyncNotes(_ notes: String) -> SSHHost {
        var copy = self
        copy.notes = notes
        return copy
    }
}

// MARK: - Merge result

public struct SyncMergeResult<Payload: Codable & Sendable>: Sendable {
    /// The authoritative merged collection both sides converge to. Records are
    /// sorted by id for deterministic encoding.
    public let merged: SyncCollection<Payload>
    /// Live payloads in merged order — what a store applies via applyRemote.
    public let orderedItems: [Payload]
    /// True when the merged live set or order differs from the local section's.
    public let localNeedsApply: Bool
    /// True when the merged section (incl. tombstones) differs from remote's.
    public let remoteNeedsWrite: Bool

    public init(merged: SyncCollection<Payload>, orderedItems: [Payload], localNeedsApply: Bool, remoteNeedsWrite: Bool) {
        self.merged = merged
        self.orderedItems = orderedItems
        self.localNeedsApply = localNeedsApply
        self.remoteNeedsWrite = remoteNeedsWrite
    }
}

// MARK: - Merger

/// Record-level last-writer-wins merge. Pure and deterministic:
/// - per record the `(modifiedAt, deviceID)` lexicographic maximum wins;
///   exact ties take the remote record (reachable only via same-device
///   same-timestamp landing fixups — picking remote converges every device on
///   the file's contents).
/// - tombstones participate in the same LWW, so a newer live edit resurrects
///   an id and a newer delete propagates.
/// - tombstones older than `tombstoneHorizon` (30 days) are garbage-collected
///   on the next write.
/// - order snapshots merge by their own `(orderModifiedAt, orderDeviceID)`
///   clock; ids missing from the winning snapshot append in id order.
public enum SyncMerger {
    public static let tombstoneHorizon: TimeInterval = 30 * 24 * 60 * 60

    public static func merge<Payload: Codable & Sendable>(
        local: SyncCollection<Payload>,
        remote: SyncCollection<Payload>,
        now: Date = Date(),
        preserveNonEmptyNotes: Bool = false
    ) -> SyncMergeResult<Payload> {
        var localByID: [UUID: SyncRecord<Payload>] = [:]
        for record in local.records { localByID[record.id] = record }
        var remoteByID: [UUID: SyncRecord<Payload>] = [:]
        for record in remote.records { remoteByID[record.id] = record }

        var mergedRecords: [SyncRecord<Payload>] = []
        mergedRecords.reserveCapacity(max(localByID.count, remoteByID.count))
        for id in Set(localByID.keys).union(remoteByID.keys) {
            switch (localByID[id], remoteByID[id]) {
            case let (localRecord?, remoteRecord?):
                mergedRecords.append(resolve(localRecord, remoteRecord, preserveNonEmptyNotes: preserveNonEmptyNotes))
            case let (localRecord?, nil):
                mergedRecords.append(normalized(localRecord))
            case let (nil, remoteRecord?):
                mergedRecords.append(normalized(remoteRecord))
            case (nil, nil):
                break
            }
        }

        // GC: physically drop tombstones past the horizon. A device offline
        // longer than that may see its already-synced deletions come back —
        // accepted trade-off, documented in the design doc.
        mergedRecords.removeAll { record in
            guard let deletedAt = record.deletedAt else { return false }
            return now.timeIntervalSince(deletedAt) > tombstoneHorizon
        }
        mergedRecords.sort { $0.id.uuidString < $1.id.uuidString }

        // Order: the newer order clock wins; ids absent from the winning
        // snapshot (freshly merged records) append in id order; snapshot ids
        // that no longer name a live record drop out.
        let orderWinner = wins(
            (local.orderModifiedAt, local.orderDeviceID),
            over: (remote.orderModifiedAt, remote.orderDeviceID)
        ) ? local : remote
        let liveIDs = Set(mergedRecords.compactMap { $0.isTombstone ? nil : $0.id })
        var order = orderWinner.orderSnapshot.filter { liveIDs.contains($0) }
        order.append(contentsOf: liveIDs.subtracting(order).sorted { $0.uuidString < $1.uuidString })

        let merged = SyncCollection(
            orderSnapshot: order,
            orderModifiedAt: orderWinner.orderModifiedAt,
            orderDeviceID: orderWinner.orderDeviceID,
            records: mergedRecords
        )

        let payloadByID = Dictionary(uniqueKeysWithValues: mergedRecords.compactMap { record in
            record.payload.map { (record.id, $0) }
        })
        let orderedItems = order.compactMap { payloadByID[$0] }

        return SyncMergeResult(
            merged: merged,
            orderedItems: orderedItems,
            localNeedsApply: liveSignature(of: merged) != liveSignature(of: local),
            remoteNeedsWrite: fullSignature(of: merged) != fullSignature(of: remote)
        )
    }

    // MARK: - Internals

    /// `(modifiedAt, deviceID)` lexicographic compare; the exact tie (same
    /// device, same timestamp) does not reach here — the caller picks remote.
    private static func wins(_ lhs: (Date, String), over rhs: (Date, String)) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
        return lhs.1 > rhs.1
    }

    private static func resolve<Payload: Codable & Sendable>(
        _ local: SyncRecord<Payload>,
        _ remote: SyncRecord<Payload>,
        preserveNonEmptyNotes: Bool
    ) -> SyncRecord<Payload> {
        let localWins = wins((local.modifiedAt, local.deviceID), over: (remote.modifiedAt, remote.deviceID))
        let tie = local.modifiedAt == remote.modifiedAt && local.deviceID == remote.deviceID
        let winner = (localWins && !tie) ? local : remote
        let loser = (localWins && !tie) ? remote : local
        if winner.isTombstone {
            return SyncRecord(id: winner.id, modifiedAt: winner.modifiedAt, deviceID: winner.deviceID, deletedAt: winner.deletedAt)
        }
        var record = normalized(winner)
        // The only field-level rule in the design: when this device strips
        // notes from its outgoing envelope, an empty winner notes must not
        // wipe the loser's non-empty notes — otherwise applying a stripped
        // remote winner would erase the local remarks.
        if preserveNonEmptyNotes, let winnerPayload = record.payload, let loserPayload = loser.payload,
           let winnerCarrier = winnerPayload as? SyncNotesCarrier,
           let loserCarrier = loserPayload as? SyncNotesCarrier,
           winnerCarrier.syncNotes.isEmpty, !loserCarrier.syncNotes.isEmpty,
           let preserved = winnerCarrier.withSyncNotes(loserCarrier.syncNotes) as? Payload {
            record.payload = preserved
        }
        return record
    }

    /// Tombstones carry no payload on the wire; normalize records that arrive
    /// with both set so downstream equality and re-encoding stay stable.
    private static func normalized<Payload: Codable & Sendable>(_ record: SyncRecord<Payload>) -> SyncRecord<Payload> {
        guard record.isTombstone, record.payload != nil else { return record }
        return SyncRecord(id: record.id, modifiedAt: record.modifiedAt, deviceID: record.deviceID, deletedAt: record.deletedAt)
    }

    /// Live records' `(id, modifiedAt, deviceID)` plus the order — everything
    /// that changes what a store would display. Tombstone-only differences do
    /// not require a local apply.
    private static func liveSignature<Payload>(of collection: SyncCollection<Payload>) -> [LiveEntry] {
        collection.records
            .filter { !$0.isTombstone }
            .map { LiveEntry(id: $0.id, modifiedAt: $0.modifiedAt, deviceID: $0.deviceID) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            + collection.orderSnapshot.map { LiveEntry(id: $0, modifiedAt: Date(timeIntervalSince1970: 0), deviceID: "") }
    }

    /// All records (incl. tombstones) plus the order clocks — everything the
    /// file must persist. Drives the "should we write back" decision.
    private static func fullSignature<Payload>(of collection: SyncCollection<Payload>) -> [FullEntry] {
        collection.records
            .map { FullEntry(id: $0.id, modifiedAt: $0.modifiedAt, deviceID: $0.deviceID, deletedAt: $0.deletedAt) }
            .sorted { $0.id.uuidString < $1.id.uuidString }
            + collection.orderSnapshot.map {
                FullEntry(id: $0, modifiedAt: collection.orderModifiedAt, deviceID: collection.orderDeviceID, deletedAt: nil)
            }
    }

    private struct LiveEntry: Equatable {
        let id: UUID
        let modifiedAt: Date
        let deviceID: String
    }

    private struct FullEntry: Equatable {
        let id: UUID
        let modifiedAt: Date
        let deviceID: String
        let deletedAt: Date?
    }
}
