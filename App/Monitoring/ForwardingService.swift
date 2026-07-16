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
    /// Last operation failure; cleared on the next success. Surfaced by TunnelView.
    @Published var lastError: String?
    private var inFlight = 0

    init(exec: RemoteExec, forwards: [PortForward]) {
        self.exec = exec
        self.forwards = forwards
    }

    func enableForward(_ forward: PortForward) async -> Bool {
        inFlight += 1; busy = true
        defer { inFlight -= 1; busy = inFlight > 0 }
        let ok = await exec.enableForward(forward)
        if ok { enabled[forward.id] = true; lastError = nil }
        else { lastError = L("端口转发启用失败") }
        return ok
    }

    func disableForward(_ forward: PortForward) async -> Bool {
        inFlight += 1; busy = true
        defer { inFlight -= 1; busy = inFlight > 0 }
        let ok = await exec.disableForward(forward)
        if ok { enabled[forward.id] = false; lastError = nil }
        else { lastError = L("端口转发关闭失败") }
        return ok
    }

    func addAdHocForward(_ forward: PortForward) async -> Bool {
        inFlight += 1; busy = true
        defer { inFlight -= 1; busy = inFlight > 0 }
        let ok = await exec.enableForward(forward)
        if ok {
            adHocForwards.append(forward)
            enabled[forward.id] = true
            lastError = nil
        } else {
            lastError = L("端口转发启用失败")
        }
        return ok
    }

    func removeAdHocForward(_ forward: PortForward) async {
        if enabled[forward.id] == true {
            inFlight += 1; busy = true
            let ok = await exec.disableForward(forward)
            inFlight -= 1; busy = inFlight > 0
            if !ok {
                lastError = L("端口转发关闭失败")
                return
            }
        }
        adHocForwards.removeAll { $0.id == forward.id }
        enabled.removeValue(forKey: forward.id)
    }
}
