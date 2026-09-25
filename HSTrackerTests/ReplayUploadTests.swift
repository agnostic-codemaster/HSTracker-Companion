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

    func testReconnectUploadUsesLastCreateAndMarksPartial() {
        let lines = ["D 10:00 GameState.DebugPrintPower() - CREATE_GAME",
                     "D 10:01 GameState.DebugPrintPower() - OLD_EVENT",
                     "D 10:02 GameState.DebugPrintPower() - CREATE_GAME",
                     "D 10:03 GameState.DebugPrintPower() - NEW_EVENT"]
        let candidate = LogUploader.candidate(from: lines, reconnected: true)
        XCTAssertEqual(candidate?.log, lines[2...].joined(separator: "\n"))
        XCTAssertEqual(candidate?.partial, true)
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
