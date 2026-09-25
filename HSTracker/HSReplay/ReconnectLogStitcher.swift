//  ReconnectLogStitcher.swift
//  HSTracker

import Foundation

/// 拔线重连后，炉石会在 Power.log 里再写一个 CREATE_GAME，把当时的局面整体快照一遍
/// （实体 ID 与重连前保持一致）。HSReplay 把每个 CREATE_GAME 当作一局，一次上传只收一局，
/// 所以此前只能上传最后一段：重连前选的英雄、买的随从都没有事件记录，HSReplay 就显示
/// “未知”英雄和残缺的终局阵容。
///
/// 这里把每个重连快照换算成相对上一段结束状态的差异：已有实体只补变化了的 TAG_CHANGE，
/// 新实体补 FULL_ENTITY，卡牌 ID 变化补 SHOW_ENTITY/CHANGE_ENTITY，快照里已消失的在场实体
/// 移出游戏，断线时没闭合的 BLOCK 补 BLOCK_END。最终只保留第一个 CREATE_GAME。
/// 补出来的每一行都来自服务器快照本身；断线期间的具体过程日志里本来就没有，不做任何猜测。
/// 任何一段看起来不是同一局（GameEntity 或玩家实体对不上）时返回 nil，由调用方退回旧逻辑。
enum ReconnectLogStitcher {
    private static let powerPrefix = "GameState.DebugPrintPower() - "
    private static let liveZones: Set<String> = ["PLAY", "HAND", "SECRET", "DECK"]

    private final class State {
        var tags: [Int: [String: String]] = [:]
        var cards: [Int: String] = [:]
        var gameEntity: Int?
        var playerEntities: [Int: Int] = [:] // PlayerID -> EntityID
        var names: [String: Int] = [:]       // PlayerName -> PlayerID
        var depth = 0
        private var current: Int?

        func entityId(_ raw: Substring) -> Int? {
            let ref = raw.trimmingCharacters(in: .whitespaces)
            if let id = Int(ref) { return id }
            if ref == "GameEntity" { return gameEntity }
            if ref.hasPrefix("[") { return ReconnectLogStitcher.bracketId(ref) }
            guard let playerId = names[ref] else { return nil }
            return playerEntities[playerId]
        }

        func set(_ id: Int, _ tag: String, _ value: String) {
            tags[id, default: [:]][tag] = value
        }

        func feed(_ line: String) {
            // hslog 在遇到 Options 时会强制闭合所有未结束的 BLOCK（战旗日志常漏 BLOCK_END），
            // 这里保持同样的计数方式，避免拼接时补出多余的 BLOCK_END。
            if line.contains("GameState.DebugPrintOptions()") { depth = 0 }
            if let player = ReconnectLogStitcher.playerName(line) {
                names[player.name] = player.id
                current = nil
                return
            }
            guard let body = ReconnectLogStitcher.body(line) else {
                current = nil
                return
            }
            let text = body.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("tag=") {
                if let id = current, let pair = ReconnectLogStitcher.tagValue(text) {
                    set(id, pair.tag, pair.value)
                }
                return
            }
            current = nil
            if text.hasPrefix("BLOCK_START") {
                depth += 1
            } else if text == "BLOCK_END" {
                depth = max(0, depth - 1)
            } else if let id = ReconnectLogStitcher.gameEntityId(text) {
                gameEntity = id
                current = id
                tags[id] = tags[id] ?? [:]
            } else if let player = ReconnectLogStitcher.playerEntity(text) {
                playerEntities[player.playerId] = player.entityId
                current = player.entityId
                tags[player.entityId] = tags[player.entityId] ?? [:]
            } else if let full = ReconnectLogStitcher.fullEntity(text) {
                guard let id = full.id ?? full.ref.flatMap({ entityId($0) }) else { return }
                current = id
                tags[id] = tags[id] ?? [:]
                if !full.cardId.isEmpty || cards[id] == nil { cards[id] = full.cardId }
            } else if let shown = ReconnectLogStitcher.showEntity(text) {
                guard let id = entityId(shown.ref) else { return }
                current = id
                tags[id] = tags[id] ?? [:]
                cards[id] = shown.cardId
            } else if let change = ReconnectLogStitcher.tagChange(text, prefix: "HIDE_ENTITY - Entity=")
                        ?? ReconnectLogStitcher.tagChange(text, prefix: "TAG_CHANGE Entity=") {
                if let id = entityId(change.ref) { set(id, change.tag, change.value) }
            }
        }
    }

    private struct Snapshot {
        var gameEntity: Int?
        var players: [Int: Int] = [:]
        var order: [Int] = []
        var tags: [Int: [(tag: String, value: String)]] = [:]
        var cards: [Int: String] = [:]
        var names: [String: Int] = [:]
        var headerEnd = 1
    }

