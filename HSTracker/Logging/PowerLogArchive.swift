import Foundation

/// Keeps the raw Power.log bytes and a committed source offset across app restarts.
/// Capture runs independently of LogReader's game entry point, so a reconnect does not
/// discard the earlier part of the same game. Missing lines are never synthesized.
final class PowerLogArchive {
    static let shared = PowerLogArchive(directory: Paths.HSTracker.appendingPathComponent("PowerLogArchive"))

    private struct Cursor: Codable {
        var sourcePath: String
        var sourceFileNumber: UInt64
        var offset: UInt64
        var archiveName: String
        var archiveLength: UInt64
    }

    private let directory: URL
    private let lock = NSLock()
    private var cursor: Cursor?

    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: directory.appendingPathComponent("cursor.json")) {
            cursor = try? JSONDecoder().decode(Cursor.self, from: data)
        }
        if let cursor,
           let output = try? FileHandle(forWritingTo: directory.appendingPathComponent(cursor.archiveName)) {
            try? output.truncate(atOffset: cursor.archiveLength)
            try? output.close()
        }
    }

    func capture(path: String) {
        lock.lock()
        defer { lock.unlock() }
        let source = URL(fileURLWithPath: path)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let number = attrs[.systemFileNumber] as? NSNumber,
              let size = attrs[.size] as? NSNumber else { return }
        let inode = number.uint64Value
        let fileSize = size.uint64Value
        if cursor?.sourcePath != path || cursor?.sourceFileNumber != inode || fileSize < (cursor?.offset ?? 0) {
            cursor = Cursor(sourcePath: path, sourceFileNumber: inode, offset: 0,
                            archiveName: UUID().uuidString + ".log", archiveLength: 0)
            guard let name = cursor?.archiveName else { return }
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: nil)
            saveCursor()
            pruneArchives()
        }
        guard var current = cursor, fileSize > current.offset,
              let input = try? FileHandle(forReadingFrom: source),
              let output = try? FileHandle(forWritingTo: directory.appendingPathComponent(current.archiveName)) else { return }
        defer { try? input.close(); try? output.close() }
        do {
            // A crash after appending but before committing the cursor is repaired by
            // truncating to the committed length and copying the source bytes again.
            try output.truncate(atOffset: current.archiveLength)
            try output.seek(toOffset: current.archiveLength)
            try input.seek(toOffset: current.offset)
            while current.offset < fileSize {
                let chunk = try input.read(upToCount: Int(min(1_048_576, fileSize - current.offset))) ?? Data()
                if chunk.isEmpty { break }
                try output.write(contentsOf: chunk)
                current.offset += UInt64(chunk.count)
                current.archiveLength += UInt64(chunk.count)
                cursor = current
                saveCursor()
            }
        } catch {
            logger.error("Power log archive failed: \(error)")
        }
    }

    /// The final segment can contain several CREATE_GAME lines after reconnect.
    /// Preserve it in full; the uploader may choose a usable suffix separately.
    ///
    /// The archive covers a whole Hearthstone session and can run to tens of megabytes.
    /// Decoding all of it into strings at game end cost hundreds of megabytes that were
    /// never returned, so a first pass locates the latest match on raw bytes, and only
    /// that match is decoded, keeping just the lines that contain `filter`.
    func latestMatchLines(containing filter: String? = nil) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let name = cursor?.archiveName else { return [] }
        let url = directory.appendingPathComponent(name)
        guard let start = latestMatchOffset(in: url) else { return [] }
        var matchLines: [String] = []
        forEachLine(in: url, from: start) { bytes, _ in
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            if !line.isEmpty && (filter.map { line.contains($0) } ?? true) {
                matchLines.append(line)
            }
        }
        return matchLines
    }

    private static let gameStateMarker = Data("GameState.DebugPrintPower()".utf8)
    private static let createGameMarker = Data("CREATE_GAME".utf8)
    private static let completeMarker = Data("tag=STATE value=COMPLETE".utf8)

    /// Offset of the CREATE_GAME line that opens the latest match. A CREATE_GAME starts a
    /// new match only after the previous one reached COMPLETE; before that it is a
    /// reconnect inside the same match.
    private func latestMatchOffset(in url: URL) -> UInt64? {
        var start: UInt64?
        var completed = false
        forEachLine(in: url, from: 0) { bytes, offset in
            if bytes.range(of: Self.createGameMarker) != nil && bytes.range(of: Self.gameStateMarker) != nil {
                if start == nil || completed {
                    start = offset
                    completed = false
                }
            } else if start != nil && bytes.range(of: Self.completeMarker) != nil {
                completed = true
            }
        }
        return start
    }

    /// Calls `body` with each newline-terminated line, without its newline, and the offset
    /// the line starts at. A trailing line still being written is skipped.
    private func forEachLine(in url: URL, from start: UInt64, _ body: (Data, UInt64) -> Void) {
        guard let input = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? input.close() }
        var pending = Data()
        var lineStart = start
        do {
            try input.seek(toOffset: start)
            var reachedEnd = false
            while !reachedEnd {
                // The read must happen inside the pool: each chunk comes back autoreleased,
                // and outside it every chunk of the file stays alive until the caller's pool
                // drains — as much memory as the archive is large.
                try autoreleasepool {
                    guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else {
                        reachedEnd = true
                        return
                    }
                    var index = chunk.startIndex
                    while let newline = chunk[index...].firstIndex(of: 0x0A) {
                        let length: Int
                        if pending.isEmpty {
                            let line = chunk[index..<newline]
                            length = line.count
                            body(line, lineStart)
                        } else {
                            pending.append(chunk[index..<newline])
                            length = pending.count
                            body(pending, lineStart)
                            pending.removeAll()
                        }
                        lineStart += UInt64(length + 1)
                        index = chunk.index(after: newline)
                    }
                    pending.append(chunk[index...])
                }
            }
        } catch {
            logger.error("Could not read archived Power log: \(error)")
        }
    }

    private func saveCursor() {
        guard let cursor, let data = try? JSONEncoder().encode(cursor) else { return }
        try? data.write(to: directory.appendingPathComponent("cursor.json"), options: .atomic)
    }

    private func pruneArchives() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                          includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let old = files.filter { $0.pathExtension == "log" && $0.lastPathComponent != cursor?.archiveName }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
                return (left ?? .distantPast) > (right ?? .distantPast)
            }
        for file in old.dropFirst(20) { try? FileManager.default.removeItem(at: file) }
    }
}
