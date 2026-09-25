import Foundation

/// Wire format between the menu-bar app and the root daemon.
///
/// Note what a request *cannot* say: which address to block. The daemon runs as root, so
/// letting a caller name an arbitrary IP would turn it into a general-purpose "blackhole any
/// host as root" primitive for anything running as the user. Instead the daemon derives the
/// target itself from the live Hearthstone process. The client can only ask for a skip and
/// say how long.
public enum SkipRequest: Codable, Sendable {
    case skip(duration: TimeInterval)
    case status
    case restore
    /// Reports pf/route state from inside the daemon, which is the only place with the root
    /// privileges needed to read it.
    case diag

    private enum CodingKeys: String, CodingKey { case command, duration }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .command) {
        case "skip":
            self = .skip(duration: try container.decodeIfPresent(TimeInterval.self, forKey: .duration) ?? 3)
        case "status":
            self = .status
        case "restore":
            self = .restore
        case "diag":
            self = .diag
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .command, in: container, debugDescription: "unknown command \(other)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .skip(let duration):
            try container.encode("skip", forKey: .command)
            try container.encode(duration, forKey: .duration)
        case .status:
            try container.encode("status", forKey: .command)
        case .restore:
            try container.encode("restore", forKey: .command)
        case .diag:
            try container.encode("diag", forKey: .command)
        }
    }
}

public struct SkipResponse: Codable, Sendable {
    public var protocolVersion: Int
    public var ok: Bool
    public var strategy: String?
    public var target: String?
    public var blocking: Bool?
    public var error: String?
    public var detail: String?

    public init(
        ok: Bool, strategy: String? = nil, target: String? = nil,
        blocking: Bool? = nil, error: String? = nil, detail: String? = nil
    ) {
        self.protocolVersion = IPC.protocolVersion
        self.ok = ok
        self.strategy = strategy
        self.target = target
        self.blocking = blocking
        self.error = error
        self.detail = detail
    }
}

public enum IPC {
    public static let protocolVersion = 1
    public static let socketPath = "/var/run/hstracker-chs-skip.sock"

    /// Sends one request and reads one response. Synchronous and short-lived by design —
    /// the daemon answers in well under a millisecond.
    public static func send(_ request: SkipRequest, timeout: TimeInterval = 3,
                            socketPath: String = IPC.socketPath) throws -> SkipResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IPCError.cannotConnect("socket() failed") }
        defer { close(fd) }

        var timeval = timeval(
            tv_sec: Int(timeout),
            tv_usec: Int32((timeout - floor(timeout)) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeval, socklen_t(MemoryLayout<Foundation.timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeval, socklen_t(MemoryLayout<Foundation.timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw IPCError.cannotConnect("socket path too long")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw IPCError.cannotConnect(
                "daemon not reachable at \(socketPath) — is hsbgskipd installed and running?"
            )
        }

        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { throw IPCError.transport("write failed") }
                sent += n
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) && response.count <= 16_384 {
            let n = read(fd, &buffer, buffer.count)
            guard n > 0 else { break }
            response.append(contentsOf: buffer.prefix(n))
        }
        guard response.contains(0x0A), response.count <= 16_384 else {
            throw IPCError.transport("daemon closed or timed out without a valid reply")
        }

        let line = response.prefix { $0 != 0x0A }
        let decoded = try JSONDecoder().decode(SkipResponse.self, from: Data(line))
        guard decoded.protocolVersion == protocolVersion else {
            throw IPCError.transport("拔线服务版本不兼容，请在设置中升级服务")
        }
        return decoded
    }
}

public enum IPCError: LocalizedError {
    case cannotConnect(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .cannotConnect(let message), .transport(let message): return message
        }
    }
}
