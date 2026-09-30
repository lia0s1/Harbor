import Foundation

/// Local-only command safety classification used by Harbor's confirmation UI.
/// This is a guardrail, not a shell parser or a policy-enforcement mechanism:
/// the user can still deliberately run any command after confirming it.
public enum CommandRisk: String, Equatable, Sendable {
    case destructiveFiles
    case systemLifecycle
    case processTermination
    case containerOrClusterDeletion

    public var summary: String {
        switch self {
        case .destructiveFiles: return "可能删除或覆盖文件"
        case .systemLifecycle: return "可能重启、关机或停止服务"
        case .processTermination: return "可能强制结束进程"
        case .containerOrClusterDeletion: return "可能删除容器或集群资源"
        }
    }
}

/// The one decision every UI command-execution entry point must make before it
/// writes a command to a terminal. Keeping the decision in HarborKit makes the
/// policy independently testable and prevents UI surfaces from growing subtly
/// different detector branches.
public enum CommandExecutionDecision: Equatable, Sendable {
    case execute
    case requiresConfirmation(CommandRisk)
}

public enum CommandExecutionCoordinator {
    public static func decision(for command: String) -> CommandExecutionDecision {
        if let risk = CommandRiskDetector.detect(in: command) {
            return .requiresConfirmation(risk)
        }
        return .execute
    }

    public static func confirmationRisk(for command: String) -> CommandRisk? {
        guard case .requiresConfirmation(let risk) = decision(for: command) else {
            return nil
        }
        return risk
    }
}

public enum CommandRiskDetector {
    /// Returns the first high-impact operation found in a user-entered shell
    /// command. This deliberately implements only the small shell grammar we
    /// need for guardrails: quote-aware words plus command separators. It does
    /// not execute expansions or fully emulate a shell, but avoids substring
    /// false positives such as `echo "rm -rf"`.
    public static func detect(in command: String) -> CommandRisk? {
        detect(in: command, nestingDepth: 0)
    }

    private static func detect(in command: String, nestingDepth: Int) -> CommandRisk? {
        // `sh -c`, `eval`, and remote ssh text can nest a command. Bound this
        // work so user-supplied input cannot cause unbounded recursion.
        guard nestingDepth < 8 else { return nil }
        for words in shellCommandWords(in: command) {
            if let risk = detect(inCommandWords: words, nestingDepth: nestingDepth) {
                return risk
            }
        }
        return nil
    }

    private static func detect(inCommandWords words: [String], nestingDepth: Int) -> CommandRisk? {
        guard let executableIndex = executableIndex(in: words) else { return nil }

        let executable = commandName(words[executableIndex])
        let arguments = Array(words.dropFirst(executableIndex + 1))

        // Shell and remote-execution wrappers receive source text as data, so
        // inspect that nested text instead of treating a quoted payload as a
        // standalone command. Ordinary commands such as `echo "rm -rf"` are
        // intentionally not searched recursively.
        if let nested = nestedCommand(for: executable, arguments: arguments),
           let risk = detect(in: nested, nestingDepth: nestingDepth + 1) {
            return risk
        }

        switch executable {
        case "rm":
            if hasRecursiveRemovalOption(arguments) {
                return .destructiveFiles
            }

        case "dd":
            if arguments.contains(where: { optionName($0) == "if" || optionName($0) == "of" }) {
                return .destructiveFiles
            }

        case let name where name == "mkfs" || name.hasPrefix("mkfs.") || name == "mke2fs" || name == "newfs":
            return .destructiveFiles

        case "reboot", "shutdown", "poweroff", "halt":
            return .systemLifecycle

        case "systemctl":
            if arguments.contains(where: isLifecycleAction) {
                return .systemLifecycle
            }

        case "service":
            if serviceLifecycleAction(arguments) {
                return .systemLifecycle
            }

        case "kill", "killall", "pkill":
            if hasForceKillSignal(arguments) {
                return .processTermination
            }

        case "docker", "podman", "nerdctl":
            if isDestructiveContainerCommand(arguments) {
                return .containerOrClusterDeletion
            }

        case "docker-compose", "podman-compose":
            if composeRunsDown(arguments) {
                return .containerOrClusterDeletion
            }

        case "kubectl", "oc":
            if firstSubcommand(in: arguments, optionsWithValues: kubectlOptionsWithValues) == "delete" {
                return .containerOrClusterDeletion
            }

        default:
            break
        }

        return nil
    }

    // MARK: Command classification

    private static func hasRecursiveRemovalOption(_ arguments: [String]) -> Bool {
        for argument in arguments {
            let lower = argument.lowercased()
            if lower == "--recursive" { return true }
            guard lower.hasPrefix("-"), !lower.hasPrefix("--") else { continue }
            if lower.dropFirst().contains("r") { return true }
        }
        return false
    }