    static func stitch(_ input: [String]) -> (lines: [String], reconnects: Int)? {
        let lines = input.filter { $0.contains("GameState.") }
        let starts = lines.indices.filter { isCreateGame(lines[$0]) }
        guard starts.count > 1 else { return nil }

        let state = State()
        var output: [String] = []
        output.reserveCapacity(lines.count)
        for line in lines[starts[0]..<starts[1]] {
            state.feed(line)
            output.append(line)
        }

        let bounds = Array(starts.dropFirst()) + [lines.count]
        for index in 0..<(bounds.count - 1) {
            let segment = Array(lines[bounds[index]..<bounds[index + 1]])
            let snapshot = readSnapshot(segment)
            if let game = snapshot.gameEntity, let known = state.gameEntity, game != known { return nil }
            for (playerId, entity) in snapshot.players {
                if let known = state.playerEntities[playerId], known != entity { return nil }
                state.playerEntities[playerId] = entity
            }
            for (name, playerId) in snapshot.names { state.names[name] = playerId }

            let synthesized = diff(snapshot, against: state, timestamp: timestamp(segment[0]))
            for line in synthesized { state.feed(line) }
            output.append(contentsOf: synthesized)
            for line in segment[snapshot.headerEnd...] {
                state.feed(line)
                output.append(line)
            }
        }
        return (output, starts.count - 1)
    }

    private static func diff(_ snapshot: Snapshot, against state: State, timestamp: String) -> [String] {
        var result: [String] = []
        func emit(_ text: String) { result.append("\(timestamp) \(powerPrefix)\(text)") }

        for _ in 0..<state.depth { emit("BLOCK_END") }

        let special = Set([snapshot.gameEntity].compactMap { $0 } + Array(snapshot.players.values))
        for id in snapshot.order {
            let fresh = snapshot.tags[id] ?? []
            let cardId = snapshot.cards[id] ?? ""
            guard let old = state.tags[id] else {
                if special.contains(id) { continue }
                emit("FULL_ENTITY - Creating ID=\(id) CardID=\(cardId)")
                for pair in fresh { emit("    tag=\(pair.tag) value=\(pair.value)") }
                continue
            }
            let oldCard = state.cards[id] ?? ""
            if !special.contains(id), !cardId.isEmpty, cardId != oldCard {
                emit("\(oldCard.isEmpty ? "SHOW_ENTITY" : "CHANGE_ENTITY") - Updating Entity=\(id) CardID=\(cardId)")
                for pair in fresh { emit("    tag=\(pair.tag) value=\(pair.value)") }
                continue
            }
            let name = id == snapshot.gameEntity ? "GameEntity" : "\(id)"
            var seen = Set<String>()
            for pair in fresh {
                seen.insert(pair.tag)
                if old[pair.tag] != pair.value {
                    emit("TAG_CHANGE Entity=\(name) tag=\(pair.tag) value=\(pair.value) ")
                }
            }
            // 快照里只列非零标签，旧状态里有、快照里没有的就是被清零了。
            for (tag, value) in old.sorted(by: { $0.key < $1.key })
            where !seen.contains(tag) && value != "0" && value != "INVALID" {
                emit("TAG_CHANGE Entity=\(name) tag=\(tag) value=0 ")
            }
        }

        let present = Set(snapshot.order)
        for id in state.tags.keys.sorted() where !present.contains(id) && !special.contains(id) {
            if id == state.gameEntity || state.playerEntities.values.contains(id) { continue }
            if let zone = state.tags[id]?["ZONE"], liveZones.contains(zone) {
                emit("TAG_CHANGE Entity=\(id) tag=ZONE value=REMOVEDFROMGAME ")
            }
        }
        return result
    }

    /// 读取紧跟在 CREATE_GAME 后面的快照：GameEntity、Player 以及顶层 FULL_ENTITY 与各自的标签。
    private static func readSnapshot(_ segment: [String]) -> Snapshot {
        var snapshot = Snapshot()
        var current: Int?
        var index = 1
        while index < segment.count {
            let line = segment[index]
            guard let body = Self.body(line) else {
                if let player = playerName(line) {
                    snapshot.names[player.name] = player.id
                } else if !line.contains("GameState.DebugPrintGame()")
                            && !line.contains("GameState.DebugPrintPowerList()") {
                    break
                }
                index += 1
                continue
            }
            let text = body.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("tag=") {
                if let id = current, let pair = tagValue(text) { snapshot.tags[id, default: []].append(pair) }
            } else if let id = gameEntityId(text) {
                snapshot.gameEntity = id
                current = id
                snapshot.tags[id] = []
                snapshot.order.append(id)
            } else if let player = playerEntity(text) {
                snapshot.players[player.playerId] = player.entityId
                current = player.entityId
                snapshot.tags[player.entityId] = []
                snapshot.order.append(player.entityId)
            } else if body.first != " ", let full = fullEntity(text), let id = full.id {
                current = id
                snapshot.tags[id] = []
                snapshot.cards[id] = full.cardId
                snapshot.order.append(id)
            } else {
                break
            }
            index += 1
        }
        snapshot.headerEnd = index
        return snapshot
    }

