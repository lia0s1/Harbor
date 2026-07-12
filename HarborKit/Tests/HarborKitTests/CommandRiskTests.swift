import XCTest
@testable import HarborKit

final class CommandRiskTests: XCTestCase {
    func testDetectsDestructiveFileCommands() {
        XCTAssertEqual(CommandRiskDetector.detect(in: "sudo rm -rf /var/cache"), .destructiveFiles)
        XCTAssertEqual(CommandRiskDetector.detect(in: "mkfs.ext4 /dev/sdb"), .destructiveFiles)
    }

    func testDetectsSystemAndProcessLifecycleCommands() {
        XCTAssertEqual(CommandRiskDetector.detect(in: "systemctl restart nginx"), .systemLifecycle)
        XCTAssertEqual(CommandRiskDetector.detect(in: "service nginx stop"), .systemLifecycle)
        XCTAssertEqual(CommandRiskDetector.detect(in: "kill -9 123"), .processTermination)
    }

    func testDetectsContainerAndClusterDeletion() {
        XCTAssertEqual(CommandRiskDetector.detect(in: "docker system prune -af"), .containerOrClusterDeletion)
        XCTAssertEqual(CommandRiskDetector.detect(in: "kubectl delete pod api-1"), .containerOrClusterDeletion)
    }

    func testLeavesRoutineCommandsUntouched() {
        XCTAssertNil(CommandRiskDetector.detect(in: "journalctl -u nginx -f"))
        XCTAssertNil(CommandRiskDetector.detect(in: "docker ps"))
    }
}
