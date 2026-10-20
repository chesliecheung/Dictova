import AppKit
import Foundation

@MainActor
final class ConversionModel: ObservableObject {
    @Published var sourceURL: URL?
    @Published var selectedFiles: [URL] = []
    @Published var outputURL: URL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    @Published var dictionaryName = ""
    @Published var installAfterConversion = false
    @Published var keepResources = true
    @Published var isRunning = false
    @Published var progress = 0.0
    @Published var status = "选择一个 MDX 文件开始"
    @Published var log = ""
    @Published var resultURL: URL?
    @Published var resultByteCount: Int64?
    @Published var installedURL: URL?
    @Published var isInstalling = false
    @Published var isCheckingEnvironment = false
    @Published var environmentReport = ""
    @Published var environmentReady: Bool?
    @Published var nativeDictionaryCount = 0
    @Published var errorMessage: String?

    private var process: Process?
    private var outputRemainder = ""
    private var activity: NSObjectProtocol?

    var companionSummary: String {
        guard let sourceURL else { return "支持 .mdx + .mdd/.1.mdd/.2.mdd… + .css" }
        let files = selectedFiles.count > 1 ? selectedFiles : Self.companionFiles(for: sourceURL)
        let mdds = files.filter { $0.pathExtension.lowercased() == "mdd" }.count
        let css = files.contains { $0.pathExtension.lowercased() == "css" }
        let js = files.filter { $0.pathExtension.lowercased() == "js" }.count
        let source = selectedFiles.count > 1 ? "已选择" : "已自动发现"
        return "\(source) \(mdds) 个 MDD 资源卷" + (css ? "、CSS" : "") + (js > 0 ? "、\(js) 个 JS（转换时移除）" : "")
    }

    var selectedFilesSize: String {
        let bytes = selectedFiles.reduce(Int64(0)) { partial, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return partial + Int64(size)
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var resultSize: String? {
        resultByteCount.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["mdx", "mdd", "css", "js"].compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "可选择整个词典文件夹，或一次选择 1 个 MDX 及全部 MDD、CSS"
        if panel.runModal() == .OK { setSources(panel.urls) }
    }

    func setSource(_ url: URL) {
        setSources([url])
    }

    func setSources(_ urls: [URL]) {
        let supported = Self.expandSelection(urls)
        let mdxFiles = supported.filter { $0.pathExtension.lowercased() == "mdx" }
        guard mdxFiles.count == 1, let mdx = mdxFiles.first else {
            errorMessage = mdxFiles.isEmpty ? "所选文件中必须包含一个 .mdx 主文件。" : "一次转换只能选择一个 .mdx 主文件。"
            return
        }
        selectedFiles = supported.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        sourceURL = mdx
        dictionaryName = mdx.deletingPathExtension().lastPathComponent
        resultURL = nil
        resultByteCount = nil
        installedURL = nil
        status = "已就绪"
        log = ""
    }

    func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url { outputURL = url }
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(outputURL)
    }

    func revealSource() {
        guard let sourceURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([sourceURL])
    }

    func openSupportFolder() {
        let folder = Self.supportFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
        } catch {
            errorMessage = "无法打开组件目录：\(error.localizedDescription)"
        }
    }