    // MARK: - 行解析

    private static func isCreateGame(_ line: String) -> Bool {
        line.contains(powerPrefix + "CREATE_GAME")
    }

    private static func body(_ line: String) -> Substring? {
        guard let range = line.range(of: powerPrefix) else { return nil }
        return line[range.upperBound...]
    }

    private static func timestamp(_ line: String) -> String {
        guard let range = line.range(of: " GameState.") else { return "D 00:00:00.0000000" }
        return String(line[..<range.lowerBound])
    }

    private static func playerName(_ line: String) -> (id: Int, name: String)? {
        guard let range = line.range(of: "GameState.DebugPrintGame() - PlayerID=") else { return nil }
        let rest = line[range.upperBound...]
        guard let comma = rest.range(of: ", PlayerName="), let id = Int(rest[..<comma.lowerBound]) else { return nil }
        return (id, rest[comma.upperBound...].trimmingCharacters(in: .whitespaces))
    }

    fileprivate static func bracketId(_ ref: String) -> Int? {
        guard let range = ref.range(of: " id=") ?? ref.range(of: "[id=") else { return nil }
        return Int(ref[range.upperBound...].prefix { $0.isNumber })
    }

    private static func tagValue(_ text: String) -> (tag: String, value: String)? {
        guard text.hasPrefix("tag="), let value = text.range(of: " value=") else { return nil }
        let tag = String(text[text.index(text.startIndex, offsetBy: 4)..<value.lowerBound])
        let rest = text[value.upperBound...]
        return (tag, String(rest.prefix { $0 != " " }))
    }

    private static func gameEntityId(_ text: String) -> Int? {
        guard text.hasPrefix("GameEntity EntityID=") else { return nil }
        return Int(text.dropFirst("GameEntity EntityID=".count).prefix { $0.isNumber })
    }

    private static func playerEntity(_ text: String) -> (entityId: Int, playerId: Int)? {
        guard text.hasPrefix("Player EntityID="), let pid = text.range(of: " PlayerID=") else { return nil }
        let entity = text.dropFirst("Player EntityID=".count).prefix { $0.isNumber }
        let player = text[pid.upperBound...].prefix { $0.isNumber }
        guard let entityId = Int(entity), let playerId = Int(player) else { return nil }
        return (entityId, playerId)
    }

    private static func fullEntity(_ text: String) -> (id: Int?, ref: Substring?, cardId: String)? {
        guard let card = text.range(of: " CardID=", options: .backwards) else { return nil }
        let cardId = String(text[card.upperBound...])
        if text.hasPrefix("FULL_ENTITY - Creating ID=") {
            let id = text[text.index(text.startIndex, offsetBy: "FULL_ENTITY - Creating ID=".count)..<card.lowerBound]
            return (Int(id), nil, cardId)
        }
        if text.hasPrefix("FULL_ENTITY - Updating ") {
            let ref = text[text.index(text.startIndex, offsetBy: "FULL_ENTITY - Updating ".count)..<card.lowerBound]
            return (nil, ref, cardId)
        }
        return nil
    }

    private static func showEntity(_ text: String) -> (ref: Substring, cardId: String)? {
        let prefixes = ["SHOW_ENTITY - Updating Entity=", "CHANGE_ENTITY - Updating Entity="]
        guard let prefix = prefixes.first(where: { text.hasPrefix($0) }),
              let card = text.range(of: " CardID=", options: .backwards) else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        guard start <= card.lowerBound else { return nil }
        return (text[start..<card.lowerBound], String(text[card.upperBound...]))
    }

    private static func tagChange(_ text: String, prefix: String) -> (ref: Substring, tag: String, value: String)? {
        guard text.hasPrefix(prefix), let tagRange = text.range(of: " tag=", options: .backwards) else { return nil }
        let start = text.index(text.startIndex, offsetBy: prefix.count)
        guard start <= tagRange.lowerBound,
              let pair = tagValue(String(text[text.index(after: tagRange.lowerBound)...])) else { return nil }
        return (text[start..<tagRange.lowerBound], pair.tag, pair.value)
    }
}
