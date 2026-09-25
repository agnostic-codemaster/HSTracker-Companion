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
    func latestMatchLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        guard let name = cursor?.archiveName,
              let input = try? FileHandle(forReadingFrom: directory.appendingPathComponent(name)) else { return [] }
        defer { try? input.close() }
        var matchLines: [String] = []
        var pending = Data()
        var started = false
        var completed = false

        func process(_ bytes: Data) {
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines)
            let create = line.contains("GameState.DebugPrintPower()") && line.contains("CREATE_GAME")
            if create && completed {
                matchLines.removeAll(keepingCapacity: true)
                completed = false
            }
            if create { started = true }
            if started && !line.isEmpty { matchLines.append(line) }
            if started && line.contains("tag=STATE value=COMPLETE") { completed = true }
        }

        do {
            while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
                let parts = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
                for part in parts.dropLast() {
                    pending.append(contentsOf: part)
                    process(pending)
                    pending.removeAll(keepingCapacity: true)
                }
                if let last = parts.last { pending.append(contentsOf: last) }
            }
        } catch {
            logger.error("Could not read archived Power log: \(error)")
        }
        return matchLines
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
