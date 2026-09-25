//
//  MinionPoolCompat.swift
//  HSTracker
//
//  HSTracker 3.6.13 reads the Battlegrounds minion pool through HearthMirror
//  1a6012b5, which HearthSim has not published on libs.hearthsim.net. Until it
//  is available this build pins HearthMirror 912e88ea and provides these types
//  locally; getBattlegroundsMinionPool() returns nil, so BattlegroundsDb falls
//  back to the assembled database as it did before 3.6.13.
//
//  To remove: set HearthMirror-version.txt back to
//  1a6012b545ba7af09afc14da3cd8286986c996f1, delete this file, and restore
//  `mirror?.getBattlegroundsMinionPool()` in MirrorHelper.
//

import Foundation

class MirrorBattlegroundsMinionPoolEntry: NSObject {
    var dbfId: Int = 0
    var tier: Int = 0
    var cardType: Int = 0
    var minionTypes: [NSNumber] = []
    var banned: Bool = false
}

class MirrorBattlegroundsMinionPool: NSObject {
    var cards: [MirrorBattlegroundsMinionPoolEntry] = []
    var activeMinionTypes: [NSNumber] = []
}
