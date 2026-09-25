//
//  ReplayUploadTests.swift
//  HSTracker
//
//  Created by Istvan Fehervari on 09/05/2017.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest

@testable import HSTracker

class ReplayUploadTests: HSTrackerTests {

	override func setUp() {
		super.setUp()
	}

	override func tearDown() {
		super.tearDown()
	}

	/// The upload metadata goes to HSReplay as JSON, so the property names are
	/// part of the wire format rather than an internal detail.
	func testMetadataEncoding() throws {
		let player = UploadMetaData.Player()

		player.stars = 1
		player.wins = 20
		player.losses = 10
		player.deck = ["one", "two"]
		player.deck_id = 12345
		player.cardback = 3

		let data = try JSONEncoder().encode(player)
		let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

		XCTAssertEqual(json["stars"] as? Int, player.stars)
		XCTAssertEqual(json["wins"] as? Int, player.wins)
		XCTAssertEqual(json["losses"] as? Int, player.losses)
		XCTAssertEqual(json["deck"] as? [String], player.deck)
		XCTAssertEqual(json["deck_id"] as? Int64, player.deck_id)
		XCTAssertEqual(json["cardback"] as? Int, player.cardback)

		// Unset fields are omitted rather than sent as null.
		XCTAssertNil(json["rank"])
		XCTAssertNil(json["legend_rank"])
	}

