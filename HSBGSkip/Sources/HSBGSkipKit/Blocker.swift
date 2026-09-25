import Foundation

/// Severs Hearthstone's game-server connection, then restores the network.
///
/// Uses a short-lived pf `block return-rst` rule pinned to the old socket's local port.
///
/// Every strategy must be idempotent on restore: `restore()` is safe to call when nothing is
/// blocked, because it runs from crash handlers and timers as well as the normal path.
public protocol NetworkBlocker: AnyObject {
    var name: String { get }
    func block(_ connection: Connection) throws
    func restore()
}

public enum BlockerError: LocalizedError {
    case commandFailed(String, String)
    case rejected(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output):
            return "\(command) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .rejected(let reason):
            return reason
        }
    }
}

// MARK: - pf

public final class PFBlocker: NetworkBlocker {
    public let name = "pf"

    /// macOS `/etc/pf.conf` ships with `anchor "com.apple/*"`, so any sub-anchor under
    /// `com.apple/` is evaluated without editing the main ruleset — which matters because OS
    /// updates rewrite `/etc/pf.conf`.
    public static let anchor = "com.apple/hstracker_chs_skip"

    private let pfctl = "/sbin/pfctl"
    private var enableToken: String?
    private var isBlocking = false

    public init() {}

    public func block(_ connection: Connection) throws {
        // -E is reference counted, so this cooperates with anything else using pf.
        let enable = Shell.run(pfctl, ["-E"])
        guard enable.succeeded else {
            throw BlockerError.commandFailed("pfctl -E", enable.combined)
        }
        enableToken = Self.parseToken(from: enable.combined)

        // `pfctl -E` enables pf but does NOT load /etc/pf.conf. If nothing else has loaded it,
        // the main ruleset is empty, the `anchor "com.apple/*"` point does not exist, and a
        // rule loaded into a nested anchor is never evaluated — pfctl reports success and
        // drops nothing. Load the stock ruleset only when that anchor is genuinely absent, so
        // anchors inserted by other software (VPNs) are left alone whenever possible.
        if !Self.mainRulesetHasAppleAnchor() {
            let load = Shell.run(pfctl, ["-f", "/etc/pf.conf"])
            guard load.succeeded else {
                releaseToken()
                throw BlockerError.commandFailed("pfctl -f /etc/pf.conf", load.combined)
            }
        }

        // Two things matter in this rule, both learned the hard way.
        //
        // `return-rst` rather than `drop`: silently discarding packets is invisible to TCP,
        // which just retransmits and resumes intact once the block lifts — the game never
        // notices. A forged reset kills the socket outright.
        //
        // Matching the *source port* rather than the whole destination: a rule covering all
        // traffic to <server>:3724 also resets the reconnect, because Hearthstone redials the
        // same address ~100ms later. That put the client into a retry loop against a rule
        // still in force, which is what left it hanging on "Reconnecting". Pinning the rule to
        // this socket's ephemeral local port makes it lethal to the connection we want gone
        // and completely transparent to the new one, which arrives on a different port.
        let rule = "block return-rst quick proto tcp "
                 + "from any port \(connection.localPort) "
                 + "to \(connection.remoteAddress) port \(connection.remotePort)\n"
        let load = Shell.run(pfctl, ["-a", Self.anchor, "-f", "-"], input: rule)
        guard load.succeeded else {
            releaseToken()
            throw BlockerError.commandFailed("pfctl -a \(Self.anchor) -f -", load.combined)
        }
        isBlocking = true

        // Do not take pfctl's exit status as proof. Read the rule back: if the anchor is not
        // reachable the rule silently does nothing, which is the failure mode that made an
        // earlier version report success while the game stayed connected.
        let readback = Shell.run(pfctl, ["-a", Self.anchor, "-s", "rules"])
        guard readback.combined.contains(connection.remoteAddress) else {
            restore()
            throw BlockerError.commandFailed(
                "pf rule not active in anchor \(Self.anchor)", readback.combined
            )
        }

        // Flush the established state so the cut is immediate rather than waiting for the
        // client's own timeout.
        guard ProcScan.findGameServerConnection()?.connection == connection else {
            restore()
            throw BlockerError.rejected("对局连接已变化，已取消拔线")
        }
        let killed = Shell.run(pfctl, ["-k", connection.localAddress, "-k", connection.remoteAddress])
        guard killed.succeeded else {
            restore()
            throw BlockerError.commandFailed("pfctl -k", killed.combined)
        }
    }

    /// Whether the main ruleset actually contains the `com.apple` anchor point our nested
    /// anchor hangs off.
    static func mainRulesetHasAppleAnchor() -> Bool {
        Shell.run("/sbin/pfctl", ["-s", "rules"]).combined.contains("com.apple")
    }

