import XCTest
@testable import HarborKit

/// SyncMerger is a pure function; these tests pin its convergence semantics:
/// LWW with deviceID tiebreak, tombstone propagation + GC, order LWW, the
/// notes carve-out, and idempotency.
final class SyncMergerTests: XCTestCase {
    private let deviceA = "device-AAA"
    private let deviceB = "device-BBB"

    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Record and payload share the id, exactly as the engine builds them.
    private func hostRecord(
        _ id: UUID, _ name: String, notes: String = "", at t: Date, device: String
    ) -> SyncRecord<SSHHost> {
        let host = SSHHost(id: id, name: name, hostname: "\(name).example.com", username: "root", notes: notes)
        return SyncRecord(id: id, modifiedAt: t, deviceID: device, payload: host)
    }

    private func tombstone<Payload: Codable & Sendable>(
        _ id: UUID, of type: Payload.Type, at t: Date, device: String
    ) -> SyncRecord<Payload> {
        SyncRecord(id: id, modifiedAt: t, deviceID: device, deletedAt: t)
    }

    private func collection<Payload: Codable & Sendable>(
        _ records: [SyncRecord<Payload>], order: [UUID], orderAt: Date, orderDevice: String
    ) -> SyncCollection<Payload> {
        SyncCollection(orderSnapshot: order, orderModifiedAt: orderAt, orderDeviceID: orderDevice, records: records)
    }

    // MARK: - Convergence

