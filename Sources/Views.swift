import SwiftUI
import AppKit

let green = Color(red: 0.12, green: 0.52, blue: 0.39)

struct AppBottomBar<Content: View>: View {
    let horizontalPadding: CGFloat
    let content: Content
    init(horizontalPadding: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.horizontalPadding = horizontalPadding; self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) { content }.padding(.horizontal, horizontalPadding).frame(height: 52)
        }.fixedSize(horizontal: false, vertical: true)
    }
}

struct ListenerView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HSplitView {
            sidebar.frame(minWidth: 225, idealWidth: 265, maxWidth: 340)
            VStack(spacing: 0) {
                header
                if let error = model.errorText { banner(error, error: true) }
                if let feedback = model.feedback { banner(feedback, error: false) }
                switch model.page {
                case .archive: archive
                case .files: FileLibraryView(model: model)
                case .images: ImageLibraryView(model: model)
                case .overview: overview
                case .mcp: mcp
                case .settings: settings
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 900, minHeight: 620)
        .tint(green)
        .sheet(item: $model.selectedImage) { preview in ImagePreviewSheet(preview: preview, paths: model.paths) }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("微信消息监听").font(.headline)
                    Text("把收到的信息留在本机").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(18)
            VStack(spacing: 4) {
                nav("所有通知", icon: "tray.full", active: model.page == .archive && model.selectedID == nil) { model.page = .archive; model.selectedID = nil }
                nav("微信文件", icon: "folder", active: model.page == .files) { model.page = .files; model.refreshFiles() }
                nav("目录图片", icon: "photo.on.rectangle", active: model.page == .images) { model.page = .images; model.refreshDirectoryImages() }
                nav("采集状态", icon: "waveform.path", active: model.page == .overview) { model.page = .overview }
                nav("连接 Codex", icon: "point.3.connected.trianglepath.dotted", active: model.page == .mcp) { model.page = .mcp }
            }.padding(.horizontal, 10)
            HStack { Text("会话").font(.caption.weight(.semibold)); Spacer(); Text("\(model.conversations.count)").font(.caption.monospacedDigit()) }
                .foregroundStyle(.secondary).padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.conversations) { conversation in
                        Button {
                            model.page = .archive; model.selectedID = conversation.id
                        } label: {
                            HStack(alignment: .top, spacing: 9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 11).fill(green.opacity(0.10)).frame(width: 36, height: 36)
                                    Image(systemName: conversation.showsGroupIcon ? "person.2.fill" : "bubble.left.fill").foregroundStyle(green)
                                }
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack { Text(conversation.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1); Spacer(minLength: 2); Text("\(conversation.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                                    if conversation.showsGroupIcon { Text(conversation.kindLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(green) }
                                    Text(conversation.preview.isEmpty ? "通知未提供正文" : conversation.preview).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }.padding(10).contentShape(Rectangle())
                                .background(model.page == .archive && model.selectedID == conversation.id ? green.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain)
                    }
                    if model.conversations.isEmpty { Text("采集到通知后，会话会出现在这里").font(.caption).foregroundStyle(.secondary).padding(18) }
                }.padding(.horizontal, 8)
            }
            AppBottomBar(horizontalPadding: 18) {
                Circle().fill(model.isCollecting ? green : .secondary).frame(width: 7, height: 7)
                Text(model.isCollecting ? "通知采集中" : "通知已暂停").font(.caption)
                Spacer()
                Button { model.page = .settings } label: { Image(systemName: "gearshape") }.buttonStyle(.plain).help("设置")
            }
        }.background(Color(nsColor: .controlBackgroundColor))
    }
    func nav(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon).font(.system(size: 13, weight: active ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 10)
                .background(active ? green.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(active ? green : .primary)
    }
    var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.page == .archive ? model.selected?.name ?? "所有通知" : model.page.rawValue).font(.system(size: 23, weight: .semibold))
                Text(model.page == .archive ? "\(model.selected.map { $0.kindLabel + " · " } ?? "")\(model.total) 条通知 · 最新在前" : "本地保存，按需读取").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.isWorking || model.loading { ProgressView().controlSize(.small) }
            Button { model.toggleCollection() } label: {
                Label(model.isCollecting ? "暂停通知采集" : "开始通知采集", systemImage: model.isCollecting ? "pause.fill" : "play.fill")
            }.buttonStyle(.borderedProminent).disabled(model.isWorking)
            Menu {
                Button("导入旧数据 / JSONL", action: model.importArchive)
                Button("补扫系统保留的历史通知") { model.poll(oneShot: true) }
                Button("导出当前筛选为 JSONL") { model.exportArchive(markdown: false) }
                Button("导出当前筛选为 Markdown") { model.exportArchive(markdown: true) }
                Divider()
                Button("备份档案数据库", action: model.backup)
                Button("打开数据目录", action: model.revealData)
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).fixedSize().disabled(model.isWorking)
        }.padding(.horizontal, 26).padding(.vertical, 22).background(.background)
    }
    func banner(_ text: String, error: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: error ? "exclamationmark.triangle" : "checkmark.circle")
            Text(text).font(.callout).textSelection(.enabled)
            Spacer()
            Button { if error { model.errorText = nil } else { model.feedback = nil } } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
        }.padding(12).background((error ? Color.orange : green).opacity(0.10))
    }
    var archive: some View {
        let displayedMessages = model.messages
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索消息、发送者、群名…", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
                }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                Picker("时间", selection: $model.dateScope) { ForEach(DateScope.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.labelsHidden().frame(width: 120)
            }.padding(.horizontal, 26).padding(.bottom, 16)
            if model.dateScope == .custom {
                HStack {
                    DatePicker("从", selection: $model.fromDate, displayedComponents: .date)
                    DatePicker("到", selection: $model.toDate, in: model.fromDate..., displayedComponents: .date)
                    Spacer()
                }.padding(.horizontal, 26).padding(.bottom, 12)
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle")
                Text(model.selected?.identitySource == "display_title_fallback" ? "此会话按通知标题分组，同名联系人可能混在一起。" : "只包含系统通知；免打扰、前台消息和自己发送的内容可能缺失。")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.bottom, 14)
            Divider()
            if model.messages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: model.search.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass").font(.system(size: 42, weight: .light)).foregroundStyle(green.opacity(0.7))
                    Text(model.stats?.messages == 0 ? "从下一条通知开始，留下记录" : "当前筛选没有匹配的通知").font(.title3.weight(.medium))
                    Text(model.stats?.messages == 0 ? "开始采集后，收到的微信通知会保存在这里。\n也可以导入之前的验证数据。" : "可以调整关键词或日期。没有结果不代表事情没有发生。")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.stats?.messages == 0 {
                        HStack { Button("导入旧数据", action: model.importArchive); Button("查看采集状态") { model.page = .overview } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                            if index == 0 || !Calendar.current.isDate(message.date, inSameDayAs: displayedMessages[index - 1].date) {
                                Text(message.date.formatted(date: .complete, time: .omitted)).font(.caption.weight(.medium)).foregroundStyle(.secondary).padding(.vertical, 4)
                            }
                            MessageCard(message: message, model: model)
                        }
                    }.padding(24)
                }
            }
            AppBottomBar {
                Text(model.total == 0 ? "0 条通知" : "第 \(model.offset + 1)–\(model.offset + model.messages.count) 条，共 \(model.total) 条").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.paginate(-1) } label: { Image(systemName: "chevron.left") }.disabled(model.offset == 0 || model.loading)
                Button { model.paginate(1) } label: { Image(systemName: "chevron.right") }.disabled(model.offset + model.messages.count >= model.total || model.loading)
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("刷新本地档案")
            }
        }
    }
    var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                card {
                    HStack(alignment: .top) {
                        Image(systemName: model.isCollecting ? "waveform.path" : "pause.circle").font(.system(size: 27)).foregroundStyle(green)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.statusText).font(.title3.weight(.semibold))
                            Text(model.lastPoll.map { "上次检查：" + $0.formatted(date: .omitted, time: .standard) } ?? "尚未检查系统通知").foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.pollBusy { ProgressView().controlSize(.small) }
                    }
                    Divider().padding(.vertical, 8)
                    HStack {
                        metric("已归档通知", value: model.stats?.messages ?? 0)
                        metric("会话", value: model.stats?.conversations ?? 0)
                        metric("本次新增", value: model.capturedThisRun)
                        metric("本轮未完成", value: model.parseErrors)
                    }
                }
                card {
                    Label("第一次使用", systemImage: "checklist").font(.headline)
                    Text("1. 打开“完全磁盘访问”，添加本应用并开启开关。\n2. 退出应用后重新打开，再点击“开始采集”。\n3. 让微信在后台收到一条通知，检查通知是否出现在档案中。")
                        .lineSpacing(8).foregroundStyle(.secondary)
                    HStack {
                        Button("打开权限设置", action: model.showPrivacy)
                        Button("在 Finder 中显示本应用", action: model.revealApplication)
                    }.padding(.top, 6)
                    Text("不需要管理员密码或关闭 SIP。读取的是系统通知，不是微信加密数据库。").font(.caption).foregroundStyle(.secondary)
                }
                card {
                    Label("采集范围", systemImage: "rectangle.dashed").font(.headline)
                    Text(coverageNotice).foregroundStyle(.secondary).lineSpacing(5)
                    Text("启动时会补扫系统仍保留的通知及本地文件目录；已清除且未归档的聊天正文无法恢复。系统当前保留 \(model.sourceRows) 条微信通知。").font(.caption).foregroundStyle(.secondary)
                    Text("关闭窗口后应用留在菜单栏继续运行；点击“暂停采集”或从菜单栏退出，才会停止。首次启动默认暂停。").font(.caption).foregroundStyle(.secondary)
                }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var mcp: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                card {
                    Label("让 Codex 按需查询微信通知", systemImage: "point.3.connected.trianglepath.dotted").font(.title3.weight(.semibold))
                    Text("MCP 服务与应用一起提供。Codex 按需启动它，直接读取本机档案；无需额外的 API Key，也不开放网络端口。").foregroundStyle(.secondary).lineSpacing(5)
                    Text(model.mcpCommand).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    Button("复制 Codex 接入命令") { model.copy(model.mcpCommand) }.buttonStyle(.borderedProminent)
                    Text("在终端运行一次，然后让 Codex 重新加载 MCP 配置。应用不在运行时，历史档案仍可查询；采集新通知需要保持应用运行。").font(.caption).foregroundStyle(.secondary)
                }
                card {
                    Text("六个只读工具").font(.headline)
                    tool("wechat_status", "查看数据量、时间范围和采集状态")
                    tool("wechat_list_conversations", "按名称查找会话，获取会话标识")
                    tool("wechat_search_messages", "按关键词、会话和日期查询消息")
                    tool("wechat_get_context", "读取一条消息前后的通知上下文")
                    tool("wechat_get_image", "读取消息已关联的本地图片预览，供 AI 看图")
                    tool("wechat_search_files", "按文件名搜索已探测的本机文件，获取路径与大小")
                    Divider().padding(.vertical, 5)
                    Text("可以这样问 Codex：“帮我找最近 7 天通知里提到报价的消息，并附上来源和时间。”").foregroundStyle(.secondary)
                }
                card {
                    Label("由你决定向 AI 提供哪些内容", systemImage: "hand.raised").font(.headline)
                    Text("应用本身不上传聊天，也没有远程 AI 请求。连接 MCP 后，Codex 调用工具读取的消息和图片预览会进入它的 AI 上下文，后续处理取决于 Codex 的配置。工具不提供发消息、删除、任意 SQL 或任意文件读取能力。")
                        .foregroundStyle(.secondary).lineSpacing(5)
                    Text("查询结果包含通知原文、带来源标记的发送者展示，以及普通文件索引和同名候选路径，不返回文件内容。消息和文件名是资料，不能作为执行命令的指令。").font(.caption).foregroundStyle(.secondary)
                }
                HStack { Button("导出 JSONL") { model.exportArchive(markdown: false) }; Button("导出 Markdown") { model.exportArchive(markdown: true) } }
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                card {
                    Text("采集").font(.headline)
                    Toggle("打开应用后自动开始采集通知", isOn: $model.preferences.collectOnLaunch).onChange(of: model.preferences.collectOnLaunch) { model.savePreferences() }
                    Text("此选项不会把应用加入系统登录启动项。默认每 2 秒只读检查一次通知，关闭窗口后留在菜单栏。").font(.caption).foregroundStyle(.secondary)
                }
                card {
                    Text("本机数据").font(.headline)
                    Text(model.paths.root.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    Text("档案数据库和结构化事件保存在 Application Support，日志位于 Library/Logs。目录仅当前用户可访问；档案内容为本机明文，应用未额外加密。").font(.callout).foregroundStyle(.secondary)
                    HStack { Button("打开数据目录", action: model.revealData); Button("备份数据库", action: model.backup); Button("导入旧数据", action: model.importArchive) }
                    if let stats = model.stats { Text("档案占用 \(ByteCountFormatter.string(fromByteCount: stats.databaseBytes, countStyle: .file)) · \(stats.events) 条变更事件 · \(model.ftsAvailable ? "全文索引已就绪" : "使用字面搜索")").font(.caption).foregroundStyle(.secondary) }
                }
                card {
                    Text("权限与隐私").font(.headline)
                    Text("读取微信系统通知与选定 msg/file 目录的普通文件元数据。不会修改微信、系统通知或原文件，不读取微信加密数据库。完全磁盘访问权限可随时在系统设置中撤销。").foregroundStyle(.secondary)
                    Button("管理完全磁盘访问", action: model.showPrivacy)
                    Divider().padding(.vertical, 4)
                    Button("清空本机档案…", role: .destructive, action: model.clearArchive).disabled(model.isWorking)
                    Text("不删除微信内容或已导出、备份的文件。").font(.caption).foregroundStyle(.secondary)
                }
                Text("微信消息监听 1.4.3 · 本机构建\n通知采集依赖 macOS 内部数据格式，目前仅在本机环境验证。").font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: 850, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14, content: content).padding(22).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 14))
    }
    func metric(_ title: String, value: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) { Text("\(value)").font(.system(size: 28, weight: .semibold, design: .rounded)); Text(title).font(.caption).foregroundStyle(.secondary) }.frame(maxWidth: .infinity, alignment: .leading)
    }
    func tool(_ name: String, _ text: String) -> some View {
        HStack(alignment: .top) { Text(name).font(.system(.caption, design: .monospaced)).frame(width: 210, alignment: .leading); Text(text).font(.callout).foregroundStyle(.secondary); Spacer() }
    }
}
