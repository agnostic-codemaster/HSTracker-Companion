# HSTracker Companion

面向酒馆战棋玩家的 macOS 记牌器：中文界面、禁用随从面板、Bob's Buddy、一键拔线，以及拔线重连后的对局追踪与 HSReplay 上传。拔线不需要 Clash、TUN 或代理。整合计划与验收范围见 [实施计划](docs/hsbg-companion-integration-plan.md)。

## 项目来源

本仓库不是从零开发，而是在以下三个开源项目的基础上整合修改而成：

| 项目 | 作者 | 在本仓库中的作用 |
| --- | --- | --- |
| [HSTracker](https://github.com/HearthSim/HSTracker) | HearthSim | 记牌器本体。当前基于 3.6.13。 |
| [HSTracker_CHS](https://github.com/alamo68/HSTracker_CHS) | alamo68 | 直接父仓库。本仓库沿用它的 git 历史，包括中文化、禁用随从面板、Bob's Buddy 中文面板、合并的左上角面板等修改。 |
| [hsbg-companion](https://github.com/zilinfg/hsbg-companion) | Zilin Fang | 拔线后端。它的连接识别与 pf 规则实现被移植为 `HSBGSkip` 守护进程，取代 HSTracker_CHS 原先基于 Clash 的拔线。 |

在此之上，本仓库新增了：用 HSBGSkip 本地服务替代 Clash 拔线、按局归档 Power.log 并在重启后续读、拔线重连后拼接多段日志再上传 HSReplay、上传结果记录与重试，以及停用上游自动更新。

同步上游时，`hstracker-chs` 远端指向 alamo68/HSTracker_CHS，`upstream` 远端指向 HearthSim/HSTracker。

## 主要功能

- 对局左上角合并面板提供「一键拔线」及当前禁用种族；也可使用「拔线」菜单、Dock 菜单或 `⌘⇧K`。
- 只在 `GameNetLogger.log` 记录的对局服务器地址与炉石进程实时连接唯一且精确匹配时执行拔线。对局外、日志缺失或连接有歧义时拒绝操作。每次断线 3 秒，两次操作至少间隔 8 秒。
- 重连后根据当前日志与 HearthMirror 恢复后续实时追踪。原始 Power 日志及读取位置保存在本机，以便重启后继续读取；客户端未产生的事件不会被补写。
- 对局历史会保留缺少英雄或名次等字段的酒馆战棋对局，并以「未知」「不完整」标识。HSReplay 上传结果可在「拔线 → HSReplay 上传记录」查看，网络失败可从菜单重试。

## 截图

![游戏内整体效果](docs/images/game-overlay.jpg)

![左上角面板](docs/images/top-left-panel.jpg)

![Bob's Buddy 中文面板](docs/images/bobs-buddy.jpg)

## 安装与拔线服务

最低支持 macOS 14。将构建好的 `HSTracker.app` 放入「应用程序」后，打开应用菜单「拔线 → 服务设置…」，选择「安装服务」，并在 macOS 管理员授权窗口中确认。应用包中已经包含 Intel 与 Apple Silicon 通用版本的独立 LaunchDaemon。之后可在同一入口检测、升级或卸载服务。

如果电脑中已有 HSBG Companion 的旧拔线服务，安装界面会提示迁移。安装程序先恢复并停用旧服务，再安装新服务；新服务未能通过启动和通信端口检查时，会恢复旧服务。迁移后不再依赖 Companion 的菜单栏应用。卸载整合版服务会清除它自己的 pf 规则。

进入实际对局后点击左上角「一键拔线」，或使用菜单、Dock 菜单和 `⌘⇧K`。服务只处理炉石对局连接；若检测不到唯一目标，菜单「拔线 → 检测拔线服务」会给出状态。必要时可选「立即恢复连接」。

首次安装后的真实对局检查步骤见 [验收记录](docs/hsbg-integration-acceptance.md)。

## 对局与上传记录

应用在自己的支持目录保存 `PowerLogArchive`、`BgsLastGames.json` 和 `ReplayUploadResults.json`。重连或重启后，只追踪仍可从日志及游戏取得的状态。HSReplay 上传候选由原始日志构造；多次 `CREATE_GAME` 时保留完整原始片段，并将可用后段标为「部分」。日志缺少起点或必要元数据时不发送，上传结果明确标为「完整」「部分」「被拒绝」或「待重试」。HSReplay 对残缺日志的接受结果取决于其服务端。

## 从源码构建

需要 macOS 14 或更新版本、Xcode，以及可用的 Swift Package Manager 依赖。执行：

```bash
xcodebuild -project HSTracker.xcodeproj -scheme HSTracker -configuration Release CODE_SIGNING_ALLOWED=NO build
```

HSTracker 3.6.13 依赖的 HearthMirror `1a6012b5` 尚未由 HearthSim 发布到 libs.hearthsim.net，因此本仓库暂时固定使用 `912e88ea`，并通过 `HSTracker/HearthMirror/MinionPoolCompat.swift` 关闭「从游戏读取酒馆随从池」功能，随从浏览器回退到内置数据库。等新版可下载后，按该文件顶部注释即可恢复。

构建阶段会分别编译 arm64 和 x86_64 的 `hsbgskipd`，合并后放入应用资源目录。用于本机安装时，运行 `Tools/package-local.sh <Release/HSTracker.app 路径>`，脚本会对整个应用包做临时签名并验证，再生成压缩包。直接使用 `CODE_SIGNING_ALLOWED=NO` 的构建产物会使 macOS 无法稳定识别应用的权限身份。临时签名仅保证同一构建在本机的身份一致；安装新的构建时仍可能需要重新授权。公开发布所需的开发者签名和公证不在本期范围内。为防止整合版被上游程序覆盖，上游自动更新已停用。

## 许可与致谢

本项目遵循仓库根目录 [LICENSE](LICENSE)（HSTracker 的 MIT 许可）。拔线后端保留 HSBG Companion 的 [MIT 许可声明](HSBGSkip/LICENSE)；其实现最初借鉴了 [hearthstone_skipper](https://github.com/z2z63/hearthstone_skipper) 的思路。感谢 HearthSim/HSTracker、alamo68/HSTracker_CHS、zilinfg/hsbg-companion 的作者，以及 LINUX DO 社区的贡献和反馈。