    /// Human-readable pf state, for diagnosing why a block did or did not take effect.
    public static func diagnostics() -> String {
        let info = Shell.run("/sbin/pfctl", ["-s", "info"]).combined
        let status = info.split(separator: "\n").first.map(String.init) ?? "unknown"
        let mainRules = Shell.run("/sbin/pfctl", ["-s", "rules"]).combined
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let ourRules = Shell.run("/sbin/pfctl", ["-a", anchor, "-s", "rules"]).combined
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return """
        pf \(status)
        main ruleset has com.apple anchor: \(mainRulesetHasAppleAnchor())
        main ruleset:
        \(mainRules.isEmpty ? "  (empty — nested anchors are NOT evaluated)" : mainRules)
        \(anchor) rules:
        \(ourRules.isEmpty ? "  (none)" : ourRules)
        """
    }

    /// Launchd restarts after an uncatchable crash. Clear any stale rule before serving.
    public static func clearStaleRules() {
        _ = Shell.run("/sbin/pfctl", ["-a", anchor, "-F", "rules"])
    }

    public func restore() {
        if isBlocking {
            Shell.run(pfctl, ["-a", Self.anchor, "-F", "rules"])
            isBlocking = false
        }
        releaseToken()
    }

    private func releaseToken() {
        if let token = enableToken {
            Shell.run(pfctl, ["-X", token])
            enableToken = nil
        }
    }

    /// `pfctl -E` reports `Token : 1234567890` on stderr.
    static func parseToken(from output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("Token") {
            if let token = line.split(separator: ":").last?
                .trimmingCharacters(in: .whitespaces), !token.isEmpty {
                return token
            }
        }
        return nil
    }
}

// MARK: - Coordinator

/// Runs a timed block with a guaranteed restore.
public final class SkipController {
    private let blockers: [NetworkBlocker]
    private var active: NetworkBlocker?
    private var restoreTimer: DispatchSourceTimer?
    private let lock = NSLock()

    /// Hard ceiling on how long the network may stay cut, whatever a client asks for.
    public static let maximumDuration: TimeInterval = 15

    /// Minimum gap between skips.
    ///
    /// The client reconnects within ~100ms of the reset, so a second skip fired moments later
    /// tears down the *new* connection — often mid-handshake, which leaves Hearthstone stuck
    /// on "Reconnecting" rather than recovering. One combat only ever needs one cut, so
    /// refuse the rest instead of trusting the caller not to double-fire.
    public static let cooldown: TimeInterval = 8

    private var lastSkipEndedAt: Date?

    public init(blockers: [NetworkBlocker] = [PFBlocker()]) {
        self.blockers = blockers
    }

    public var isBlocking: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil
    }

    /// Cuts the connection and schedules the restore. Returns the strategy that worked.
    @discardableResult
    public func skip(_ connection: Connection, duration: TimeInterval) throws -> String {
        guard duration.isFinite, duration > 0, duration <= Self.maximumDuration else {
            throw BlockerError.rejected("拔线时长无效")
        }
        lock.lock()
        defer { lock.unlock() }

        if active != nil {
            throw BlockerError.rejected("a skip is already in progress")
        }
        if let last = lastSkipEndedAt, Date().timeIntervalSince(last) < Self.cooldown {
            let remaining = Self.cooldown - Date().timeIntervalSince(last)
            throw BlockerError.rejected(
                String(format: "too soon — wait %.0fs so the reconnect can finish", remaining)
            )
        }

        var failures: [String] = []
        for blocker in blockers {
            do {
                try blocker.block(connection)
                active = blocker
                scheduleRestoreLocked(after: min(duration, Self.maximumDuration))
                return blocker.name
            } catch {
                failures.append("\(blocker.name): \(error.localizedDescription)")
                blocker.restore()
            }
        }
        throw BlockerError.commandFailed("all strategies", failures.joined(separator: "; "))
    }

    public func restore() {
        lock.lock(); defer { lock.unlock() }
        restoreLocked()
    }

    private func scheduleRestoreLocked(after seconds: TimeInterval) {
        restoreTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + seconds)
        timer.setEventHandler { [weak self] in self?.restore() }
        restoreTimer = timer
        timer.resume()
    }

    private func restoreLocked() {
        restoreTimer?.cancel()
        restoreTimer = nil
        if active != nil { lastSkipEndedAt = Date() }
        // Restore every strategy, not just the active one: a crash mid-`skip` can leave a
        // partially applied block behind, and restore is idempotent.
        for blocker in blockers { blocker.restore() }
        active = nil
    }
}