    /// Both devices edit different records concurrently: the merge must
    /// contain both edits and be identical regardless of argument order.
    func testConcurrentEditsOnDifferentRecordsConverge() {
        let id1 = UUID(), id2 = UUID()
        let local = collection(
            [hostRecord(id1, "one", notes: "edited on A", at: t0 + 2, device: deviceA)],
            order: [id1], orderAt: t0, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id2, "two", at: t0 + 3, device: deviceB)],
            order: [id2], orderAt: t0, orderDevice: deviceB
        )

        let forward = SyncMerger.merge(local: local, remote: remote, now: t0 + 4)
        let reverse = SyncMerger.merge(local: remote, remote: local, now: t0 + 4)

        XCTAssertEqual(Set(forward.orderedItems.map(\.id)), [id1, id2])
        XCTAssertEqual(forward.orderedItems.first(where: { $0.id == id1 })?.notes, "edited on A")
        XCTAssertEqual(
            forward.merged.records.map { "\($0.id)|\($0.modifiedAt)|\($0.deviceID)" },
            reverse.merged.records.map { "\($0.id)|\($0.modifiedAt)|\($0.deviceID)" },
            "merge must converge regardless of local/remote argument order"
        )
        XCTAssertEqual(forward.merged.orderSnapshot, reverse.merged.orderSnapshot)
        XCTAssertEqual(forward.orderedItems, reverse.orderedItems)
        XCTAssertTrue(forward.localNeedsApply)
        XCTAssertTrue(forward.remoteNeedsWrite)
    }

    /// Same record edited on both sides: the later timestamp wins, whichever
    /// side of the merge it started on.
    func testSameRecordLaterTimestampWinsBothDirections() {
        let id = UUID()
        let older = collection([hostRecord(id, "old", at: t0, device: deviceA)], order: [id], orderAt: t0, orderDevice: deviceA)
        let newer = collection([hostRecord(id, "new", at: t0 + 10, device: deviceB)], order: [id], orderAt: t0, orderDevice: deviceA)

        let forward = SyncMerger.merge(local: older, remote: newer, now: t0 + 20)
        let reverse = SyncMerger.merge(local: newer, remote: older, now: t0 + 20)

        XCTAssertEqual(forward.orderedItems.first?.name, "new")
        XCTAssertEqual(reverse.orderedItems.first?.name, "new")
        XCTAssertEqual(forward.orderedItems, reverse.orderedItems)
    }

    /// Identical timestamps resolve by deviceID lexicographic order so every
    /// device converges to the same winner even under clock skew.
    func testEqualTimestampDeviceIDTiebreakIsDeterministic() {
        let id = UUID()
        let fromA = collection([hostRecord(id, "from-A", at: t0, device: deviceA)], order: [id], orderAt: t0, orderDevice: deviceA)
        let fromB = collection([hostRecord(id, "from-B", at: t0, device: deviceB)], order: [id], orderAt: t0, orderDevice: deviceB)

        let forward = SyncMerger.merge(local: fromA, remote: fromB, now: t0 + 1)
        let reverse = SyncMerger.merge(local: fromB, remote: fromA, now: t0 + 1)

        // device-BBB > device-AAA lexicographically, so B wins on both sides.
        XCTAssertEqual(forward.orderedItems.first?.name, "from-B")
        XCTAssertEqual(reverse.orderedItems.first?.name, "from-B")
    }

    // MARK: - Tombstones

    /// A newer delete beats an older edit: the item disappears from the
    /// ordered output and the merged record is a payload-less tombstone.
    func testDeletePropagatesOverOlderEdit() {
        let id = UUID()
        let local = collection(
            [tombstone(id, of: SSHHost.self, at: t0 + 5, device: deviceA)],
            order: [], orderAt: t0 + 5, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id, "still-alive", at: t0, device: deviceB)],
            order: [id], orderAt: t0, orderDevice: deviceB
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 6)

        XCTAssertTrue(result.orderedItems.isEmpty)
        XCTAssertEqual(result.merged.records.count, 1)
        XCTAssertTrue(result.merged.records[0].isTombstone)
        XCTAssertNil(result.merged.records[0].payload, "tombstones must not carry a payload")
        XCTAssertTrue(result.remoteNeedsWrite, "the delete must be written back so it propagates")
    }

    /// A newer live edit beats an older tombstone (re-adding a host on another
    /// device resurrects the id).
    func testNewerEditResurrectsDeletedRecord() {
        let id = UUID()
        let local = collection(
            [tombstone(id, of: SSHHost.self, at: t0, device: deviceA)],
            order: [], orderAt: t0, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id, "recreated", at: t0 + 9, device: deviceB)],
            order: [id], orderAt: t0 + 9, orderDevice: deviceB
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 10)

        XCTAssertEqual(result.orderedItems.map(\.name), ["recreated"])
        XCTAssertFalse(result.merged.records[0].isTombstone)
        XCTAssertTrue(result.localNeedsApply)
    }

    /// Tombstones older than the 30-day horizon are physically dropped on the
    /// next write; younger ones survive.
    func testTombstoneGarbageCollection() {
        let oldID = UUID(), recentID = UUID(), liveID = UUID()
        let local = collection(
            [
                tombstone(oldID, of: SSHHost.self, at: t0, device: deviceA),
                tombstone(recentID, of: SSHHost.self, at: t0 + 29 * 24 * 3600, device: deviceA),
                hostRecord(liveID, "live", at: t0, device: deviceA),
            ],
            order: [liveID], orderAt: t0, orderDevice: deviceA
        )
        let now = t0 + 31 * 24 * 3600

        let result = SyncMerger.merge(local: local, remote: .empty, now: now)

        XCTAssertEqual(Set(result.merged.records.map(\.id)), [recentID, liveID],
                       "the 31-day-old tombstone must be collected, the 29-day-old kept")
        XCTAssertTrue(result.remoteNeedsWrite)
        // Merging the GC'd result against the original local must not bring
        // the collected tombstone back: local's copy is equally old and gets
        // collected in that merge too.
        let remerge = SyncMerger.merge(local: result.merged, remote: local, now: now)
        XCTAssertEqual(Set(remerge.merged.records.map(\.id)), [recentID, liveID])
    }

    // MARK: - First-sync guards

    /// An empty local section must never erase a populated remote: the merged
    /// result is the remote's content and only the local side applies.
    func testEmptyLocalDoesNotOverwritePopulatedRemote() {
        let id1 = UUID(), id2 = UUID()
        let remote = collection(
            [hostRecord(id1, "a", at: t0, device: deviceB), hostRecord(id2, "b", at: t0, device: deviceB)],
            order: [id1, id2], orderAt: t0, orderDevice: deviceB
        )

        let result = SyncMerger.merge(local: .empty, remote: remote, now: t0 + 1)

        XCTAssertEqual(result.orderedItems.count, 2)
        XCTAssertTrue(result.localNeedsApply)
        XCTAssertFalse(result.remoteNeedsWrite, "merging an empty local against the remote must not rewrite the file")
    }

    /// The mirror image: populated local, empty remote → local pushes, no
    /// local apply needed.
    func testEmptyRemoteTakesFullLocalPush() {
        let id = UUID()
        let local = collection(
            [hostRecord(id, "mine", at: t0, device: deviceA)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )

        let result = SyncMerger.merge(local: local, remote: .empty, now: t0 + 1)

        XCTAssertEqual(result.orderedItems.map(\.name), ["mine"])
        XCTAssertFalse(result.localNeedsApply)
        XCTAssertTrue(result.remoteNeedsWrite)
    }

    /// Both empty: nothing to do, no writes, no applies.
    func testBothEmptyIsQuiet() {
        let result = SyncMerger.merge(local: SyncCollection<SSHHost>.empty, remote: .empty, now: t0)
        XCTAssertTrue(result.orderedItems.isEmpty)
        XCTAssertFalse(result.localNeedsApply)
        XCTAssertFalse(result.remoteNeedsWrite)
    }

    // MARK: - Idempotency

    /// merge(merge(L, R), R) must produce the same merged section — an
    /// unchanged remote never undoes convergence.
    func testMergeConvergesAgainstUnchangedRemote() {
        let id1 = UUID(), id2 = UUID(), id3 = UUID()
        let local = collection(
            [
                hostRecord(id1, "one", notes: "local edit", at: t0 + 3, device: deviceA),
                tombstone(id2, of: SSHHost.self, at: t0 + 4, device: deviceA),
            ],
            order: [id1], orderAt: t0 + 4, orderDevice: deviceA
        )
        let remote = collection(
            [
                hostRecord(id1, "one", at: t0, device: deviceB),
                hostRecord(id2, "two", at: t0, device: deviceB),
                hostRecord(id3, "three", at: t0 + 2, device: deviceB),
            ],
            order: [id2, id1, id3], orderAt: t0, orderDevice: deviceB
        )
        let now = t0 + 10

        let once = SyncMerger.merge(local: local, remote: remote, now: now)
        let twice = SyncMerger.merge(local: once.merged, remote: remote, now: now)

        XCTAssertEqual(
            once.merged.records.map { "\($0.id)|\($0.modifiedAt)|\($0.deviceID)|\($0.deletedAt != nil)" },
            twice.merged.records.map { "\($0.id)|\($0.modifiedAt)|\($0.deviceID)|\($0.deletedAt != nil)" }
        )
        XCTAssertEqual(once.merged.orderSnapshot, twice.merged.orderSnapshot)
        XCTAssertEqual(once.orderedItems, twice.orderedItems)
        // The remote was never written back, so it still lags the merged
        // result and a write remains necessary — that is the correct signal.
        XCTAssertTrue(twice.remoteNeedsWrite)
    }

    /// Once both sides hold the merged section, merging is a fixpoint with no
    /// apply and no write.
    func testMergedResultIsFixpoint() {
        let id1 = UUID(), id2 = UUID()
        let local = collection(
            [hostRecord(id1, "one", at: t0 + 3, device: deviceA)],
            order: [id1], orderAt: t0 + 3, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id2, "two", at: t0 + 2, device: deviceB)],
            order: [id2], orderAt: t0 + 2, orderDevice: deviceB
        )

        let once = SyncMerger.merge(local: local, remote: remote, now: t0 + 10)
        let fixpoint = SyncMerger.merge(local: once.merged, remote: once.merged, now: t0 + 11)

        XCTAssertEqual(fixpoint.orderedItems, once.orderedItems)
        XCTAssertFalse(fixpoint.localNeedsApply)
        XCTAssertFalse(fixpoint.remoteNeedsWrite)
    }

    // MARK: - Order

    /// The newer order clock's snapshot wins; ids it doesn't know append in
    /// id order; dead snapshot entries drop out.
    func testOrderLWWAndNewIDsAppendSorted() {
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let dead = UUID()

        let local = collection(
            [hostRecord(id1, "one", at: t0, device: deviceA)],
            order: [id1], orderAt: t0 + 5, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id1, "one", at: t0, device: deviceA),
             hostRecord(id2, "two", at: t0, device: deviceB),
             hostRecord(id3, "three", at: t0, device: deviceB)],
            order: [id3, dead, id2], orderAt: t0, orderDevice: deviceB
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 6)

        // Local has the newer order clock, so its snapshot [id1] leads; id2
        // and id3 (new to it) append in uuidString order; `dead` never appears.
        XCTAssertEqual(result.merged.orderSnapshot, [id1, id2, id3])
        XCTAssertEqual(result.orderedItems.map(\.id), [id1, id2, id3])
    }

    // MARK: - Notes carve-out

    /// With the notes-strip preference on, an empty winner notes must not
    /// erase the loser's non-empty notes.
    func testNotesEmptyDoesNotOverwriteNonEmptyWhenPreserving() {
        let id = UUID()
        let local = collection(
            [hostRecord(id, "h", notes: "本机备注", at: t0, device: deviceA)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )
        // Remote is the stripped winner: newer, notes blanked.
        let remote = collection(
            [hostRecord(id, "h", notes: "", at: t0 + 1, device: deviceB)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 2, preserveNonEmptyNotes: true)

        XCTAssertEqual(result.orderedItems.first?.name, "h")
        XCTAssertEqual(result.orderedItems.first?.notes, "本机备注")
    }

    /// Without the preference the plain LWW applies: the winner's empty notes
    /// clears the field (deliberate note-clearing must be able to propagate).
    func testNotesEmptyOverwritesWhenNotPreserving() {
        let id = UUID()
        let local = collection(
            [hostRecord(id, "h", notes: "本机备注", at: t0, device: deviceA)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id, "h", notes: "", at: t0 + 1, device: deviceB)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 2, preserveNonEmptyNotes: false)

        XCTAssertEqual(result.orderedItems.first?.notes, "")
    }

    /// The carve-out only fills blanks; a non-empty winner notes is untouched.
    func testNotesNonEmptyWinnerUntouched() {
        let id = UUID()
        let local = collection(
            [hostRecord(id, "h", notes: "old", at: t0, device: deviceA)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )
        let remote = collection(
            [hostRecord(id, "h", notes: "new", at: t0 + 1, device: deviceB)],
            order: [id], orderAt: t0, orderDevice: deviceA
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 2, preserveNonEmptyNotes: true)

        XCTAssertEqual(result.orderedItems.first?.notes, "new")
    }

    // MARK: - Generality & encoding

    /// The merger is payload-agnostic: run the core scenario over a second
    /// model type (QuickCommand) to prove nothing is SSHHost-specific.
    func testMergeWorksForQuickCommandPayloads() {
        let id = UUID()
        let local = collection(
            [SyncRecord(id: id, modifiedAt: t0, deviceID: deviceA,
                        payload: QuickCommand(id: id, title: "old", command: "ls"))],
            order: [id], orderAt: t0, orderDevice: deviceA
        )
        let remote = collection(
            [SyncRecord(id: id, modifiedAt: t0 + 1, deviceID: deviceB,
                        payload: QuickCommand(id: id, title: "new", command: "ls -la"))],
            order: [id], orderAt: t0, orderDevice: deviceA
        )

        let result = SyncMerger.merge(local: local, remote: remote, now: t0 + 2)

        XCTAssertEqual(result.orderedItems.map(\.title), ["new"])
    }

    /// Envelope models round-trip through JSON with the app's ISO8601 date
    /// strategy, tombstone included.
    func testCollectionCodableRoundTrip() throws {
        let id = UUID(), goneID = UUID()
        let section = SyncCollection(
            orderSnapshot: [id],
            orderModifiedAt: t0,
            orderDeviceID: deviceA,
            records: [
                hostRecord(id, "h", notes: "n", at: t0, device: deviceA),
                tombstone(goneID, of: SSHHost.self, at: t0 + 1, device: deviceB),
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(section)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(SyncCollection<SSHHost>.self, from: data)

        XCTAssertEqual(decoded.records.count, 2)
        XCTAssertEqual(decoded.orderSnapshot, [id])
        XCTAssertEqual(decoded.records.first(where: { $0.id == goneID })?.isTombstone, true)
        XCTAssertNil(decoded.records.first(where: { $0.id == goneID })?.payload)
        XCTAssertEqual(decoded.records.first(where: { $0.id == id })?.payload?.notes, "n")
    }
}