    private static func optionName(_ argument: String) -> String? {
        let lower = argument.lowercased()
        guard let equal = lower.firstIndex(of: "=") else { return nil }
        let prefix = lower[..<equal]
        return prefix.hasPrefix("--") ? String(prefix.dropFirst(2)) : String(prefix)
    }

    private static func isLifecycleAction(_ argument: String) -> Bool {
        switch argument.lowercased() {
        case "stop", "restart", "reload-or-restart", "try-restart", "disable", "mask", "kill",
             "reboot", "poweroff", "halt", "emergency", "rescue", "isolate":
            return true
        default:
            return false
        }
    }

    private static func serviceLifecycleAction(_ arguments: [String]) -> Bool {
        // `service nginx stop` has a service name between the executable and
        // action; ignore leading service(8) options before finding it.
        var index = skipOptions(in: arguments, from: 0, optionsWithValues: serviceOptionsWithValues)
        guard index < arguments.endIndex else { return false }
        index += 1 // service name
        return arguments[index...].contains(where: isLifecycleAction)
    }

    private static func hasForceKillSignal(_ arguments: [String]) -> Bool {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index].lowercased()
            if argument == "-9" || argument == "-kill" || argument == "-sigkill" {
                return true
            }
            if argument == "-s" || argument == "--signal" {
                let signalIndex = index + 1
                if signalIndex < arguments.count, isKillSignal(arguments[signalIndex]) {
                    return true
                }
                index += 2
                continue
            }
            if argument.hasPrefix("-s") && isKillSignal(String(argument.dropFirst(2))) {
                return true
            }
            if argument.hasPrefix("--signal=") && isKillSignal(String(argument.dropFirst("--signal=".count))) {
                return true
            }
            index += 1
        }
        return false
    }

    private static func isKillSignal(_ value: String) -> Bool {
        let normalized = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "= "))
        return normalized == "9" || normalized == "kill" || normalized == "sigkill"
    }

    private static func isDestructiveContainerCommand(_ arguments: [String]) -> Bool {
        let subcommand = firstSubcommand(in: arguments, optionsWithValues: dockerOptionsWithValues)
        switch subcommand {
        case "rm", "rmi":
            return true
        case "system":
            guard let systemIndex = indexOfSubcommand("system", in: arguments, optionsWithValues: dockerOptionsWithValues) else {
                return false
            }
            return firstSubcommand(
                in: Array(arguments.dropFirst(systemIndex + 1)),
                optionsWithValues: []
            ) == "prune"
        case "compose":
            guard let composeIndex = indexOfSubcommand("compose", in: arguments, optionsWithValues: dockerOptionsWithValues) else {
                return false
            }
            return composeRunsDown(Array(arguments.dropFirst(composeIndex + 1)))
        default:
            return false
        }
    }

    private static func composeRunsDown(_ arguments: [String]) -> Bool {
        firstSubcommand(in: arguments, optionsWithValues: composeOptionsWithValues) == "down"
    }

    /// Finds the first command word after options. The options-with-values set
    /// handles `docker --context prod system prune` and `kubectl -n dev delete`
    /// without relying on whitespace-normalized substrings.
    private static func firstSubcommand(in arguments: [String], optionsWithValues: Set<String>) -> String? {
        let index = skipOptions(in: arguments, from: 0, optionsWithValues: optionsWithValues)
        guard index < arguments.endIndex else { return nil }
        return arguments[index].lowercased()
    }

    private static func indexOfSubcommand(
        _ expected: String,
        in arguments: [String],
        optionsWithValues: Set<String>
    ) -> Int? {
        let index = skipOptions(in: arguments, from: 0, optionsWithValues: optionsWithValues)
        guard index < arguments.endIndex, arguments[index].caseInsensitiveCompare(expected) == .orderedSame else {
            return nil
        }
        return index
    }

    private static func skipOptions(
        in words: [String],
        from start: Int,
        optionsWithValues: Set<String>
    ) -> Int {
        var index = start
        while index < words.count {
            let word = words[index]
            let lower = word.lowercased()
            if word == "--" { return index + 1 }
            guard lower.hasPrefix("-") && lower != "-" else { return index }
            if optionsWithValues.contains(lower) {
                index += 2
            } else {
                index += 1
            }
        }
        return index
    }

    // MARK: Shell word handling

    private static func executableIndex(in words: [String]) -> Int? {
        var index = 0
        while index < words.count, isEnvironmentAssignment(words[index]) {
            index += 1
        }

        // Launch prefixes should not hide the executable they wrap.
        while index < words.count {
            let command = commandName(words[index])
            guard executionPrefixes.contains(command) else { break }
            index += 1
            index = skipPrefixOptions(for: command, in: words, from: index)
            while index < words.count, isEnvironmentAssignment(words[index]) {
                index += 1
            }
        }

        // Shell control words may lead a command list (`if rm -rf …`, `! rm`).
        while index < words.count, shellControlWords.contains(words[index].lowercased()) {
            index += 1
        }
        return index < words.count ? index : nil
    }

    private static func skipPrefixOptions(for command: String, in words: [String], from start: Int) -> Int {
        let valueOptions: Set<String>
        switch command {
        case "sudo", "doas": valueOptions = sudoOptionsWithValues
        case "env": valueOptions = envOptionsWithValues
        case "nice": valueOptions = ["-n", "--adjustment"]
        case "ionice": valueOptions = ["-c", "--class", "-n", "--classdata", "-p", "--pid"]
        case "stdbuf": valueOptions = ["-i", "--input", "-o", "--output", "-e", "--error"]
        default: valueOptions = []
        }
        return skipOptions(in: words, from: start, optionsWithValues: valueOptions)
    }

    private static func nestedCommand(for executable: String, arguments: [String]) -> String? {
        switch executable {
        case "sh", "bash", "zsh", "dash", "ksh", "fish":
            return shellCommandArgument(arguments)
        case "su":
            return optionValue("-c", long: "--command", in: arguments)
        case "eval", "xargs":
            let start = skipOptions(in: arguments, from: 0, optionsWithValues: xargsOptionsWithValues)
            let nested = arguments.dropFirst(start).joined(separator: " ")
            return nested.isEmpty ? nil : nested
        case "ssh":
            return sshRemoteCommand(arguments)
        default:
            return nil
        }
    }

    private static func shellCommandArgument(_ arguments: [String]) -> String? {
        if let command = optionValue("-c", long: "--command", in: arguments) {
            return command
        }
        // `sh -ec '…'` is valid shorthand, so treat an option bundle containing
        // c as a command-text option too.
        for (index, argument) in arguments.enumerated() where argument.hasPrefix("-") && !argument.hasPrefix("--") {
            if argument.dropFirst().contains("c"), index + 1 < arguments.count {
                return arguments[index + 1]
            }
        }
        return nil
    }

    private static func optionValue(_ short: String, long: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == short || argument == long {
                let valueIndex = index + 1
                return valueIndex < arguments.count ? arguments[valueIndex] : nil
            }
            if argument.hasPrefix("\(long)=") {
                return String(argument.dropFirst(long.count + 1))
            }
        }
        return nil
    }

    private static func sshRemoteCommand(_ arguments: [String]) -> String? {
        var index = skipOptions(in: arguments, from: 0, optionsWithValues: sshOptionsWithValues)
        guard index < arguments.count else { return nil }
        index += 1 // destination host
        let remoteCommand = arguments.dropFirst(index).joined(separator: " ")
        return remoteCommand.isEmpty ? nil : remoteCommand
    }

    private static func commandName(_ word: String) -> String {
        let executable = word.split(separator: "/").last.map(String.init) ?? word
        return executable.lowercased()
    }

    private static func isEnvironmentAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        let name = word[..<equals]
        guard let first = name.first, !first.isNumber else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    /// Produces words grouped by shell command separators. Quotes and escapes
    /// are folded into their words; quoted strings never become separate
    /// commands. Command substitutions are an exception: `$()` and backticks
    /// execute even inside double quotes, so their content is tokenized as a
    /// nested command while `echo 'rm -rf /'` remains harmless text.
    private static func shellCommandWords(in command: String) -> [[String]] {
        enum Token {
            case word(String)
            case separator
        }

        var tokens: [Token] = []
        var word = ""
        var index = command.startIndex
        var singleQuoted = false
        var doubleQuoted = false
        var doubleQuoteSubstitutionDepth = 0
        var resumeDoubleQuoteAfterSubstitution = false
        var resumeDoubleQuoteAfterBacktick = false

        func flushWord() {
            guard !word.isEmpty else { return }
            tokens.append(.word(word))
            word = ""
        }

        func appendSeparator() {
            flushWord()
            if case .separator? = tokens.last { return }
            tokens.append(.separator)
        }

        while index < command.endIndex {
            let character = command[index]
            let nextIndex = command.index(after: index)

            if singleQuoted {
                if character == "'" {
                    singleQuoted = false
                } else {
                    word.append(character)
                }
                index = nextIndex
                continue
            }

            if doubleQuoted {
                if character == "$", nextIndex < command.endIndex, command[nextIndex] == "(" {
                    // `$()` executes within double quotes. Temporarily parse
                    // its contents with normal shell word boundaries so an
                    // expression such as `echo "$(rm -rf /)"` cannot hide the
                    // invoked command behind one quoted argument.
                    appendSeparator()
                    doubleQuoted = false
                    doubleQuoteSubstitutionDepth = 1
                    resumeDoubleQuoteAfterSubstitution = true
                    index = command.index(after: nextIndex)
                    continue
                } else if character == "`" {
                    // Backticks also execute inside double quotes.
                    appendSeparator()
                    doubleQuoted = false
                    resumeDoubleQuoteAfterBacktick = true
                    index = nextIndex
                    continue
                } else if character == "\"" {
                    doubleQuoted = false
                } else if character == "\\", nextIndex < command.endIndex {
                    word.append(command[nextIndex])
                    index = command.index(after: nextIndex)
                    continue
                } else {
                    word.append(character)
                }
                index = nextIndex
                continue
            }

            if character == ")", doubleQuoteSubstitutionDepth > 0 {
                appendSeparator()
                doubleQuoteSubstitutionDepth -= 1
                if doubleQuoteSubstitutionDepth == 0, resumeDoubleQuoteAfterSubstitution {
                    resumeDoubleQuoteAfterSubstitution = false
                    doubleQuoted = true
                }
                index = nextIndex
                continue
            }

            if character == "`", resumeDoubleQuoteAfterBacktick {
                appendSeparator()
                resumeDoubleQuoteAfterBacktick = false
                doubleQuoted = true
                index = nextIndex
                continue
            }

            switch character {
            case "'":
                singleQuoted = true
            case "\"":
                doubleQuoted = true
            case "\\":
                if nextIndex < command.endIndex {
                    word.append(command[nextIndex])
                    index = command.index(after: nextIndex)
                    continue
                }
                word.append(character)
            case "#":
                // # begins a comment only at a word boundary.
                if word.isEmpty {
                    flushWord()
                    while index < command.endIndex, command[index] != "\n" {
                        index = command.index(after: index)
                    }
                    appendSeparator()
                    continue
                }
                word.append(character)
            case "$" where nextIndex < command.endIndex && command[nextIndex] == "(":
                if doubleQuoteSubstitutionDepth > 0 {
                    doubleQuoteSubstitutionDepth += 1
                }
                appendSeparator()
                index = command.index(after: nextIndex)
                continue
            case ";", "\n", "|", "&", "<", ">", "(", ")", "`":
                appendSeparator()
            default:
                if character.isWhitespace {
                    flushWord()
                } else {
                    word.append(character)
                }
            }
            index = nextIndex
        }
        flushWord()

        var commands: [[String]] = []
        var current: [String] = []
        for token in tokens {
            switch token {
            case .word(let value):
                current.append(value)
            case .separator:
                if !current.isEmpty {
                    commands.append(current)
                    current = []
                }
            }
        }
        if !current.isEmpty { commands.append(current) }
        return commands
    }

    // MARK: Option data

    private static let executionPrefixes: Set<String> = [
        "sudo", "doas", "env", "command", "builtin", "nohup", "time", "nice", "ionice", "setsid", "stdbuf"
    ]
    private static let shellControlWords: Set<String> = ["if", "then", "do", "while", "until", "!"]
    private static let sudoOptionsWithValues: Set<String> = [
        "-c", "-g", "-h", "-p", "-r", "-t", "-u", "--chdir", "--group", "--host", "--prompt", "--role", "--type", "--user"
    ]
    private static let envOptionsWithValues: Set<String> = ["-c", "-s", "--chdir", "--split-string"]
    private static let serviceOptionsWithValues: Set<String> = ["--user"]
    private static let dockerOptionsWithValues: Set<String> = [
        "-c", "--config", "--context", "-h", "--host", "-l", "--log-level"
    ]
    private static let composeOptionsWithValues: Set<String> = [
        "-f", "--file", "-p", "--project-name", "--project-directory", "--env-file", "--profile"
    ]
    private static let kubectlOptionsWithValues: Set<String> = [
        "-n", "--namespace", "--context", "--cluster", "--user", "--kubeconfig", "--server", "--as", "--as-group", "--token", "--request-timeout"
    ]
    private static let xargsOptionsWithValues: Set<String> = ["-e", "-i", "-l", "-n", "-p", "-s", "-d", "--eof", "--max-args", "--max-chars", "--delimiter", "--replace"]
    private static let sshOptionsWithValues: Set<String> = [
        "-b", "-c", "-d", "-e", "-i", "-j", "-l", "-m", "-o", "-p", "-r", "-s", "-w",
        "--identity-file", "--jump", "--login-name", "--option", "--port"
    ]
}