    func testLegacyBattlegroundsHistoryDecodesWithoutIncompleteFlag() throws {
        let json = """
        {"startTime":"2026-09-23T10:00:00Z","endTime":"2026-09-23T10:20:00Z",
         "hero":"TB_BaconShop_HERO_01","rating":6000,"ratingAfter":6020,"placement":3}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let game = try decoder.decode(BattlegroundsLastGames.GameItem.self, from: Data(json.utf8))
        XCTAssertFalse(game.isIncomplete)
        XCTAssertEqual(game.placement, 3)
    }

    func testMissingBattlegroundsFieldsAreMarkedIncomplete() {
        let game = BattlegroundsLastGames.GameItem(
            startTime: Date(), endTime: Date(), hero: "", rating: 0, ratingAfter: 0,
            placement: 0, finalBoard: [], friendlyGame: false, player: nil,
            duos: false, incomplete: true)
        XCTAssertTrue(game.isIncomplete)
        let row = BattlegroundsGameRowViewModel(gameItem: game)
        XCTAssertEqual(row.placementText, "未知（不完整）")
        XCTAssertEqual(row.heroName, "未知英雄（不完整）")
    }

    func testUploadStatusAndRetryPayloadSurviveRestart() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = ReplayUploadStore(path: path)
        store.saveCandidate(id: "match-1", metadata: Data("{}".utf8), log: "CREATE_GAME", partial: true)
        XCTAssertEqual(store.retryCandidates().count, 1)

        let reloaded = ReplayUploadStore(path: path)
        XCTAssertEqual(reloaded.retryCandidates().first?.log, "CREATE_GAME")
        reloaded.finish(id: "match-1", status: "部分", detail: "已上传", replayId: "abc")
        XCTAssertTrue(reloaded.summary().contains("部分"))
        XCTAssertTrue(reloaded.retryCandidates().isEmpty)
    }

    private func power(_ text: String, _ time: String = "10:00:00.0000000") -> String {
        "D \(time) GameState.DebugPrintPower() - \(text)"
    }

    private func reconnectFixture(secondPlayerEntity: Int = 2) -> (first: [String], second: [String]) {
        let later = "10:05:00.0000000"
        let first = [power("CREATE_GAME"),
                     power("    GameEntity EntityID=1"),
                     power("        tag=TURN value=1"),
                     power("    Player EntityID=2 PlayerID=5 GameAccountId=[hi=1 lo=1]"),
                     power("        tag=PLAYER_ID value=5"),
                     "D 10:00:00.0000000 GameState.DebugPrintGame() - PlayerID=5, PlayerName=me#1",
                     power("FULL_ENTITY - Creating ID=10 CardID=HERO_A"),
                     power("    tag=ZONE value=PLAY"),
                     power("    tag=CONTROLLER value=5"),
                     power("BLOCK_START BlockType=PLAY Entity=10 EffectCardId= EffectIndex=0 Target=0 SubOption=-1 "),
                     power("    FULL_ENTITY - Creating ID=11 CardID=MINION_A"),
                     power("        tag=ZONE value=HAND"),
                     power("        tag=EXHAUSTED value=1"),
                     power("    TAG_CHANGE Entity=me#1 tag=RESOURCES value=3 ")]
        let second = [power("CREATE_GAME", later),
                      power("    GameEntity EntityID=1", later),
                      power("        tag=TURN value=3", later),
                      power("    Player EntityID=\(secondPlayerEntity) PlayerID=5 GameAccountId=[hi=1 lo=1]", later),
                      power("        tag=PLAYER_ID value=5", later),
                      power("        tag=RESOURCES value=3", later),
                      power("FULL_ENTITY - Creating ID=10 CardID=HERO_A", later),
                      power("    tag=ZONE value=PLAY", later),
                      power("    tag=CONTROLLER value=5", later),
                      power("FULL_ENTITY - Creating ID=11 CardID=MINION_A", later),
                      power("    tag=ZONE value=PLAY", later),
                      power("FULL_ENTITY - Creating ID=12 CardID=MINION_B", later),
                      power("    tag=ZONE value=PLAY", later),
                      power("TAG_CHANGE Entity=12 tag=ATK value=3 ", later)]
        return (first, second)
    }

    /// 重连快照被换算成差异：闭合断线时未结束的 BLOCK，只补变化的标签，新实体补 FULL_ENTITY，
    /// 最终只剩一个 CREATE_GAME，重连前的英雄与随从事件都保留下来。
    func testReconnectUploadStitchesSegmentsIntoOneGame() throws {
        let fixture = reconnectFixture()
        let candidate = try XCTUnwrap(LogUploader.candidate(from: fixture.first + fixture.second,
                                                            reconnected: true))
        let later = "10:05:00.0000000"
        let expected = fixture.first + [
            power("BLOCK_END", later),
            power("TAG_CHANGE Entity=GameEntity tag=TURN value=3 ", later),
            power("TAG_CHANGE Entity=11 tag=ZONE value=PLAY ", later),
            power("TAG_CHANGE Entity=11 tag=EXHAUSTED value=0 ", later),
            power("FULL_ENTITY - Creating ID=12 CardID=MINION_B", later),
            power("    tag=ZONE value=PLAY", later),
            power("TAG_CHANGE Entity=12 tag=ATK value=3 ", later)
        ]
        XCTAssertEqual(candidate.log, expected.joined(separator: "\n"))
        XCTAssertEqual(candidate.log.components(separatedBy: "CREATE_GAME").count - 1, 1)
        XCTAssertEqual(candidate.stitched, 1)
        XCTAssertTrue(candidate.partial)
    }

    /// 玩家实体对不上说明不是同一局，不能拼接，退回只上传最后一段。
    func testReconnectUploadFallsBackToLastCreateWhenSegmentsDiffer() throws {
        let fixture = reconnectFixture(secondPlayerEntity: 3)
        let candidate = try XCTUnwrap(LogUploader.candidate(from: fixture.first + fixture.second,
                                                            reconnected: true))
        XCTAssertEqual(candidate.log, fixture.second.joined(separator: "\n"))
        XCTAssertEqual(candidate.stitched, 0)
        XCTAssertTrue(candidate.partial)
    }

    func testUploadCandidateBasics() {
        let single = [power("CREATE_GAME"), power("TAG_CHANGE Entity=1 tag=TURN value=2 ")]
        XCTAssertEqual(LogUploader.candidate(from: single, reconnected: false)?.partial, false)
        XCTAssertEqual(LogUploader.candidate(from: single, reconnected: true)?.partial, true)
        XCTAssertNil(LogUploader.candidate(from: ["missing"], reconnected: false))
        XCTAssertTrue(LogUploader.retryableStatus(nil))
        XCTAssertTrue(LogUploader.retryableStatus(503))
        XCTAssertTrue(LogUploader.retryableStatus(429))
        XCTAssertFalse(LogUploader.retryableStatus(400))
    }

    func testUploadDiagnosticOmitsSignedURLAndToken() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/upload?x-amz-security-token=secret"))
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200,
                                                     httpVersion: nil, headerFields: nil))
        let error = NSError(domain: NSURLErrorDomain, code: -1,
                            userInfo: [NSURLErrorFailingURLStringErrorKey: url.absoluteString])
        let summary = Http.transportSummary(data: Data("abc".utf8), response: response, error: error)
        XCTAssertEqual(summary, "status=200, bytes=3, error=NSURLErrorDomain:-1")
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertFalse(summary.contains("example.com"))
    }
}
