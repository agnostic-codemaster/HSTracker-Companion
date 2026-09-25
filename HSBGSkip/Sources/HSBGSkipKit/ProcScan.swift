import Darwin
import Foundation

/// A single established IPv4 TCP connection owned by a process.
public struct Connection: Sendable, Equatable {
    public let fd: Int32
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16

    public init(fd: Int32, localAddress: String, localPort: UInt16,
                remoteAddress: String, remotePort: UInt16) {
        self.fd = fd
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }
}

public struct GameServerEndpoint: Sendable, Equatable {
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) {
        self.address = address
        self.port = port
    }
}

/// Locates Hearthstone and its live sockets via libproc.
///
/// Deliberately does not shell out to `lsof`: a fork+exec costs a few hundred
/// milliseconds, and the whole point of the skip hotkey is to cut the connection at a
/// precise moment. A libproc scan measures in fractions of a millisecond.
public enum ProcScan {

    /// Port numbers alone cannot distinguish a game socket from Battle.net.
    public static let gameServerPort: UInt16 = 3724
    public static let battleNetPort: UInt16 = 1119

    static let executableSuffix = "Hearthstone.app/Contents/MacOS/Hearthstone"

    public static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    public static func allPIDs() -> [pid_t] {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
        guard written > 0 else { return [] }
        return Array(pids.prefix(Int(written) / MemoryLayout<pid_t>.size)).filter { $0 > 0 }
    }

    /// The running Hearthstone process, if any.
    public static func hearthstonePID() -> pid_t? {
        let matches = allPIDs().filter { executablePath(of: $0)?.hasSuffix(executableSuffix) == true }
        return matches.count == 1 ? matches[0] : nil
    }

    public static func hearthstoneUID() -> uid_t? {
        guard let pid = hearthstonePID() else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_uid
    }

    /// Every established IPv4 TCP connection owned by `pid`.
    public static func establishedConnections(pid: pid_t) -> [Connection] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }

        var descriptors = [proc_fdinfo](
            repeating: proc_fdinfo(),
            count: Int(size) / MemoryLayout<proc_fdinfo>.size
        )
        let written = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, size)
        guard written > 0 else { return [] }

        var result: [Connection] = []
        for descriptor in descriptors.prefix(Int(written) / MemoryLayout<proc_fdinfo>.size) {
            guard descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) else { continue }

            var info = socket_fdinfo()
            let read = proc_pidfdinfo(
                pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO,
                &info, Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard read == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_kind == SOCKINFO_TCP else { continue }

            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == TSI_S_ESTABLISHED else { continue }

            let endpoint = tcp.tcpsi_ini
            guard endpoint.insi_vflag & UInt8(INI_IPV4) != 0 else { continue }

            result.append(Connection(
                fd: descriptor.proc_fd,
                localAddress: Self.ipv4String(endpoint.insi_laddr.ina_46),
                localPort: UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_lport)),
                remoteAddress: Self.ipv4String(endpoint.insi_faddr.ina_46),
                remotePort: UInt16(bigEndian: UInt16(truncatingIfNeeded: endpoint.insi_fport))
            ))
        }
        return result
    }

    /// Picks the connection carrying the game session.
    ///
    /// The game log names the actual server, including games that share port 1119 with
    /// Battle.net. Never infer that every 1119 socket is a game connection.
    public static func gameServerConnection(among connections: [Connection]) -> Connection? {
        gameServerConnection(among: connections, loggedEndpoint: currentGameServerEndpoint())
    }

    public static func gameServerConnection(
        among connections: [Connection], loggedEndpoint: GameServerEndpoint?
    ) -> Connection? {
        guard let loggedEndpoint else { return nil }
        let matches = connections.filter {
            $0.remoteAddress == loggedEndpoint.address && $0.remotePort == loggedEndpoint.port
        }
        guard matches.count == 1 else { return nil }
        // pfctl -k acts on source/destination addresses, not TCP ports. If another
        // Hearthstone socket shares that address, resetting states could affect it.
        guard connections.filter({ $0.remoteAddress == loggedEndpoint.address }).count == 1 else {
            return nil
        }
        return matches[0]
    }

    /// Reads the latest matchmaking address recorded by this Hearthstone session. A stale
    /// address is harmless: it only selects an exact match among the process's live sockets.
    public static func currentGameServerEndpoint() -> GameServerEndpoint? {
        guard let root = HearthstonePaths.discoverLogsRoot(),
              let sessions = try? FileManager.default.contentsOfDirectory(atPath: root),
              let newest = sessions.filter({ $0.hasPrefix("Hearthstone_") }).max(),
              let handle = FileHandle(forReadingAtPath: "\(root)/\(newest)/GameNetLogger.log")
        else { return nil }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return endpointFromGameNetLog(String(decoding: data, as: UTF8.self))
    }

    public static func endpointFromGameNetLog(_ contents: String) -> GameServerEndpoint? {
        let marker = "Network.GotoGameServe() - address="
        for line in contents.split(separator: "\n").reversed() {
            guard let range = line.range(of: marker) else { continue }
            let addressAndPort = line[range.upperBound...]
                .split(separator: ",", maxSplits: 1).first?
                .trimmingCharacters(in: .whitespaces) ?? ""
            let parts = addressAndPort.split(separator: ":")
            guard parts.count == 2,
                  let port = UInt16(parts[1]),
                  port > 0 else { continue }
            let address = String(parts[0])
            var ipv4 = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 else { continue }
            return GameServerEndpoint(address: address, port: port)
        }
        return nil
    }

    /// Convenience: find Hearthstone and its game-server connection in one step.
    public static func findGameServerConnection() -> (pid: pid_t, connection: Connection)? {
        guard let pid = hearthstonePID() else { return nil }
        guard let connection = gameServerConnection(among: establishedConnections(pid: pid)) else {
            return nil
        }
        // pfctl -k resets a local/remote IP pair for every process. Refuse the
        // operation if Battle.net or another process shares that pair.
        let otherPIDs = allPIDs().filter { $0 != pid }
        guard !otherPIDs.isEmpty else { return nil }
        for otherPID in otherPIDs {
            let sockets = establishedConnections(pid: otherPID)
            if sockets.contains(where: {
                $0.localAddress == connection.localAddress &&
                    $0.remoteAddress == connection.remoteAddress
            }) { return nil }
        }
        return (pid, connection)
    }

    static func ipv4String(_ address: in4in6_addr) -> String {
        var raw = address.i46a_addr4
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &raw, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
