#if os(macOS)
import Darwin
import Dispatch
import Testing
@testable import SwiftTerm

/// Exercises LocalProcess's delivery queue without spawning a PTY.  The first
/// delegate callback is deliberately held so input can outpace delivery; the
/// process must cap its retained queue and emit one explicit loss marker after
/// the backlog is released.
final class LocalProcessBackpressureTests {
    private final class BlockingDelegate: LocalProcessDelegate {
        let firstChunkStarted = DispatchSemaphore(value: 0)
        let releaseFirstChunk = DispatchSemaphore(value: 0)
        let sawDropMarker = DispatchSemaphore(value: 0)
        private var shouldBlock = true

        func processTerminated(_ source: LocalProcess, exitCode: Int32?) {}

        func dataReceived(slice: ArraySlice<UInt8>) {
            if shouldBlock {
                shouldBlock = false
                firstChunkStarted.signal()
                releaseFirstChunk.wait()
            }
            if Array(slice) == LocalProcess.droppedOutputMarker {
                sawDropMarker.signal()
            }
        }

        func getWindowSize() -> winsize { winsize() }
    }

    @Test func testPendingOutputBacklogIsBoundedAndMarked() {
        let delegate = BlockingDelegate()
        let deliveryQueue = DispatchQueue(label: "LocalProcessBackpressureTests.delivery")
        let process = LocalProcess(delegate: delegate, dispatchQueue: deliveryQueue)
        let chunk = [UInt8](repeating: 0x41, count: 128 * 1024)

        // Hold the first delivery on the delegate queue, then submit more than
        // the eight-MiB cap from the simulated DispatchIO read queue.
        chunk.withUnsafeBytes { bytes in
            process.childProcessRead(done: false, data: DispatchData(bytes: bytes), errno: 0)
        }
        #expect(delegate.firstChunkStarted.wait(timeout: .now() + 1) == .success)

        for _ in 0..<80 {
            chunk.withUnsafeBytes { bytes in
                process.childProcessRead(done: false, data: DispatchData(bytes: bytes), errno: 0)
            }
        }

        delegate.releaseFirstChunk.signal()
        #expect(delegate.sawDropMarker.wait(timeout: .now() + 5) == .success)
        withExtendedLifetime(process) {}
    }
}
#endif
