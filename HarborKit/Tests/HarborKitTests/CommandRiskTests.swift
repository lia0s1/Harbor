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

    func testTokenAwareDetectorHandlesOptionsWhitespaceAndWrappers() {
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "docker    system     prune -af"),
            .containerOrClusterDeletion
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "docker --context production system prune --all"),
            .containerOrClusterDeletion
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "sudo systemctl --system restart sshd"),
            .systemLifecycle
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "kill -s KILL 123"),
            .processTermination
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "kill --signal=SIGKILL 123"),
            .processTermination
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "env TMPDIR=/tmp rm -fr cache"),
            .destructiveFiles
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "sh -c 'kubectl delete pod api-1'"),
            .containerOrClusterDeletion
        )
    }

    func testQuoteAndCommentTextDoesNotBecomeACommand() {
        XCTAssertNil(CommandRiskDetector.detect(in: "echo 'rm -rf /'"))
        XCTAssertNil(CommandRiskDetector.detect(in: "printf '%s\\n' 'docker system prune'"))
        XCTAssertNil(CommandRiskDetector.detect(in: "# systemctl --system restart sshd"))
        XCTAssertNil(CommandRiskDetector.detect(in: "docker run --rm example/image"))
    }

    func testSeparatorsAndCommandSubstitutionsStillInspectExecutedCommands() {
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "printf ready && docker system prune -af"),
            .containerOrClusterDeletion
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "echo $(kill -s KILL 123)"),
            .processTermination
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "echo \"$(rm -rf /tmp/example)\""),
            .destructiveFiles
        )
        XCTAssertEqual(
            CommandRiskDetector.detect(in: "echo \"`docker system prune -af`\""),
            .containerOrClusterDeletion
        )
    }

    func testCoordinatorRequiresConfirmationForDetectedRiskOnly() {
        XCTAssertEqual(
            CommandExecutionCoordinator.decision(for: "kill -s KILL 123"),
            .requiresConfirmation(.processTermination)
        )
        XCTAssertEqual(CommandExecutionCoordinator.decision(for: "docker ps"), .execute)
    }
}
