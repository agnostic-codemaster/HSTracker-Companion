//
//  LogReaderTests.swift
//  HSTracker
//
//  Created by Istvan Fehervari on 21/03/2017.
//  Copyright © 2017 Benjamin Michotte. All rights reserved.
//

import XCTest
import Foundation

@testable import HSTracker

class LogReaderTests: HSTrackerTests {
	
	override func setUp() {
		super.setUp()
	}
	
	override func tearDown() {
		super.tearDown()
	}
	
	func testTimeStamp() {
		
		let lines = ["D 00:06:10.0000000 GameState",
		             "D 00:06:10.0010000 GameState",
		             "D 00:06:10 GameState.DebugPrintPower() -     tag=ZONE value=PLAY",
		             "D 00:06:10.0010001 GameState"
                    ]
		let loglines = lines.map { LogLine(namespace: .power, line: $0) }
	
		XCTAssertEqual(loglines[0].time, loglines[2].time)
		XCTAssert(loglines[1].time > loglines[2].time, "\(loglines[1].time) is not bigger than \(loglines[2].time)")
        XCTAssert(loglines[3].time > loglines[1].time, "\(loglines[3].time) is not bigger than \(loglines[1].time)")
	}

    func testLogSessionDiscoveryUsesCurrentGameDirectoryWithoutMirror() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchDate = Date().addingTimeInterval(-30)
        let older = root.appendingPathComponent("Hearthstone_2026_09_23_09_00_00")
        let current = root.appendingPathComponent("Hearthstone_2026_09_24_09_00_00")
        try FileManager.default.createDirectory(at: older, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data().write(to: older.appendingPathComponent("Power.log"))
        try Data().write(to: current.appendingPathComponent("LoadingScreen.log"))

        XCTAssertEqual(MirrorHelper.latestLogSessionDir(in: root, launchedAfter: launchDate), current.path)
        XCTAssertNil(MirrorHelper.latestLogSessionDir(in: root,
                                                     launchedAfter: Date().addingTimeInterval(60)))
    }

    func testPowerArchiveResumesAtCommittedOffsetWithoutDuplicatingReconnectLines() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Power.log")
        let first = "D 10:00:00 GameState.DebugPrintPower() - CREATE_GAME\n"
        try Data(first.utf8).write(to: source)

        let archive = PowerLogArchive(directory: root.appendingPathComponent("archive"))
        archive.capture(path: source.path)
        XCTAssertEqual(archive.latestMatchLines().count, 1)

        let reconnect = "D 10:01:00 GameState.DebugPrintPower() - CREATE_GAME\n"
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(reconnect.utf8))
        try handle.close()

        let restarted = PowerLogArchive(directory: root.appendingPathComponent("archive"))
        restarted.capture(path: source.path)
        restarted.capture(path: source.path)
        XCTAssertEqual(restarted.latestMatchLines(), [first.trimmingCharacters(in: .newlines),
                                                       reconnect.trimmingCharacters(in: .newlines)])
    }

    func testPowerArchiveStartsNewSessionWhenSourceIsTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Power.log")
        let old = "D 10:00 GameState.DebugPrintPower() - CREATE_GAME\nD 10:20 GameState.DebugPrintPower() - OLD_EVENT\n"
        try Data(old.utf8).write(to: source)
        let archive = PowerLogArchive(directory: root.appendingPathComponent("archive"))
        archive.capture(path: source.path)

        let new = "D 11:00 GameState.DebugPrintPower() - CREATE_GAME\n"
        try Data(new.utf8).write(to: source)
        archive.capture(path: source.path)
        XCTAssertEqual(archive.latestMatchLines(), [new.trimmingCharacters(in: .newlines)])
    }

    func testPowerArchiveKeepsLatestGameAfterPreviousComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Power.log")
        let old = "D 10:00 GameState.DebugPrintPower() - CREATE_GAME\nD 10:20 GameState.DebugPrintPower() - tag=STATE value=COMPLETE\n"
        let new = "D 11:00 GameState.DebugPrintPower() - CREATE_GAME\n"
        try Data((old + new).utf8).write(to: source)
        let archive = PowerLogArchive(directory: root.appendingPathComponent("archive"))
        archive.capture(path: source.path)
        XCTAssertEqual(archive.latestMatchLines(), [new.trimmingCharacters(in: .newlines)])
    }

    func testPowerArchiveFiltersLatestMatchAcrossReconnects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Power.log")
        let log = """
            D 10:00 GameState.DebugPrintPower() - CREATE_GAME
            D 10:20 GameState.DebugPrintPower() - tag=STATE value=COMPLETE
            D 11:00 GameState.DebugPrintPower() - CREATE_GAME
            D 11:01 PowerTaskList.DebugPrintPower() - BLOCK_START
            D 11:02 GameState.DebugPrintPower() - TAG_CHANGE
            D 11:05 GameState.DebugPrintPower() - CREATE_GAME
            D 11:06 GameState.DebugPrintPower() - TAG_CHANGE
            D 11:07 GameState.DebugPrintPower() - partial
            """
        try Data(log.utf8).write(to: source)
        let archive = PowerLogArchive(directory: root.appendingPathComponent("archive"))
        archive.capture(path: source.path)
        XCTAssertEqual(archive.latestMatchLines(containing: "GameState."), [
            "D 11:00 GameState.DebugPrintPower() - CREATE_GAME",
            "D 11:02 GameState.DebugPrintPower() - TAG_CHANGE",
            "D 11:05 GameState.DebugPrintPower() - CREATE_GAME",
            "D 11:06 GameState.DebugPrintPower() - TAG_CHANGE"
        ])
    }

	func testLineContent() {
		let line = "D 00:06:10.0012345 GameState.DebugPrintPower() -     tag=ZONE value=PLAY"
		let lineItem = LogLine(namespace: .power, line: line)
		
		let dateStringFormatter = LogDateFormatter()
		dateStringFormatter.dateFormat = "HH:mm:ss.SSSSSSS"
		
		let str = String(format: "D %@ %@",dateStringFormatter.string(from: lineItem.time), lineItem.content)
		XCTAssertEqual(line, str)
	}
	
	func testDayRollover() {
		
		let future = LogDate(date: Calendar.current.date(byAdding: .second, value: 5, to: Date())!)
		if trimTime(date: future) > trimTime(date: LogDate()) {
			Thread.sleep(forTimeInterval: 5)
		}
		
		let line = "D 23:59:59.9999999 GameState.DebugPrintPower() -     tag=ZONE value=PLAY"
		let lineItem = LogLine(namespace: .power, line: line)

		XCTAssertEqual(trimTime(date: lineItem.time), trimTime(date: LogDate(date: Calendar.current.date(byAdding: .day, value: -1, to: Date())!) ))
	}
	
	func trimTime(date: LogDate) -> LogDate {
		let dateFormatter = LogDateFormatter()
		dateFormatter.timeStyle = DateFormatter.Style.none
		dateFormatter.dateStyle = DateFormatter.Style.short
		
		let str = dateFormatter.string(from: date) // 12/15/16
		
		return dateFormatter.date(from: str)!
	}
}
