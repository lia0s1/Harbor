import Foundation
import HarborKit

/// Tracks which of a host's tunnels are live on the active ControlMaster and
/// applies enable/disable over that connection without reconnecting. Also
/// builds the combined `-L`/`-R`/`-D` argv for connect time.
///
/// Lightweight by design: status only changes in response to explicit
/// activate/deactivate (or setStatus) calls — there is no timer and no
/// background polling of the socket.
@MainActor
final class TunnelManager: ObservableObject {
    enum Status: Equatable {
        case inactive
        /// An add/remove over the live connection is in flight.
        case activating
        case active
        case failed
    }

    /// Live status per tunnel id. A missing id means `.inactive`.
    @Published private(set) var statuses: [UUID: Status] = [:]

    func status(for id: UUID) -> Status { statuses[id] ?? .inactive }
    func isActive(_ id: UUID) -> Bool { status(for: id) == .active }

    /// Directly sets a tunnel's status (for callers that drive activation
    /// through their own mechanism instead of `activate(_:using:)`).
    func setStatus(_ status: Status, for id: UUID) {
        statuses[id] = status
    }

    /// Drops a tunnel's tracked status — call when the configuration is deleted.
    func forget(_ id: UUID) {
        statuses.removeValue(forKey: id)
    }

    /// Clears all live status, e.g. when the session disconnects. Does not
    /// touch the remote: the connection carrying the forwards is already gone.
    func markAllInactive() {
        statuses.removeAll()
    }

    // MARK: - Connect-time arguments

    /// Combined ssh argv (`-L`/`-R`/`-D` …) for every ENABLED tunnel, built
    /// through the app's single injection-safe builder. Invalid rows are
    /// skipped so one malformed tunnel never blocks the whole connection.
    func connectArguments(for tunnels: [TunnelConfiguration]) -> [String] {
        tunnels
            .filter(\.enabled)
            .compactMap { try? SSHCommandBuilder.forwardArguments(for: $0.portForward) }
            .flatMap { $0 }
    }

    /// Argv for a single tunnel; throws the same `SSHCommandError` the host
    /// editor surfaces, so the editor can validate a row before saving.
    static func arguments(for tunnel: TunnelConfiguration) throws -> [String] {
        try SSHCommandBuilder.forwardArguments(for: tunnel.portForward)
    }

    // MARK: - Live control (over a running session's ControlMaster)

    /// Adds the tunnel to the live connection (`ssh -O forward`). Records
    /// `.active` on success and `.failed` otherwise; returns success.
    /// Idempotent against concurrent calls: returns immediately if an activation
    /// is already in-flight (`.activating`) or already succeeded (`.active`).
    @discardableResult
    func activate(_ tunnel: TunnelConfiguration, using exec: RemoteExec) async -> Bool {
        switch statuses[tunnel.id] {
        case .activating: return false   // in-flight; second caller yields
        case .active:     return true    // already up; nothing to do
        default:          break
        }
        statuses[tunnel.id] = .activating
        let ok = await exec.enableForward(tunnel.portForward)
        statuses[tunnel.id] = ok ? .active : .failed
        return ok
    }

    /// Removes the tunnel from the live connection (`ssh -O cancel`). Marks it
    /// `.inactive` on success; leaves the prior status untouched on failure.
    @discardableResult
    func deactivate(_ tunnel: TunnelConfiguration, using exec: RemoteExec) async -> Bool {
        let ok = await exec.disableForward(tunnel.portForward)
        if ok { statuses[tunnel.id] = .inactive }
        return ok
    }

    /// Brings every enabled tunnel up on a freshly-connected session.
    func activateEnabled(_ tunnels: [TunnelConfiguration], using exec: RemoteExec) async {
        for tunnel in tunnels where tunnel.enabled {
            await activate(tunnel, using: exec)
        }
    }
}
