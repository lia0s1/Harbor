import XCTest
@testable import HarborKit

final class QuickCommandTests: XCTestCase {

    // MARK: - displayTitle

    func testDisplayTitleUsesTitleWhenPresent() {
        let cmd = QuickCommand(title: "Restart nginx", command: "systemctl restart nginx")
        XCTAssertEqual(cmd.displayTitle, "Restart nginx")
    }

    func testDisplayTitleFallsBackToCommandWhenTitleBlank() {
        let cmd = QuickCommand(title: "   ", command: "df -h")
        XCTAssertEqual(cmd.displayTitle, "df -h")
    }

    // MARK: - Parameter parsing

    func testNoPlaceholdersMeansNoParameters() {
        let cmd = QuickCommand(command: "df -h")
        XCTAssertEqual(cmd.parameters, [])
        XCTAssertFalse(cmd.hasParameters)
    }

    func testSinglePlaceholderIsDetected() {
        let cmd = QuickCommand(command: "systemctl restart {service}")
        XCTAssertEqual(cmd.parameters, ["service"])
        XCTAssertTrue(cmd.hasParameters)
    }

    func testMultiplePlaceholdersKeepFirstAppearanceOrder() {
        let cmd = QuickCommand(command: "scp {src} {host}:{dst}")
        XCTAssertEqual(cmd.parameters, ["src", "host", "dst"])
    }

    func testDuplicatePlaceholdersDeduplicatedButOrderPreserved() {
        let cmd = QuickCommand(command: "tar -czf {name}.tgz {name}/")
        XCTAssertEqual(cmd.parameters, ["name"])
    }

    func testPlaceholderNamesAllowDigitsUnderscoreAndDash() {
        let cmd = QuickCommand(command: "echo {arg_1} {arg-2} {ARG3}")
        XCTAssertEqual(cmd.parameters, ["arg_1", "arg-2", "ARG3"])
    }

    func testCJKPlaceholderNamesSupported() {
        let cmd = QuickCommand(command: "systemctl restart {服务}")
        XCTAssertEqual(cmd.parameters, ["服务"])
    }

    func testShellVariableIsNotTreatedAsPlaceholder() {
        // ${HOME} and bare $VAR must NOT become a parameter prompt.
        let cmd = QuickCommand(command: "echo ${HOME} and $PATH and {real}")
        XCTAssertEqual(cmd.parameters, ["real"])
    }

    func testEmptyBracesAndBraceExpansionIgnored() {
        // {} is empty; {a,b} contains a comma which is not a name character.
        let cmd = QuickCommand(command: "echo {} cp file.{txt,md} {dir}")
        XCTAssertEqual(cmd.parameters, ["dir"])
    }

    func testUnterminatedBraceIgnored() {
        let cmd = QuickCommand(command: "echo {oops and {ok}")
        XCTAssertEqual(cmd.parameters, ["ok"])
    }

    // MARK: - Substitution

    func testSubstituteFillsPlaceholder() {
        let cmd = QuickCommand(command: "systemctl restart {service}")
        XCTAssertEqual(cmd.substitute(["service": "nginx"]), "systemctl restart nginx")
    }

    func testSubstituteFillsMultipleAndRepeated() {
        let cmd = QuickCommand(command: "tar -czf {name}.tgz {name}/")
        XCTAssertEqual(cmd.substitute(["name": "backup"]), "tar -czf backup.tgz backup/")
    }

    func testSubstituteMissingValueBecomesEmptyString() {
        let cmd = QuickCommand(command: "kill -9 {pid}")
        XCTAssertEqual(cmd.substitute([:]), "kill -9 ")
    }

    func testSubstitutePreservesShellVariablesAndBraceExpansion() {
        let cmd = QuickCommand(command: "echo ${HOME}/{dir} {a,b}")
        XCTAssertEqual(cmd.substitute(["dir": "logs"]), "echo ${HOME}/logs {a,b}")
    }

    func testSubstituteWithNoPlaceholdersReturnsTemplate() {
        let cmd = QuickCommand(command: "df -h")
        XCTAssertEqual(cmd.substitute(["x": "y"]), "df -h")
    }

    func testSubstituteValueContainingSpacesAndSpecialCharsKeptVerbatim() {
        // No shell quoting is applied — the command is sent to an interactive shell.
        let cmd = QuickCommand(command: "echo {msg}")
        XCTAssertEqual(cmd.substitute(["msg": "hello world; rm -rf x"]),
                       "echo hello world; rm -rf x")
    }

    func testSubstituteValueContainingBracesDoesNotRecurse() {
        let cmd = QuickCommand(command: "run {a}")
        XCTAssertEqual(cmd.substitute(["a": "{b}"]), "run {b}")
    }
}
