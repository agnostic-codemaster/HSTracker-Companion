import Foundation

/// Locates a Hearthstone installation and makes sure it is configured to write the log we
/// depend on.
///
/// Neither of these can be assumed. Battle.net lets the user pick an install directory, and
/// Hearthstone writes `Power.log` only when a `log.config` asks it to — on a machine that has
/// never run a tracker, that file does not exist and no amount of tailing will find anything.
public enum HearthstonePaths {

    /// Overrides discovery entirely. Useful for unusual installs and for testing.
    public static let logsRootEnvironmentKey = "HSBG_HEARTHSTONE_LOGS"

    public static var logConfigPath: String {
        NSHomeDirectory() + "/Library/Preferences/Blizzard/Hearthstone/log.config"
    }

    /// Where Hearthstone writes its per-session log directories.
    ///
    /// Deriving this from the *running* process is the only method that cannot be wrong, so
    /// it is tried before any hardcoded guess.
    public static func discoverLogsRoot() -> String? {
        if let override = ProcessInfo.processInfo.environment[logsRootEnvironmentKey],
           !override.isEmpty {
            return override
        }

        if let pid = ProcScan.hearthstonePID(),
           let executable = ProcScan.executablePath(of: pid),
           let appRange = executable.range(of: "/Hearthstone.app/") {
            return String(executable[..<appRange.lowerBound]) + "/Logs"
        }

        let candidates = [
            "/Applications/Hearthstone/Logs",
            NSHomeDirectory() + "/Applications/Hearthstone/Logs",
            "/Applications/Games/Hearthstone/Logs",
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    // MARK: - log.config

    /// Sections Hearthstone must be told to log, and the settings we need from each.
    ///
    /// `Power` is the one that matters; the rest are cheap and match what other trackers
    /// request, so enabling them keeps this tool interoperable with them.
    static let requiredSections = ["Power", "LoadingScreen", "Decks", "Arena", "FullScreenFX"]

    public enum LogConfigResult: Sendable, Equatable {
        case alreadyCorrect
        case created
        case updated
        /// Hearthstone reads log.config only at launch.
        public var requiresRestart: Bool { self != .alreadyCorrect }
    }

    /// Ensures `log.config` requests verbose file logging for the sections we parse.
    ///
    /// Merges rather than overwrites: HSTracker and other trackers use this same file, and
    /// clobbering it would silently break them.
    @discardableResult
    public static func ensureLogConfig() throws -> LogConfigResult {
        let path = logConfigPath
        let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let existedBefore = FileManager.default.fileExists(atPath: path)

        var sections = parse(existing)
        var changed = false

        for section in requiredSections {
            var settings = sections[section] ?? [:]
            for (key, value) in [
                ("LogLevel", "1"),
                ("FilePrinting", "true"),
                ("ConsolePrinting", "false"),
                ("ScreenPrinting", "false"),
            ] where settings[key] != value {
                settings[key] = value
                changed = true
            }
            // Only Power needs verbose output, and it is what makes board state parseable.
            if section == "Power", settings["Verbose"] != "true" {
                settings["Verbose"] = "true"
                changed = true
            }
            if sections[section] == nil { changed = true }
            sections[section] = settings
        }

        guard changed else { return .alreadyCorrect }

        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try render(sections).write(toFile: path, atomically: true, encoding: .utf8)
        return existedBefore ? .updated : .created
    }

    /// Minimal INI reader. Preserves any section it does not recognise.
    static func parse(_ contents: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if sections[current!] == nil { sections[current!] = [:] }
            } else if let section = current, let separator = line.firstIndex(of: "=") {
                let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: separator)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { sections[section]?[key] = value }
            }
        }
        return sections
    }

    static func render(_ sections: [String: [String: String]]) -> String {
        sections.keys.sorted().map { section in
            let body = (sections[section] ?? [:]).keys.sorted()
                .map { "\($0)=\(sections[section]![$0]!)" }
                .joined(separator: "\n")
            return "[\(section)]\n\(body)"
        }.joined(separator: "\n") + "\n"
    }
}
