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
