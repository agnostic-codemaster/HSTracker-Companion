import AppKit
import Darwin

// The UI talks only to this small unprivileged client. HSTracker never runs pfctl itself.
private enum SkipServiceError: LocalizedError {
    case unavailable
    case incompatible
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/com.local.hstracker-chs-skipd")
                ? "拔线服务已安装但未运行，请在「拔线 → 服务设置」中升级"
                : "拔线服务未安装，请在「拔线 → 服务设置」中安装"
        case .incompatible: return "拔线服务版本不兼容，请在「拔线 → 服务设置」中升级"
        case .transport(let message): return message
        }
    }
}

private struct SkipServiceResponse: Decodable {
    let protocolVersion: Int
    let ok: Bool
    let target: String?
    let blocking: Bool?
    let error: String?
}

private enum SkipServiceClient {
    static let socketPath = "/var/run/hstracker-chs-skip.sock"
    static let protocolVersion = 1

    static func send(_ command: String) throws -> SkipServiceResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SkipServiceError.transport("无法创建本地连接") }
        defer { close(fd) }

        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(socketPath.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SkipServiceError.transport("本地连接路径过长")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: path) }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw SkipServiceError.unavailable }

        let request = command == "skip"
            ? "{\"command\":\"skip\",\"duration\":3}\n"
            : "{\"command\":\"\(command)\"}\n"
        let bytes = Array(request.utf8)
        try bytes.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard count > 0 else { throw SkipServiceError.transport("发送请求失败") }
                sent += count
            }
        }

        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A), response.count <= 16_384 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            response.append(contentsOf: buffer.prefix(count))
        }
        guard response.contains(0x0A), response.count <= 16_384 else {
            throw SkipServiceError.transport("拔线服务没有返回有效响应")
        }
        let line = Data(response.prefix { $0 != 0x0A })
        let decoded = try JSONDecoder().decode(SkipServiceResponse.self, from: line)
        guard decoded.protocolVersion == protocolVersion else { throw SkipServiceError.incompatible }
        return decoded
    }
}

final class SkipServiceController: NSObject {
    private static let installedBinary = "/Library/PrivilegedHelperTools/com.local.hstracker-chs-skipd"
    private static let legacyBinary = "/usr/local/libexec/hsbgskipd"

    private var busy = false
    private var menuInstalled = false
    private var dockMenuInstalled = false
    var onFeedback: ((String) -> Void)?

    func setup() { installMainMenu() }

