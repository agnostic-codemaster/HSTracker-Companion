import XCTest
import Darwin
@testable import HSBGSkipKit

final class ConnectionSelectionTests: XCTestCase {
    private let game = Connection(fd: 1, localAddress: "192.0.2.10", localPort: 60001,
                                  remoteAddress: "198.51.100.10", remotePort: 1119)
    private let battleNet = Connection(fd: 2, localAddress: "192.0.2.10", localPort: 60002,
                                       remoteAddress: "198.51.100.20", remotePort: 1119)

    func testUsesOnlyExactLoggedEndpoint() {
        let endpoint = GameServerEndpoint(address: "198.51.100.10", port: 1119)
        XCTAssertEqual(ProcScan.gameServerConnection(among: [battleNet, game], loggedEndpoint: endpoint), game)
        XCTAssertNil(ProcScan.gameServerConnection(among: [battleNet, game], loggedEndpoint: nil))
        XCTAssertNil(ProcScan.gameServerConnection(
            among: [battleNet], loggedEndpoint: endpoint))
    }

    func testRejectsAmbiguousMatch() {
        let duplicate = Connection(fd: 3, localAddress: "192.0.2.10", localPort: 60003,
                                   remoteAddress: game.remoteAddress, remotePort: game.remotePort)
        XCTAssertNil(ProcScan.gameServerConnection(
            among: [game, duplicate],
            loggedEndpoint: GameServerEndpoint(address: game.remoteAddress, port: game.remotePort)))
    }

    func testRejectsAnotherSocketAtSameAddressBecauseStateKillIsAddressScoped() {
        let another = Connection(fd: 4, localAddress: "192.0.2.10", localPort: 60004,
                                 remoteAddress: game.remoteAddress, remotePort: 443)
        XCTAssertNil(ProcScan.gameServerConnection(
            among: [game, another],
            loggedEndpoint: GameServerEndpoint(address: game.remoteAddress, port: game.remotePort)))
    }

    func testRejectsInvalidDurationBeforeApplyingBlock() {
        let controller = SkipController(blockers: [])
        XCTAssertThrowsError(try controller.skip(game, duration: -.infinity))
        XCTAssertThrowsError(try controller.skip(game, duration: 16))
    }

    func testEndpointComesFromLastValidGameNetLoggerRecord() {
        let log = """
        Network.GotoGameServe() - address=198.51.100.10:1119, foo
        Network.GotoGameServe() - address=invalid:1119, foo
        Network.GotoGameServe() - address=198.51.100.11:3724, foo
        """
        XCTAssertEqual(ProcScan.endpointFromGameNetLog(log),
                       GameServerEndpoint(address: "198.51.100.11", port: 3724))
        XCTAssertNil(ProcScan.endpointFromGameNetLog("no game address"))
    }

    func testRestoreClearsRuleAndCooldownRejectsImmediateSecondSkip() throws {
        let blocker = MockBlocker()
        let controller = SkipController(blockers: [blocker])
        try controller.skip(game, duration: 3)
        XCTAssertTrue(controller.isBlocking)
        controller.restore()
        XCTAssertFalse(controller.isBlocking)
        XCTAssertEqual(blocker.restoreCount, 1)
        XCTAssertThrowsError(try controller.skip(game, duration: 3))
    }

    func testPrivilegedCommandWrapperHasDeadline() {
        let started = Date()
        let result = Shell.run("/bin/sleep", ["2"], timeout: 0.1)
        XCTAssertFalse(result.succeeded)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}

private final class MockBlocker: NetworkBlocker {
    let name = "mock"
    var restoreCount = 0
    func block(_ connection: Connection) throws {}
    func restore() { restoreCount += 1 }
}
