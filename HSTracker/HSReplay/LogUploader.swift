//  LogUploader.swift — © 2016 Benjamin Michotte. All rights reserved.
import Foundation
import Gzip
import RealmSwift

class LogUploader {
    private static let lock = NSLock()
    private static var inProgress = Set<String>()

    static func upload(logLines: [LogLine], buildNumber: Int,
                       metaData: (metaData: UploadMetaData, statId: String)? = nil,
                       gameStart: Date? = nil, fromFile: Bool = false,
                       completion: @escaping (UploadResult) -> Void) {
        upload(logLines: logLines.sorted { $0.time < $1.time }.map { $0.line },
               buildNumber: buildNumber, metaData: metaData, gameStart: gameStart,
               fromFile: fromFile, completion: completion)
    }

    static func upload(logLines: [String], buildNumber: Int,
                       metaData: (metaData: UploadMetaData, statId: String)? = nil,
                       gameStart: Date? = nil, fromFile: Bool = false,
                       partialDueToReconnect: Bool = false,
                       completion: @escaping (UploadResult) -> Void) {
        let id = metaData?.statId ?? UUID().uuidString
        guard let candidate = candidate(from: logLines, reconnected: partialDueToReconnect) else {
            reject(id: id, reason: "日志缺少 CREATE_GAME", completion: completion)
            return
        }
        guard let info = metaData?.metaData, info.match_start != nil, info.game_type != nil else {
            reject(id: id, reason: "缺少对局起点或上传元数据", completion: completion)
            return
        }
        info.build = buildNumber
        guard let encoded = try? JSONEncoder().encode(info) else {
            reject(id: id, reason: "无法编码上传元数据", completion: completion)
            return
        }
        // 拔线重连会让日志里出现多个 CREATE_GAME。优先把各段拼接成一局上传；
        // 拼接失败时才退回只上传最后一段，并标记为部分上传。
        let partial = candidate.partial
        let log = candidate.log
        ReplayUploadStore.shared.saveCandidate(id: id, metadata: encoded, log: log, partial: partial)
        send(log: log, metadata: encoded, id: id, partial: partial, stitched: candidate.stitched,
             statId: metaData?.statId, gameType: info.game_type,
             deckId: info.player1?.deck_id ?? info.player2?.deck_id, completion: completion)
    }

    static func candidate(from lines: [String],
                          reconnected: Bool) -> (log: String, partial: Bool, stitched: Int)? {
        let creates = lines.indices.filter {
            lines[$0].contains("GameState.DebugPrintPower()") && lines[$0].contains("CREATE_GAME")
        }
        guard let firstCreate = creates.first, let lastCreate = creates.last else { return nil }
        if creates.count > 1,
           let stitched = ReconnectLogStitcher.stitch(Array(lines[firstCreate...])) {
            return (stitched.lines.joined(separator: "\n"), true, stitched.reconnects)
        }
        return (lines[lastCreate...].joined(separator: "\n"), creates.count != 1 || reconnected, 0)
    }

    static func retryableStatus(_ status: Int?) -> Bool {
        guard let status else { return true }
        return status == 429 || status >= 500
    }

    static func retryPending() {
        for item in ReplayUploadStore.shared.retryCandidates() {
            guard let metadata = item.metadata, let log = item.log else { continue }
            HSReplayAPI.getUploadToken { _ in
                send(log: log, metadata: metadata, id: item.id, partial: item.partial,
                     statId: nil, gameType: nil, deckId: nil) { _ in }
            }
        }
    }

    private static func reject(id: String, reason: String,
                               completion: @escaping (UploadResult) -> Void) {
        ReplayUploadStore.shared.saveCandidate(id: id, metadata: Data(), log: "", partial: true)
        ReplayUploadStore.shared.finish(id: id, status: "被拒绝", detail: reason)
        deliver(.failed(error: reason), completion: completion)
    }

    private static func deliver(_ result: UploadResult,
                                completion: @escaping (UploadResult) -> Void) {
        if Thread.isMainThread { completion(result) }
        else { DispatchQueue.main.async { completion(result) } }
    }

    private static func send(log: String, metadata: Data, id: String, partial: Bool, stitched: Int = 0,
                             statId: String?, gameType: Int?, deckId: Int64?,
                             completion: @escaping (UploadResult) -> Void) {
        lock.lock()
        if inProgress.contains(id) {
            lock.unlock()
            deliver(.failed(error: "上传已经进行中"), completion: completion)
            return
        }
        inProgress.insert(id)
        lock.unlock()

        func finish(_ result: UploadResult, status: String, detail: String, replayId: String? = nil) {
            lock.lock()
            inProgress.remove(id)
            lock.unlock()
            ReplayUploadStore.shared.finish(id: id, status: status, detail: detail, replayId: replayId)
            deliver(result, completion: completion)
        }

        guard let token = Settings.hsReplayUploadToken else {
            finish(.failed(error: "缺少上传授权"), status: "待重试", detail: "缺少上传授权")
            return
        }
        let headers = ["X-Api-Key": HSReplayAPI.apiKey, "Authorization": "Token \(token)"]
        var requestStatus: Int?
        Http(url: HSReplay.uploadRequestUrl).json(method: .post, data: metadata, headers: headers,
                                                  responseStatus: { requestStatus = $0 }) { response in
            guard let json = response as? [String: Any] else {
                let retry = retryableStatus(requestStatus)
                finish(.failed(error: "上传请求失败"), status: retry ? "待重试" : "被拒绝",
                       detail: requestStatus.map { "HTTP \($0)" } ?? "网络请求失败")
                return
            }
            guard let putURL = json["put_url"] as? String,
                  let shortID = json["shortid"] as? String,
                  json["url"] as? String != nil else {
                let reason = String(describing: json)
                finish(.failed(error: reason), status: retryableStatus(requestStatus) ? "待重试" : "被拒绝", detail: reason)
                return
            }
            guard let data = log.data(using: .utf8), let compressed = try? data.gzipped() else {
                finish(.failed(error: "日志压缩失败"), status: "被拒绝", detail: "日志压缩失败")
                return
            }
            Http(url: putURL).upload(method: .put,
                                     headers: ["Content-Type": "text/plain", "Content-Encoding": "gzip"],
                                     data: compressed) { success, error in
                DispatchQueue.main.async {
                    if success {
                        let excluded: Set<Int> = [BnetGameType.bgt_battlegrounds.rawValue,
                                                  BnetGameType.bgt_battlegrounds_friendly.rawValue,
                                                  BnetGameType.bgt_mercenaries_pve.rawValue,
                                                  BnetGameType.bgt_mercenaries_pvp.rawValue,
                                                  BnetGameType.bgt_mercenaries_friendly.rawValue,
                                                  BnetGameType.bgt_mercenaries_pve_coop.rawValue]
                        if let gameType, !excluded.contains(gameType), let statId, let deckId,
                           let stat = RealmHelper.getGameStat(deckId: deckId, with: statId) {
                            RealmHelper.update(stat: stat, hsReplayId: shortID)
                        }
                        let status = stitched > 0 ? "已拼接" : (partial ? "部分" : "完整")
                        let note = stitched > 0 ? "（拼接 \(stitched) 次重连）" : ""
                        finish(.successful(replayId: shortID), status: status,
                               detail: "已上传：\(shortID)\(note)", replayId: shortID)
                    } else {
                        finish(.failed(error: error ?? "上传连接失败"), status: "待重试", detail: error ?? "上传连接失败")
                    }
                }
            }
        }
    }
}