    func installDockMenu(_ menu: NSMenu) {
        guard !dockMenuInstalled else { return }
        dockMenuInstalled = true
        menu.addItem(.separator())
        let skip = NSMenuItem(title: "一键拔线", action: #selector(doSkip), keyEquivalent: "")
        skip.target = self
        menu.addItem(skip)
        let service = NSMenuItem(title: "拔线服务设置", action: #selector(showServiceSettings), keyEquivalent: "")
        service.target = self
        menu.addItem(service)
    }

    func skipNow() { doSkip() }

    private func installMainMenu() {
        guard !menuInstalled, let mainMenu = NSApp.mainMenu else { return }
        menuInstalled = true
        let item = NSMenuItem(title: "拔线", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "拔线")
        let skip = NSMenuItem(title: "一键拔线", action: #selector(doSkip), keyEquivalent: "k")
        skip.keyEquivalentModifierMask = [.command, .shift]
        skip.target = self
        menu.addItem(skip)
        let status = NSMenuItem(title: "检测拔线服务", action: #selector(checkService), keyEquivalent: "")
        status.target = self
        menu.addItem(status)
        let restore = NSMenuItem(title: "立即恢复连接", action: #selector(restoreConnection), keyEquivalent: "")
        restore.target = self
        menu.addItem(restore)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "服务设置…", action: #selector(showServiceSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let uploads = NSMenuItem(title: "HSReplay 上传记录…", action: #selector(showUploadResults), keyEquivalent: "")
        uploads.target = self
        menu.addItem(uploads)
        let retry = NSMenuItem(title: "重试待上传对局", action: #selector(retryUploads), keyEquivalent: "")
        retry.target = self
        menu.addItem(retry)
        item.submenu = menu
        let names = ["Window", "窗口", "Help", "帮助"]
        if let index = mainMenu.items.firstIndex(where: { names.contains($0.title) }) {
            mainMenu.insertItem(item, at: index)
        } else {
            mainMenu.addItem(item)
        }
    }

    @objc private func doSkip() {
        guard !busy else { onFeedback?("正在拔线…"); return }
        busy = true
        onFeedback?("拔线中…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try SkipServiceClient.send("skip") }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let response):
                    if response.ok {
                        self.onFeedback?("✓ 已断开")
                        Toast.show(title: "一键拔线", message: "已发送断线请求；炉石正在重新连接", duration: 4)
                    } else {
                        self.onFeedback?("✗ 失败")
                        Toast.show(title: "拔线失败", message: response.error ?? "未知错误", duration: 4)
                    }
                case .failure(let error):
                    self.onFeedback?("✗ 失败")
                    Toast.show(title: "拔线失败", message: error.localizedDescription, duration: 4)
                }
            }
        }
    }

    @objc private func checkService() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SkipServiceClient.send("status") }
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    let message = response.blocking == true
                        ? "服务运行中，正在拔线"
                        : (response.ok ? "服务就绪，对局连接：\(response.target ?? "未知")"
                           : "服务运行中；\(response.error ?? "尚未进入对局")")
                    Toast.show(title: "拔线服务", message: message, duration: 5)
                case .failure(let error):
                    Toast.show(title: "拔线服务", message: error.localizedDescription, duration: 5)
                }
            }
        }
    }

    @objc private func restoreConnection() {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try SkipServiceClient.send("restore") }
            DispatchQueue.main.async {
                switch result {
                case .success(let response):
                    Toast.show(title: "恢复连接", message: response.ok ? "已清除拔线规则" : (response.error ?? "失败"), duration: 4)
                case .failure(let error):
                    Toast.show(title: "恢复连接", message: error.localizedDescription, duration: 4)
                }
            }
        }
    }

    @objc private func showServiceSettings() {
        let installed = FileManager.default.fileExists(atPath: Self.installedBinary)
        let legacy = FileManager.default.fileExists(atPath: Self.legacyBinary) ||
            FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/com.local.hsbgskipd.plist")
        let alert = NSAlert()
        alert.messageText = "拔线服务"
        alert.informativeText = installed
            ? "拔线服务已安装。升级会短暂重启服务；卸载会清除拔线规则。"
            : "首次使用需要管理员授权安装拔线服务。\(legacy ? "检测到旧版 companion 服务；安装时会先停用并替换它。" : "")"
        alert.addButton(withTitle: installed ? "升级服务" : "安装服务")
        if installed { alert.addButton(withTitle: "卸载服务") }
        alert.addButton(withTitle: "取消")
        let choice = alert.runModal()
        if choice == .alertFirstButtonReturn {
            runInstaller(action: "install")
        } else if installed && choice == .alertSecondButtonReturn {
            runInstaller(action: "uninstall")
        }
    }

    @objc private func showUploadResults() {
        let alert = NSAlert()
        alert.messageText = "HSReplay 上传记录"
        alert.informativeText = ReplayUploadStore.shared.summary()
        alert.addButton(withTitle: "关闭")
        alert.runModal()
    }

    @objc private func retryUploads() {
        LogUploader.retryPending()
        Toast.show(title: "HSReplay", message: "已开始重试待上传对局，可在上传记录中查看结果", duration: 5)
    }

    private func runInstaller(action: String) {
        guard !busy else { return }
        guard let script = Bundle.main.resourceURL?.appendingPathComponent("Resources/hsbgskip-install.sh"),
              FileManager.default.isReadableFile(atPath: script.path) else {
            Toast.show(title: "拔线服务", message: "应用包缺少服务安装文件", duration: 5)
            return
        }
        busy = true
        let command = """
        on run argv
            set scriptPath to item 1 of argv
            set actionName to item 2 of argv
            do shell script ("/bin/sh " & quoted form of scriptPath & " " & quoted form of actionName) with administrator privileges
        end run
        """
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", command, script.path, action]
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            let result: String
            do {
                try process.run()
                process.waitUntilExit()
                let message = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                result = process.terminationStatus == 0 ? "操作已完成" : "操作失败：\(message.trimmingCharacters(in: .whitespacesAndNewlines))"
            } catch {
                result = "无法启动安装程序：\(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                self?.busy = false
                Toast.show(title: "拔线服务", message: result, duration: 6)
            }
        }
    }
}
