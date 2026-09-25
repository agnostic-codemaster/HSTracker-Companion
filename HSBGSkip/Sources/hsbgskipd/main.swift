import Darwin
import Foundation
import HSBGSkipKit

// hsbgskipd — root daemon that severs Hearthstone's game-server connection on request.
//
// Runs as root because pf requires it. It is deliberately narrow: the
// only thing it will ever block is the connection it discovers itself by inspecting the live
// Hearthstone process. Clients cannot name a target.

let controller = SkipController()

func log(_ message: String) {
    FileHandle.standardError.write(Data("[hsbgskipd] \(message)\n".utf8))
}

// MARK: - Failsafe restore
//
// The network must never stay cut because this process died. Restore on every exit path we
// can intercept, then let the OS take the rest.

func emergencyRestore() {
    controller.restore()
}

atexit { emergencyRestore() }

// Held for the process lifetime; a released source stops delivering.
var signalSources: [DispatchSourceSignal] = []

for signalNumber in [SIGINT, SIGTERM, SIGHUP, SIGQUIT] {
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler {
        log("caught signal \(signalNumber) — restoring network and exiting")
        emergencyRestore()
        exit(0)
    }
    source.resume()
    signalSources.append(source)
}

// MARK: - Request handling

func handle(_ request: SkipRequest) -> SkipResponse {
    switch request {
    case .status:
        guard let found = ProcScan.findGameServerConnection() else {
            return SkipResponse(
                ok: false, blocking: controller.isBlocking,
                error: ProcScan.hearthstonePID() == nil
                    ? "炉石未运行或存在多个炉石进程"
                    : "未找到唯一的对局连接，请确认已进入对局"
            )
        }
        return SkipResponse(
            ok: true,
            target: "\(found.connection.remoteAddress):\(found.connection.remotePort)",
            blocking: controller.isBlocking
        )

    case .restore:
        controller.restore()
        return SkipResponse(ok: true, blocking: false)

    case .diag:
        var report = PFBlocker.diagnostics()
        if let found = ProcScan.findGameServerConnection() {
            report += "\n\ntarget: \(found.connection.remoteAddress):\(found.connection.remotePort)"
        } else {
            report += "\n\ntarget: none (not in a game?)"
        }
        return SkipResponse(ok: true, blocking: controller.isBlocking, detail: report)

    case .skip(let duration):
        guard duration.isFinite, duration > 0, duration <= SkipController.maximumDuration else {
            return SkipResponse(ok: false, error: "invalid skip duration")
        }
        guard let found = ProcScan.findGameServerConnection() else {
            return SkipResponse(
                ok: false,
                error: ProcScan.hearthstonePID() == nil
                    ? "炉石未运行或存在多个炉石进程"
                    : "未找到唯一的对局连接，已拒绝拔线"
            )
        }
        do {
            let strategy = try controller.skip(found.connection, duration: duration)
            let target = "\(found.connection.remoteAddress):\(found.connection.remotePort)"
            log("cut \(target) (local port \(found.connection.localPort)) via \(strategy) "
                + "for \(min(duration, SkipController.maximumDuration))s")
            return SkipResponse(ok: true, strategy: strategy, target: target, blocking: true)
        } catch {
            return SkipResponse(ok: false, error: error.localizedDescription)
        }
    }
}

func serve(client fd: Int32) {
    defer { close(fd) }

    var peerUID: uid_t = 0
    var peerGID: gid_t = 0
    guard getpeereid(fd, &peerUID, &peerGID) == 0,
          let consoleUID = (try? FileManager.default.attributesOfItem(atPath: "/dev/console"))?[.ownerAccountID] as? NSNumber,
          peerUID == consoleUID.uint32Value else {
        log("refused client outside current console session")
        return
    }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var incoming = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while !incoming.contains(0x0A) {
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { break }
        incoming.append(contentsOf: buffer.prefix(n))
        if incoming.count > 4096 { return }
    }
    guard incoming.contains(0x0A), incoming.count <= 4096 else { return }

    let line = Data(incoming.prefix { $0 != 0x0A })
    let response: SkipResponse
    if let request = try? JSONDecoder().decode(SkipRequest.self, from: line) {
        if case .skip = request, ProcScan.hearthstoneUID() != peerUID {
            response = SkipResponse(ok: false, error: "炉石进程属于其他用户，已拒绝拔线")
        } else {
            response = handle(request)
        }
    } else {
        response = SkipResponse(ok: false, error: "malformed request")
    }

    guard var payload = try? JSONEncoder().encode(response) else { return }
    payload.append(0x0A)
    payload.withUnsafeBytes { raw in
        var sent = 0
        while sent < raw.count {
            let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
            guard n > 0 else { return }
            sent += n
        }
    }
}

// MARK: - Listener

guard getuid() == 0 else {
    log("must run as root (pf requires it)")
    exit(1)
}

PFBlocker.clearStaleRules()

unlink(IPC.socketPath)

let listener = socket(AF_UNIX, SOCK_STREAM, 0)
guard listener >= 0 else {
    log("socket() failed: \(String(cString: strerror(errno)))")
    exit(1)
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
withUnsafeMutableBytes(of: &address.sun_path) { raw in
    raw.copyBytes(from: Array(IPC.socketPath.utf8))
}

let bound = withUnsafePointer(to: &address) { pointer in
    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard bound == 0 else {
    log("bind(\(IPC.socketPath)) failed: \(String(cString: strerror(errno)))")
    exit(1)
}

// Reachable by the console user's group, not by everyone.
chmod(IPC.socketPath, 0o660)
let staffGID: gid_t = getgrnam("staff")?.pointee.gr_gid ?? 20
chown(IPC.socketPath, 0, staffGID)

guard listen(listener, 8) == 0 else {
    log("listen() failed: \(String(cString: strerror(errno)))")
    exit(1)
}

log("listening on \(IPC.socketPath)")

let acceptQueue = DispatchQueue(label: "hsbgskipd.accept")
acceptQueue.async {
    while true {
        let client = accept(listener, nil, nil)
        if client < 0 {
            if errno == EINTR { continue }
            log("accept() failed: \(String(cString: strerror(errno)))")
            break
        }
        serve(client: client)
    }
}

dispatchMain()
