import Darwin
import Foundation
import XCTest
@testable import HSBGSkipKit

final class IPCTests: XCTestCase {
    func testRejectsDifferentProtocolVersion() throws {
        try withServer(reply: Data("{\"protocolVersion\":99,\"ok\":true}\n".utf8), delay: 0) { path in
            XCTAssertThrowsError(try IPC.send(.status, timeout: 1, socketPath: path))
        }
    }

    func testTimesOutWhenDaemonDoesNotReply() throws {
        try withServer(reply: nil, delay: 0.3) { path in
            XCTAssertThrowsError(try IPC.send(.status, timeout: 0.1, socketPath: path))
        }
    }

    private func withServer(reply: Data?, delay: TimeInterval,
                            body: (String) throws -> Void) throws {
        let path = "/private/tmp/hsbg-test-\(UUID().uuidString.prefix(12)).sock"
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(result, 0)
        XCTAssertEqual(listen(listener, 1), 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let client = accept(listener, nil, nil)
            if client >= 0 {
                var buffer = [UInt8](repeating: 0, count: 256)
                _ = read(client, &buffer, buffer.count)
                Thread.sleep(forTimeInterval: delay)
                if let reply { reply.withUnsafeBytes { raw in _ = write(client, raw.baseAddress, raw.count) } }
                close(client)
            }
            finished.signal()
        }
        try body(path)
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success)
    }
}
