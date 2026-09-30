import Foundation
import HarborKit

/// Per-session live port-forward toggle service. Manages which forwards are
/// currently enabled on the active ControlMaster and provides async methods
/// to add/remove them without reconnecting.
@MainActor
final class ForwardingService: ObservableObject {
    /// For each forward (keyed by its id), true if it is currently enabled
    /// on the live ControlMaster connection.
    @Published private(set) var enabled: [UUID: Bool] = [:]

    private let exec: RemoteExec
    /// Snapshot of the session's portForwards at attach time.
    let forwards: [PortForward]
    /// Ad-hoc forwards added to a live session this session (not saved to host).
    @Published private(set) var adHocForwards: [PortForward] = []

    /// True when one or more enable/disable operations are in flight.
    @Published private(set) var busy = false
    /// Per-forward in-flight set so a row can disable itself without relying
    /// on view-local `@State` that resets if the row is recreated.
    @Published private(set) var pendingIDs: Set<UUID> = []
    /// Last operation failure; cleared on the next success or explicit dismiss.
    @Published var lastError: String?
    private var inFlight = 0
    /// Bumped by stop() so a completion after teardown cannot resurrect state.
    private var runID = 0

    init(exec: RemoteExec, forwards: [PortForward]) {
        self.exec = exec
        self.forwards = forwards
        // These rules were supplied in the argv that created this session's
        // ControlMaster.  Treat them as live from the UI's first frame instead
        // of leaving the map empty: otherwise an already-bound forward renders
        // as off and the first toggle attempts to add it a second time.
        self.enabled = Dictionary(
            forwards.map { ($0.id, true) },
            uniquingKeysWith: { existing, _ in existing }
        )
    }

    func isPending(_ id: UUID) -> Bool { pendingIDs.contains(id) }

    func known(_ id: UUID) -> Bool {
        forwards.contains { $0.id == id } || adHocForwards.contains { $0.id == id }
    }

    /// Session teardown / panel hide: drop error banners and in-flight marks.
    /// Live enable map stays — the ControlMaster still holds those forwards
    /// until the SSH session itself dies.
    func stop() {
        runID += 1
        lastError = nil
        busy = false
        inFlight = 0
        pendingIDs = []
    }

    func enableForward(_ forward: PortForward) async -> Bool {
        await mutate(forward, enable: true)
    }

    func disableForward(_ forward: PortForward) async -> Bool {
        await mutate(forward, enable: false)
    }

    func addAdHocForward(_ forward: PortForward) async -> Bool {
        let started = runID
        begin(forward.id)
        defer { end(forward.id) }
        let ok = await exec.enableForward(forward)
        guard started == runID else { return false }
        if ok {
            if !adHocForwards.contains(where: { $0.id == forward.id }) {
                adHocForwards.append(forward)
            }
            enabled[forward.id] = true
            lastError = nil
        } else {
            lastError = L("端口转发启用失败")
        }
        return ok
    }

    func removeAdHocForward(_ forward: PortForward) async {
        let started = runID
        if enabled[forward.id] == true {
            begin(forward.id)
            let ok = await exec.disableForward(forward)
            end(forward.id)
            guard started == runID else { return }
            if !ok {
                lastError = L("端口转发关闭失败")
                return
            }
        }
        guard started == runID else { return }
        adHocForwards.removeAll { $0.id == forward.id }
        enabled.removeValue(forKey: forward.id)
        lastError = nil
    }

    private func mutate(_ forward: PortForward, enable: Bool) async -> Bool {
        guard pendingIDs.insert(forward.id).inserted else { return false }
        let started = runID
        begin(forward.id, alreadyPending: true)
        defer { end(forward.id) }
        let ok = enable
            ? await exec.enableForward(forward)
            : await exec.disableForward(forward)
        guard started == runID else { return false }
        if ok {
            // A deleted ad-hoc row must not come back from a stale completion.
            if known(forward.id) || !enable {
                enabled[forward.id] = enable
            }
            lastError = nil
        } else {
            lastError = enable ? L("端口转发启用失败") : L("端口转发关闭失败")
        }
        return ok
    }

    private func begin(_ id: UUID, alreadyPending: Bool = false) {
        if !alreadyPending { pendingIDs.insert(id) }
        inFlight += 1
        busy = true
    }

    private func end(_ id: UUID) {
        pendingIDs.remove(id)
        inFlight = max(0, inFlight - 1)
        busy = inFlight > 0
    }
}
