# 同步原版 HSTracker

本仓库的 `main` 分支 = 原版 HSTracker 的某个版本 tag + CHS 保留的提交 + HSBG 整合提交。只跟随 `upstream`（HearthSim/HSTracker），不再跟随 `hstracker-chs`（alamo68/HSTracker_CHS）。同步后 `git push --force-with-lease origin main` 推回自己的仓库。已开启 `rerere`，解决过的冲突会被记住。

```sh
git switch main
git status                          # 必须是干净的工作区
git tag pre-<新版本> HEAD            # 回退点
git fetch upstream --tags
git rebase <新版本 tag>              # 例如 3.6.14
# 冲突：Swift/xib 手工合并；project.pbxproj 两侧文件条目都保留，
# MACOSX_DEPLOYMENT_TARGET 保持 14.0，MARKETING_VERSION 取上游新值
git add <文件> && git rebase --continue
```

同步后必须在 Xcode 构建，并运行 `HSBGSkip` 的 `swift test`、`LogReaderTests`、`ReplayUploadTests`，再按 `hsbg-integration-acceptance.md` 实打一局拔线。重点检查上游对 `Game.swift`、`LogReader(Manager).swift`、`CoreManager.swift`、`LogUploader.swift` 的改动是否影响重连恢复与日志存档；3.6.10 同步时曾丢失过重连补丁。出问题可 `git rebase --abort`，或 `git reset --hard pre-<新版本>` 回退。

## 记录

- 2026-09-25：3.6.12 → 3.6.13。冲突仅在 `AppDelegate.swift`（上游移除 `Preferences` 导入、调整 `completeSetup` 时机）和 `project.pbxproj`（新增 `RewoundEntityCreationFilter.swift`、版本号）。上游新增 Semi-Stable Portal 回溯重置，为此让存档日志只用于重连或中途启动的对局上传。
- 2026-10-12：3.6.13 → 3.6.14。上游移除 PromiseKit（改 async/await）和 GzipSwift 等包：`LogUploader.swift` 保留本仓库的上传记录逻辑，改用 `import zlib` 和上游的 `Data.gzipped()`；`Http.swift` 用上游的 `uploadAsync`/`getAsync`，保留 `transportSummary` 日志。`BattlegroundsSessionViewModel` 上游把首局计算移到调用处，改为 `sessionGames.first(where: { !$0.isIncomplete })`。上游 HearthMirror `ec7b1d7e` 已公开，丢弃 `2cd1c7ce`（钉住 912e88ea 与 `MinionPoolCompat.swift`），本地 `local/hearthmirror-1a6012b5` 分支随之作废。
- 2026-10-14：3.6.14 → 3.7.0。冲突在 `Localizable.xcstrings`（上游补全德语，与本仓库的 zh-Hans/zh-Hant 条目同处，两侧都保留）和 `project.pbxproj`（版本号）。上游对 `Game.swift` 的改动只涉及 Tier7 面板 `softReset()` 和 `hoveredCard` 移到主线程，不影响重连恢复与日志存档。新增的 HSReplay 登录失败对话框和「No deck selected.」补了 zh-Hans。xcstrings 冲突可按 JSON 三方合并（以 base/ours/theirs 三个暂存版本逐个本地化条目合并），比手工改冲突标记可靠。
- 2026-10-21：3.7.0 → 3.7.1。冲突在 `AppDelegate.swift`（上游新增清理 `tavern_markers_panel_expanded`，本仓库已删 Sparkle 的 `SUFeedURL` 清理，只保留前者）、`project.pbxproj`（版本号；上游去掉 `OTHER_CODE_SIGN_FLAGS = "--deep"`，随上游）、`MirrorHelper.swift`（上游把初始化移到 `initQueue` 并加 `stateLock`，本仓库的 5 秒重试节流 `nextMirrorAttempt` 挪进 `initIfNeeded()` 并归 `stateLock` 保护）、`BattlegroundsLastGames.swift`（上游加锁、`games` 改为 private，保留本仓库的 `incomplete` 和无账号也记录）、`BattlegroundsGameRowViewModel.swift`（上游加本地化英雄简称，外面包一层本仓库的「未知英雄（不完整）」分支），以及 `BattlegroundsPreferences.xcstrings`（上游 #1435 自带 zh-Hans，按 JSON 三方合并，仅鲍勃助手、对局回顾、流派统计 4 条保留本仓库用词以与其他目录一致，其余用上游）。上游 `Game.swift` 的改动（Tier7 试用改为回菜单后刷新、组装牌相关卡牌、英雄面板提前更新）不涉及重连恢复与日志存档。3.7.1 新增的本地化 key 均已有 zh-Hans。