    func openNativeDictionaryFolder() {
        let folder = Self.nativeDictionaryFolder
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(folder)
            refreshNativeDictionaryCount()
        } catch {
            errorMessage = "无法打开原生词典文件夹：\(error.localizedDescription)"
        }
    }

    func refreshNativeDictionaryCount() {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: Self.nativeDictionaryFolder,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        nativeDictionaryCount = contents.filter { $0.pathExtension.caseInsensitiveCompare("dictionary") == .orderedSame }.count
    }

    func checkEnvironment() {
        isCheckingEnvironment = true
        environmentReport = "正在检查…"
        environmentReady = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> (Bool, String) in
                let required = ["git", "python3", "xmllint", "xsltproc", "plutil"]
                let missing = required.filter { !Self.commandAvailable($0) }
                let rosetta = Self.processSucceeds("/usr/bin/arch", ["-x86_64", "/usr/bin/true"])
                let ddk = FileManager.default.fileExists(
                    atPath: Self.supportFolder.appendingPathComponent("Dictionary-Development-Kit/bin/build_dict.sh").path
                )
                let capacity = try? FileManager.default.homeDirectoryForCurrentUser.resourceValues(
                    forKeys: [.volumeAvailableCapacityForImportantUsageKey]
                ).volumeAvailableCapacityForImportantUsage
                let freeSpace = capacity.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "未知"
                var details: [String] = []
                details.append(missing.isEmpty ? "系统工具齐全" : "缺少：\(missing.joined(separator: ", "))")
                details.append(rosetta ? "Intel 兼容环境可用" : "需要安装 Rosetta 2")
                details.append(ddk ? "词典编译器已缓存" : "词典编译器将在首次转换时下载")
                details.append("可用空间 \(freeSpace)")
                return (missing.isEmpty && rosetta, details.joined(separator: " · "))
            }.value
            isCheckingEnvironment = false
            environmentReady = result.0
            environmentReport = result.1
        }
    }

    func start() {
        guard let sourceURL else {
            errorMessage = "请先选择 MDX 文件。"
            return
        }
        let cleanName = dictionaryName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            errorMessage = "请输入词典名称。"
            return
        }
        guard let script = Bundle.module.url(forResource: "converter", withExtension: "py") else {
            errorMessage = "应用资源不完整：找不到转换器。"
            return
        }

        isRunning = true
        progress = 0.01
        resultURL = nil
        resultByteCount = nil
        installedURL = nil
        errorMessage = nil
        log = ""
        outputRemainder = ""
        status = "正在启动…"
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "正在转换 MDict 词典"
        )

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var arguments = [
            "python3", script.path,
            "--mdx", sourceURL.path,
            "--name", cleanName,
            "--output", outputURL.path
        ]
        for resource in selectedFiles where resource != sourceURL {
            arguments.append(contentsOf: ["--resource", resource.path])
        }
        if installAfterConversion { arguments.append("--install") }
        if keepResources { arguments.append("--keep-resources") }
        task.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PYTHONUNBUFFERED"] = "1"
        task.environment = environment

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in self?.consume(text) }
        }
        task.terminationHandler = { [weak self] finished in
            pipe.fileHandleForReading.readabilityHandler = nil
            Task { @MainActor in
                guard let self else { return }
                self.consume("\n")
                self.isRunning = false
                self.process = nil
                self.finishActivity()
                if finished.terminationStatus == 0 {
                    self.progress = 1
                    self.status = self.installAfterConversion ? "转换并安装完成" : "转换完成"
                } else if finished.terminationReason == .uncaughtSignal {
                    self.status = "已取消"
                } else {
                    self.status = "转换失败"
                    self.errorMessage = "转换没有完成。详细原因已保留在日志中。"
                }
            }
        }

        do {
            try task.run()
            process = task
        } catch {
            isRunning = false
            finishActivity()
            status = "无法启动"
            errorMessage = error.localizedDescription
        }
    }

    func cancel() {
        process?.terminate()
        status = "正在取消…"
    }

    func revealResult() {
        guard let resultURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([resultURL])
    }

    func installResult() {
        guard let source = resultURL, FileManager.default.fileExists(atPath: source.path) else {
            errorMessage = "找不到转换结果，请重新转换。"
            return
        }
        isInstalling = true
        status = "正在导入原生词典…"
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                Result {
                    let manager = FileManager.default
                    let root = manager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries", isDirectory: true)
                    try manager.createDirectory(at: root, withIntermediateDirectories: true)
                    let destination = Self.uniqueInstallDestination(in: root, sourceName: source.lastPathComponent)
                    try manager.copyItem(at: source, to: destination)
                    try manager.setAttributes([.modificationDate: Date()], ofItemAtPath: root.path)
                    return destination
                }
            }.value
            isInstalling = false
            switch outcome {
            case .success(let destination):
                installedURL = destination
                status = "已导入原生词典"
                log += "已导入：\(destination.path)\n"
                refreshNativeDictionaryCount()
                openDictionaryApp()
            case .failure(let error):
                status = "导入失败"
                errorMessage = "无法导入词典：\(error.localizedDescription)"
            }
        }
    }

    func openDictionaryApp() {
        let candidates = [
            URL(fileURLWithPath: "/System/Applications/Dictionary.app"),
            URL(fileURLWithPath: "/Applications/Dictionary.app")
        ]
        guard let application = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            errorMessage = "词典已经导入，但没有找到系统“词典”App。"
            return
        }
        NSWorkspace.shared.openApplication(at: application, configuration: .init())
    }

    func copyLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(log, forType: .string)
        status = "日志已复制"
    }

    func clearLog() {
        log = ""
        status = resultURL == nil ? "日志已清空" : "转换完成"
    }

    func resetTask() {
        guard !isRunning && !isInstalling else { return }
        sourceURL = nil
        selectedFiles = []
        dictionaryName = ""
        resultURL = nil
        resultByteCount = nil
        installedURL = nil
        progress = 0
        status = "选择词典文件或文件夹开始"
        log = ""
        errorMessage = nil
    }

    private func consume(_ chunk: String) {
        outputRemainder += chunk.replacingOccurrences(of: "\r", with: "\n")
        let pieces = outputRemainder.components(separatedBy: "\n")
        outputRemainder = pieces.last ?? ""
        for line in pieces.dropLast() {
            if line.hasPrefix("::progress::") {
                let parts = line.components(separatedBy: "::")
                if parts.count >= 4, let value = Double(parts[2]) {
                    progress = min(max(value, 0), 1)
                    status = parts[3]
                }
            } else if line.hasPrefix("::result::") {
                let path = String(line.dropFirst("::result::".count))
                resultURL = URL(fileURLWithPath: path)
            } else if line.hasPrefix("::resultsize::") {
                let value = String(line.dropFirst("::resultsize::".count))
                resultByteCount = Int64(value)
            } else if line.hasPrefix("::installed::") {
                let path = String(line.dropFirst("::installed::".count))
                installedURL = URL(fileURLWithPath: path)
            } else if !line.isEmpty {
                log += line + "\n"
            }
        }
    }

    private func finishActivity() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    nonisolated private static func uniqueInstallDestination(in root: URL, sourceName: String) -> URL {
        let manager = FileManager.default
        let direct = root.appendingPathComponent(sourceName, isDirectory: true)
        guard manager.fileExists(atPath: direct.path) else { return direct }
        let base = (sourceName as NSString).deletingPathExtension
        let suffix = Int(Date().timeIntervalSince1970)
        return root.appendingPathComponent("\(base)-\(suffix).dictionary", isDirectory: true)
    }

    nonisolated private static var nativeDictionaryFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Dictionaries", isDirectory: true)
    }

    nonisolated private static var supportFolder: URL {
        let manager = FileManager.default
        let base = manager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let folder = base.appendingPathComponent("Dictova", isDirectory: true)
        let legacy = base.appendingPathComponent("MDictBridge", isDirectory: true)
        if manager.fileExists(atPath: legacy.path), !manager.fileExists(atPath: folder.path) {
            try? manager.moveItem(at: legacy, to: folder)
        }
        return folder
    }

    nonisolated private static func commandAvailable(_ command: String) -> Bool {
        processSucceeds("/usr/bin/env", ["which", command])
    }

    nonisolated private static func processSucceeds(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func expandSelection(_ urls: [URL]) -> [URL] {
        let supportedExtensions = Set(["mdx", "mdd", "css", "js"])
        var result: [URL] = []
        for url in urls {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isDirectory {
                let children = (try? FileManager.default.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
                result.append(contentsOf: children.filter { supportedExtensions.contains($0.pathExtension.lowercased()) })
            } else if supportedExtensions.contains(url.pathExtension.lowercased()) {
                result.append(url)
            }
        }
        return Array(Set(result)).sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    private static func companionFiles(for mdx: URL) -> [URL] {
        let directory = mdx.deletingLastPathComponent()
        let stem = mdx.deletingPathExtension().lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents.filter { url in
            let name = url.lastPathComponent
            return name == "\(stem).mdd" ||
                name.range(of: "^\(NSRegularExpression.escapedPattern(for: stem))\\.\\d+\\.mdd$", options: [.regularExpression, .caseInsensitive]) != nil ||
                name.caseInsensitiveCompare("\(stem).css") == .orderedSame
        }
    }
}
