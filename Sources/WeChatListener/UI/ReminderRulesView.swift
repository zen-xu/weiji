import SwiftUI

struct ReminderRulesView: View {
    @ObservedObject var model: AppModel
    @State private var editing: ReminderRule?
    @State private var editingSample: Message?
    @State private var error: String?
    @State private var editingRevision = "initial"

    private var rules: [ReminderRule] { model.reminderRules }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("提醒规则").font(.title2.bold())
                    Text("按多个维度关注消息，用角落浮窗轻提示。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("添加规则", systemImage: "plus") { edit(ReminderRule()) }
                    .disabled(rules.count >= ReminderRule.maximumRules)
            }.padding(20)
            Divider()
            if rules.isEmpty {
                ContentUnavailableView(
                    "关注重要消息", systemImage: "bell.badge",
                    description: Text("按发送者、会话和内容组合条件，例如“项目群里张三发来的紧急消息”。")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(rules) { rule in
                        HStack(alignment: .top, spacing: 12) {
                            Toggle(
                                "启用“\(rule.name)”",
                                isOn: Binding(
                                    get: { rule.isEnabled },
                                    set: { enabled in
                                        update(rule) { $0.isEnabled = enabled }
                                    })
                            ).labelsHidden().toggleStyle(.switch).controlSize(.small)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(rule.name).font(.headline)
                                Text(rule.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                            }
                            Spacer()
                            Button("编辑") { edit(rule) }
                            Menu {
                                Button("复制规则") {
                                    var copy = rule
                                    copy.id = UUID()
                                    copy.name = String(rule.name.prefix(75)) + " 副本"
                                    edit(copy)
                                }.disabled(rules.count >= ReminderRule.maximumRules)
                                Button("删除规则", role: .destructive) { save(rules.filter { $0.id != rule.id }) }
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .menuStyle(.borderlessButton).fixedSize().help("更多规则操作")
                        }.padding(.vertical, 8)
                    }
                }.listStyle(.inset)
            }
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle(
                    "命中时播放提示音",
                    isOn: Binding(get: { model.preferences.reminderSound ?? false }, set: model.setReminderSound))
                Text("仅在采集开启时生效。启动补扫、历史导入不会提醒；通知中无法识别的发送者或会话类型不参与匹配。")
                    .font(.caption).foregroundStyle(.secondary)
                if !model.isCollecting {
                    Label("采集已暂停，开启采集后规则才会生效。", systemImage: "pause.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let issue = model.reminderIssue {
                    Label(issue, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                }
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
        }.frame(minWidth: 640, maxWidth: .infinity, minHeight: 500, maxHeight: .infinity, alignment: .top)
            .weijiAccent()
            .sheet(item: $editing) { rule in
                ReminderRuleEditor(rule: rule, sample: editingSample, preview: { model.onPreviewReminder?($0) }) {
                    updated in
                    var next = rules
                    if let index = next.firstIndex(where: { $0.id == updated.id }) {
                        next[index] = updated
                    } else {
                        next.append(updated)
                    }
                    try model.saveReminderRules(next, expectedRevision: editingRevision)
                }
            }
            .onAppear {
                model.refreshReminderRules()
                consumeDraft()
            }
            .onChange(of: model.reminderDraft) { _, _ in consumeDraft() }
            .onChange(of: editing) { _, next in if next == nil { consumeDraft() } }
    }

    private func update(_ rule: ReminderRule, change: (inout ReminderRule) -> Void) {
        var next = rules
        guard let index = next.firstIndex(where: { $0.id == rule.id }) else { return }
        change(&next[index])
        save(next)
    }
    private func consumeDraft() {
        guard editing == nil, let draft = model.reminderDraft else { return }
        editingSample = model.reminderDraftSample
        model.reminderDraft = nil
        model.reminderDraftSample = nil
        model.refreshReminderRules()
        editingRevision = model.reminderRuleRevision
        editing = draft
    }
    private func edit(_ rule: ReminderRule) {
        editingSample = nil
        model.refreshReminderRules()
        editingRevision = model.reminderRuleRevision
        editing = rule
    }
    private func save(_ rules: [ReminderRule]) {
        do {
            try model.saveReminderRules(rules)
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct ReminderRuleEditor: View {
    @State var rule: ReminderRule
    var sample: Message? = nil
    var preview: (ReminderHit) -> Void
    var save: (ReminderRule) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var conversation = ""
    @State private var sender = ""
    @State private var bodyText = ""
    @State private var kind = "group"
    @State private var result: ReminderEvaluation?
    @State private var testing = false
    @State private var revision = 0
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑提醒规则").font(.title2.bold())
                Spacer()
                Toggle("启用", isOn: $rule.isEnabled).toggleStyle(.switch).controlSize(.small)
            }.padding(20)
            Form {
                Section {
                    TextField("规则名称", text: $rule.name, prompt: Text("例如：项目群的重要消息"))
                    Picker("触发方式", selection: $rule.matchAll) {
                        Text("满足以下全部条件（且）").tag(true)
                        Text("满足以下任一条件（或）").tag(false)
                    }
                }
                Section {
                    ForEach($rule.conditions) { $condition in
                        HStack(spacing: 8) {
                            Picker("字段", selection: $condition.field) {
                                ForEach(ReminderField.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            Picker("比较方式", selection: $condition.comparison) {
                                ForEach(ReminderComparison.allCases) { Text($0.label).tag($0) }
                            }.labelsHidden().frame(width: 130)
                            TextField(
                                condition.comparison.isRegex ? "例如：紧急|故障|告警" : "填写匹配值",
                                text: $condition.value
                            ).labelsHidden().textFieldStyle(.roundedBorder)
                                .accessibilityLabel("\(condition.field.label)匹配值")
                            Button {
                                rule.conditions.removeAll { $0.id == condition.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless).help("移除此条件").disabled(rule.conditions.count == 1)
                        }
                    }
                    Button("添加条件", systemImage: "plus") { rule.conditions.append(ReminderCondition()) }
                        .disabled(rule.conditions.count >= ReminderRule.maximumConditions)
                    Toggle("忽略英文字母大小写", isOn: $rule.ignoreCase)
                } header: {
                    Text("匹配条件")
                } footer: {
                    Text("会话指通知中的群聊、私聊或频道名称；会话类型填写“群聊”或“私聊”。正则使用 ICU 语法，例如 ^(张三|李四)$；内容按通知原文匹配。")
                }
                Section {
                    Toggle(
                        "设置安静时段",
                        isOn: Binding(
                            get: { rule.quietHours != nil },
                            set: {
                                rule.quietHours = $0 ? ReminderQuietHours() : nil
                            }))
                    if rule.quietHours != nil {
                        DatePicker("开始", selection: quietTime(start: true), displayedComponents: .hourAndMinute)
                        DatePicker("结束", selection: quietTime(start: false), displayedComponents: .hourAndMinute)
                    }
                    Picker("同一会话合并间隔", selection: $rule.minimumIntervalSeconds) {
                        ForEach(
                            Array(Set([0, 30, 60, 300, 900, 3600, rule.minimumIntervalSeconds])).sorted(), id: \.self
                        ) { seconds in
                            Text(
                                seconds == 0
                                    ? "即时提醒" : seconds < 60 || seconds % 60 != 0 ? "\(seconds) 秒" : "\(seconds / 60) 分钟"
                            ).tag(
                                seconds)
                        }
                    }
                } header: {
                    Text("提醒节奏")
                } footer: {
                    Text("按 Mac 本地时间生效。安静时段内只存入收件箱，结束后合并提示；间隔内同一规则、同一会话的消息合并提醒，其他会话不受影响。")
                }
                Section("测试规则") {
                    TextField("会话 / 频道", text: $conversation, prompt: Text("输入一个示例会话名称"))
                    TextField("发送者", text: $sender, prompt: Text("留空代表通知未提供"))
                    Picker("会话类型", selection: $kind) {
                        Text("群聊").tag("group")
                        Text("私聊").tag("direct")
                        Text("未知").tag("unknown")
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("消息内容").font(.callout).foregroundStyle(.secondary)
                        TextEditor(text: $bodyText).font(.body).frame(height: 70)
                            .accessibilityLabel("测试消息内容")
                    }
                    HStack {
                        Button(testing ? "正在测试…" : "测试匹配", action: test).disabled(testing)
                        if let result {
                            if let issue = result.issues.first {
                                Text(issue).foregroundStyle(.orange)
                            } else if let hit = result.hits.first {
                                Label("匹配成功", systemImage: "checkmark.circle.fill").foregroundStyle(
                                    AppAppearance.accent)
                                Spacer()
                                Button("预览提示窗") { preview(hit) }
                            } else {
                                Label("未匹配", systemImage: "minus.circle").foregroundStyle(.secondary)
                            }
                        }
                    }.font(.callout)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                if let error { Text(error).font(.callout).foregroundStyle(.red) }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    do {
                        rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
                        try rule.validate()
                        try save(rule)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 720, height: 680).weijiAccent()
            .onAppear {
                if let sample {
                    conversation = sample.conversationName
                    sender = sample.senderDisplayName ?? ""
                    bodyText = sample.body
                    kind = sample.conversationKind
                }
            }
            .onChange(of: rule) { _, _ in invalidateTest() }
            .onChange(of: [conversation, sender, bodyText, kind]) { _, _ in invalidateTest() }
    }

    private func quietTime(start: Bool) -> Binding<Date> {
        Binding(
            get: {
                let minutes = start ? rule.quietHours?.startMinute ?? 1320 : rule.quietHours?.endMinute ?? 480
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())
                    ?? Date()
            },
            set: { date in
                let c = Calendar.current.dateComponents([.hour, .minute], from: date)
                let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
                if start { rule.quietHours?.startMinute = minute } else { rule.quietHours?.endMinute = minute }
            })
    }
    private func invalidateTest() {
        revision += 1
        result = nil
        testing = false
        error = nil
    }
    private func test() {
        do { try rule.validate() } catch {
            self.error = error.localizedDescription
            return
        }
        testing = true
        error = nil
        let token = revision
        var sample = NotificationDecoder.make(
            record: 0, title: conversation, subtitle: sender, body: bodyText,
            chat: kind == "group" ? "reminder-example@chatroom" : "reminder-example",
            identity: "reminder-preview-\(UUID())", delivered: Date(), captured: Date())
        sample.senderDisplayName = NotificationDecoder.nonempty(sender)
        sample.conversationKind = kind
        var enabledRule = rule
        enabledRule.isEnabled = true
        Task {
            var tested = await ReminderProcessor.test(sample, rule: enabledRule)
            guard revision == token else { return }
            for index in tested.hits.indices { tested.hits[index].isPreview = true }
            result = tested
            testing = false
        }
    }
}
