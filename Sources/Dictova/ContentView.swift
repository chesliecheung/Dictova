import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum AppSection: String, CaseIterable, Identifiable {
    case convert = "转换"
    case tools = "工具"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var model = ConversionModel()
    @State private var section: AppSection = .convert
    @State private var showLog = false
    @State private var isDropTarget = false

    var body: some View {
        ZStack {
            FrostedBackground()
            ambientLight

            VStack(spacing: 0) {
                compactToolbar
                Divider().opacity(0.45)

                Group {
                    switch section {
                    case .convert: conversionPage
                    case .tools: toolsPage
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .background(WindowConfigurator())
        .alert("提示", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onAppear { model.refreshNativeDictionaryCount() }
    }

    private var ambientLight: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.13))
                    .frame(width: 280, height: 280)
                    .blur(radius: 78)
                    .offset(x: geometry.size.width * 0.38, y: -geometry.size.height * 0.32)
                Circle()
                    .fill(Color.indigo.opacity(0.08))
                    .frame(width: 240, height: 240)
                    .blur(radius: 82)
                    .offset(x: -geometry.size.width * 0.43, y: geometry.size.height * 0.38)
            }
        }
        .allowsHitTesting(false)
    }

    private var compactToolbar: some View {
        ZStack {
            Picker("", selection: $section) {
                ForEach(AppSection.allCases) { item in
                    Label(item.rawValue, systemImage: item == .convert ? "arrow.left.arrow.right" : "slider.horizontal.3")
                        .tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 168)
            .onChange(of: section) { _ in
                withAnimation(.easeOut(duration: 0.16)) { }
            }

            HStack {
                Spacer(minLength: 74)
                Spacer()
                Button { model.openNativeDictionaryFolder() } label: {
                    Image(systemName: "books.vertical")
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("打开原生词典文件夹（当前 \(model.nativeDictionaryCount) 本）")
            }
        }
        .padding(.leading, 76)
        .padding(.trailing, 16)
        .frame(height: 48)
        .background(.ultraThinMaterial.opacity(0.58))
    }

    private var conversionPage: some View {
        ScrollView {
            VStack(spacing: 11) {
                sourcePanel
                optionsPanel
                progressPanel
            }
            .padding(14)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var sourcePanel: some View {
        glassPanel {
            VStack(spacing: 9) {
                HStack(spacing: 12) {
                    Image(systemName: model.sourceURL == nil ? "doc.badge.plus" : "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(model.sourceURL == nil ? Color.accentColor : Color.white)
                        .frame(width: 36, height: 36)
                        .background(
                            model.sourceURL == nil ? Color.accentColor.opacity(0.12) : Color.green,
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.sourceURL?.lastPathComponent ?? "放入一本词典")
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(sourceSubtitle)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    if model.sourceURL != nil {
                        Button { model.revealSource() } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("在 Finder 中显示")
                    }

                    Button { model.chooseSource() } label: {
                        Label(model.sourceURL == nil ? "选择" : "更换",
                              systemImage: model.sourceURL == nil ? "plus" : "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .keyboardShortcut("o", modifiers: .command)
                    .disabled(model.isRunning)
                }

                HStack(spacing: 6) {
                    fileBadge("MDX", icon: "doc.text", active: model.sourceURL != nil, detail: model.sourceURL == nil ? nil : "1")
                    fileBadge("MDD", icon: "photo.stack", active: mddCount > 0, detail: mddCount == 0 ? nil : "\(mddCount)")
                    fileBadge("CSS", icon: "paintbrush", active: hasCSS, detail: nil)
                    Spacer()
                    Label("支持文件夹拖放", systemImage: "hand.draw")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(isDropTarget ? Color.accentColor : Color.clear,
                        style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            collectDroppedURLs(providers)
            return true
        }
    }

    private var sourceSubtitle: String {
        if model.selectedFiles.isEmpty { return "拖入文件夹，或选择 MDX、MDD 与 CSS" }
        return "\(model.companionSummary)  ·  \(model.selectedFilesSize)"
    }

    private var optionsPanel: some View {
        glassPanel {
            VStack(spacing: 9) {
                HStack(spacing: 10) {
                    optionLabel("textformat", "名称")
                    TextField("词典显示名称", text: $model.dictionaryName)
                        .textFieldStyle(.plain)
                        .disabled(model.isRunning)
                    Spacer(minLength: 2)
                }
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    optionLabel("folder", "输出")
                    Text(model.outputURL.path)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 2)
                    Button("更改") { model.chooseOutput() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(model.isRunning)
                }
                .padding(.horizontal, 9)
                .frame(height: 31)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 20) {
                    Toggle(isOn: $model.keepResources) {
                        Label("保留媒体", systemImage: "photo.on.rectangle")
                    }
                    Toggle(isOn: $model.installAfterConversion) {
                        Label("自动导入", systemImage: "square.and.arrow.down")
                    }
                    Spacer()
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .disabled(model.isRunning)
            }
        }
    }

    private var progressPanel: some View {
        glassPanel {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(model.status)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("\(Int(model.progress * 100))%")
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)

                if let result = model.resultURL {
                    HStack(spacing: 5) {
                        Text(result.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = model.resultSize { Text("· \(size)") }
                        Spacer()
                        if model.installedURL != nil {
                            Label("已导入", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }

                actionBar

                if showLog { logView }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 9) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { showLog.toggle() }
            } label: {
                Image(systemName: showLog ? "chevron.up" : "terminal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(showLog ? "收起日志" : "查看日志")

            if !model.log.isEmpty {
                Menu {
                    Button("复制日志") { model.copyLog() }
                    Button("清空日志") { model.clearLog() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .frame(width: 20)
            }

            Spacer()

            if model.resultURL != nil {
                Button { model.revealResult() } label: {
                    Label("Finder", systemImage: "folder")
                }
                    .controlSize(.small)
                if model.installedURL != nil {
                    Button { model.openDictionaryApp() } label: {
                        Label("打开词典", systemImage: "books.vertical")
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button { model.installResult() } label: {
                        Label("导入词典", systemImage: "square.and.arrow.down")
                    }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(model.isInstalling || model.isRunning)
                }
            }

            if model.isRunning {
                Button("取消", role: .cancel) { model.cancel() }
                    .controlSize(.small)
            } else {
                if model.sourceURL != nil {
                    Button("重置") { model.resetTask() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .disabled(model.isInstalling)
                }
                Button { model.start() } label: {
                    Label(model.resultURL == nil ? "开始转换" : "再次转换",
                          systemImage: model.resultURL == nil ? "arrow.right" : "arrow.clockwise")
                }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.sourceURL == nil || model.isInstalling)
            }
        }
    }

    private var logView: some View {
        ScrollView {
            Text(model.log.isEmpty ? "转换日志会显示在这里。" : model.log)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(height: 88)
        .background(Color.black.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var toolsPage: some View {
        ScrollView {
            VStack(spacing: 11) {
                toolRow(icon: "books.vertical.fill", tint: .blue,
                        title: "原生词典",
                        subtitle: "~/Library/Dictionaries · \(model.nativeDictionaryCount) 本") {
                    Button { model.openDictionaryApp() } label: {
                        Label("词典", systemImage: "arrow.up.forward.app")
                    }.controlSize(.small)
                    Button { model.openNativeDictionaryFolder() } label: {
                        Label("文件夹", systemImage: "folder")
                    }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }

                toolRow(icon: "checkmark.shield.fill", tint: .green,
                        title: "转换环境",
                        subtitle: model.environmentReport.isEmpty
                            ? "检查系统工具、Rosetta 与可用空间"
                            : model.environmentReport) {
                    Button(model.isCheckingEnvironment ? "检查中…" : "检查") {
                        model.checkEnvironment()
                    }
                    .controlSize(.small)
                    .disabled(model.isCheckingEnvironment || model.isRunning)
                }

                toolRow(icon: "externaldrive.fill", tint: .purple,
                        title: "本地文件",
                        subtitle: "转换结果和运行组件均保存在本机") {
                    Button("输出") { model.openOutputFolder() }.controlSize(.small)
                    Button("组件") { model.openSupportFolder() }.controlSize(.small)
                }

                glassPanel {
                    HStack(spacing: 12) {
                        toolIcon("lock.shield.fill", .secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("本地处理").font(.system(size: 13, weight: .semibold))
                            Text("词典内容不会上传；原文件不会被修改。危险脚本与属性会在转换时移除。")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var statusIcon: String {
        if model.isRunning { return "arrow.triangle.2.circlepath" }
        if model.installedURL != nil { return "checkmark.circle.fill" }
        if model.resultURL != nil { return "checkmark.seal.fill" }
        return "circle.dashed"
    }

    private var statusColor: Color {
        if model.installedURL != nil || model.resultURL != nil { return .green }
        if model.isRunning { return .accentColor }
        return .secondary
    }

    private var mddCount: Int {
        model.selectedFiles.filter { $0.pathExtension.lowercased() == "mdd" }.count
    }

    private var hasCSS: Bool {
        model.selectedFiles.contains { $0.pathExtension.lowercased() == "css" }
    }

    private func optionLabel(_ icon: String, _ title: String) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: 54, alignment: .leading)
    }

    private func fileBadge(_ title: String, icon: String, active: Bool, detail: String?) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(title)
            if let detail {
                Text(detail).fontWeight(.semibold)
            }
        }
        .font(.system(size: 9.5, weight: .medium))
        .foregroundStyle(active ? Color.accentColor : Color.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(
            active ? Color.accentColor.opacity(0.11) : Color.primary.opacity(0.04),
            in: Capsule()
        )
    }

    private func glassPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(12)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 0.7)
            }
            .shadow(color: Color.black.opacity(0.035), radius: 12, y: 5)
    }

    private func toolIcon(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 10))
    }

    private func toolRow<Actions: View>(
        icon: String, tint: Color, title: String, subtitle: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        glassPanel {
            HStack(spacing: 12) {
                toolIcon(icon, tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 8)
                actions()
            }
        }
    }

    private func collectDroppedURLs(_ providers: [NSItemProvider]) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    lock.lock()
                    urls.append(url)
                    lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { model.setSources(urls) }
    }
}

private struct FrostedBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
            window.title = "Dictova"
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) { }
}
