import Foundation
import HarborKit

/// One session's auxiliary-exec channel: short-lived ssh/sftp commands that
/// piggyback on the session's ControlMaster socket (BatchMode — they reuse
/// the live connection and never prompt). Shared by monitoring and the file
/// panel.
struct RemoteExec: Sendable {
    /// `[user@]host`, exactly as the main session passed it to ssh.
    let destination: String
    /// Fully expanded socket path (no %C/%h tokens).
    let controlSocketPath: String
    let port: Int

    /// `ssh -O check`: true when the master at the socket is alive, so
    /// auxiliary commands will multiplex over it.
    func checkSocket(timeout: TimeInterval = 5) async -> Bool {
        let argv = SSHCommandBuilder.controlCheckCommand(
            controlSocketPath: controlSocketPath,
            destination: destination
        )
        let result = await AuxProcess.run(argv: argv, timeout: timeout)
        return !result.timedOut && result.exitCode == 0
    }

    /// Runs one remote script (always a single argv element; the remote
    /// shell parses it) over the multiplexed connection.
    func run(_ remoteScript: String, timeout: TimeInterval = 5) async -> AuxProcess.Output {
        let argv = SSHCommandBuilder.auxiliaryCommand(
            controlSocketPath: controlSocketPath,
            destination: destination,
            remoteScript: remoteScript,
            port: port
        )
        return await AuxProcess.run(argv: argv, timeout: timeout)
    }

    /// Enables a port forward on the live ControlMaster connection. Uses
    /// `ssh -S <socket> -O forward -L/-R/-D <spec> <dest>` so the forward
    /// is added without reconnecting. Returns true on success (exit 0).
    func enableForward(_ forward: PortForward, timeout: TimeInterval = 10) async -> Bool {
        guard let argv = try? SSHCommandBuilder.controlForwardCommand(
            controlSocketPath: controlSocketPath,
            destination: destination,
            forward: forward
        ) else { return false }
        let result = await AuxProcess.run(argv: argv, timeout: timeout)
        return !result.timedOut && result.exitCode == 0
    }

    /// Removes a port forward from the live ControlMaster connection. Uses
    /// `ssh -S <socket> -O cancel -L/-R/-D <spec> <dest>` so the forward
    /// is removed without reconnecting. Returns true on success (exit 0).
    func disableForward(_ forward: PortForward, timeout: TimeInterval = 10) async -> Bool {
        guard let argv = try? SSHCommandBuilder.controlCancelForwardCommand(
            controlSocketPath: controlSocketPath,
            destination: destination,
            forward: forward
        ) else { return false }
        let result = await AuxProcess.run(argv: argv, timeout: timeout)
        return !result.timedOut && result.exitCode == 0
    }

    /// Runs an sftp batch (one command per line, built with `SFTPBatch`) over
    /// the multiplexed connection, fed via stdin.
    func runSFTPBatch(_ batch: String, timeout: TimeInterval) async -> AuxProcess.Output {
        let argv = SSHCommandBuilder.sftpBatchCommand(
            controlSocketPath: controlSocketPath,
            destination: destination,
            port: port
        )
        let payload = batch.hasSuffix("\n") ? batch : batch + "\n"
        return await AuxProcess.run(argv: argv, stdin: Data(payload.utf8), timeout: timeout)
    }
}
