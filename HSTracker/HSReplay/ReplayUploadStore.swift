import Foundation

/// A small local ledger makes partial and failed reconnect uploads inspectable.
/// The retry payload contains only the selected upload segment, never auth tokens.
final class ReplayUploadStore {
    static let shared = ReplayUploadStore()

    struct Entry: Codable {
        var id: String
        var updatedAt: Date
        var status: String
        var detail: String
        var replayId: String?
        var metadata: Data?
        var log: String?
        var partial: Bool
    }

    private let lock = NSLock()
    private let path: URL
    private var entries: [Entry] = []

    init(path: URL = Paths.HSTracker.appendingPathComponent("ReplayUploadResults.json")) {
        self.path = path
        try? FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: path),
           let stored = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = stored
        }
    }

    func saveCandidate(id: String, metadata: Data, log: String, partial: Bool) {
        update(id: id, status: "待重试", detail: "候选已保存，等待上传", replayId: nil,
               metadata: metadata, log: log, partial: partial)
    }

    func finish(id: String, status: String, detail: String, replayId: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        entries[index].detail = detail
        entries[index].replayId = replayId
        entries[index].updatedAt = Date()
        if replayId != nil || status == "被拒绝" {
            entries[index].metadata = nil
            entries[index].log = nil
        }
        persist()
    }

    func retryCandidates() -> [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.status == "待重试" && $0.metadata != nil && $0.log != nil }
    }

    func summary() -> String {
        lock.lock()
        defer { lock.unlock() }
        if entries.isEmpty { return "尚无上传记录" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(10).map {
            "\(formatter.string(from: $0.updatedAt))  \($0.status)  \($0.detail)"
        }.joined(separator: "\n")
    }

    private func update(id: String, status: String, detail: String, replayId: String?,
                        metadata: Data?, log: String?, partial: Bool) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.id == id }
        entries.append(Entry(id: id, updatedAt: Date(), status: status, detail: detail,
                             replayId: replayId, metadata: metadata, log: log, partial: partial))
        entries = Array(entries.sorted { $0.updatedAt > $1.updatedAt }.prefix(30))
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do { try data.write(to: path, options: .atomic) }
        catch { logger.error("Could not save replay upload status: \(error)") }
    }
}
