import SwiftUI

struct MessageArchiveView: View {
    @ObservedObject var model: AppModel
    @State private var showingCoverage = false

    var body: some View {
        let messages = model.messages
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack {
                    Picker("时间范围", selection: $model.dateScope) {
                        ForEach(DateScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.labelsHidden().frame(width: 130)
                    if model.selected?.identitySource == "display_title_fallback" {
                        Text("按通知标题分组").font(.caption).foregroundStyle(.secondary)
                            .help("缺少可靠的会话标识，同名联系人可能出现在同一分组中。")
                    }
                    Spacer()
                    if model.loading { ProgressView().controlSize(.small).accessibilityLabel("正在读取通知") }
                    Button {
                        showingCoverage.toggle()
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless).help("通知覆盖范围").accessibilityLabel("通知覆盖范围")
                    .popover(isPresented: $showingCoverage) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("关于通知档案").font(.headline)
                            Text(NotificationCoverage.notice).foregroundStyle(.secondary)
                        }.padding(20).frame(width: 340)
                    }
                }
                if model.dateScope == .custom {
                    HStack {
                        DatePicker("从", selection: $model.fromDate, displayedComponents: .date)
                        DatePicker("到", selection: $model.toDate, in: model.fromDate..., displayedComponents: .date)
                        Spacer()
                    }
                }
            }.controlSize(.small).padding(.horizontal, 20).padding(.vertical, 10)
            Divider()
            if model.loading && messages.isEmpty {
                ProgressView("正在打开本地档案…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                ContentUnavailableView {
                    Label(
                        model.stats?.messages == 0 ? "尚无通知" : "没有匹配的通知",
                        systemImage: model.search.isEmpty ? "tray" : "magnifyingglass")
                } description: {
                    Text(model.stats?.messages == 0 ? "开始采集后，收到的微信和飞书通知会保存在这里。" : "试试其他关键词或时间范围。")
                } actions: {
                    if !model.search.isEmpty || model.dateScope != .all {
                        Button("清除筛选") {
                            model.search = ""
                            model.dateScope = .all
                        }
                    } else if model.stats?.messages == 0 {
                        Button("查看采集状态") { model.page = .overview }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            if index == 0
                                || !Calendar.current.isDate(message.date, inSameDayAs: messages[index - 1].date)
                            {
                                Text(dayTitle(message.date)).font(.subheadline.weight(.semibold)).foregroundStyle(
                                    .secondary
                                )
                                .padding(.top, index == 0 ? 8 : 20).padding(.bottom, 4)
                            } else {
                                Divider()
                            }
                            MessageRow(message: message, model: model)
                        }
                    }.frame(maxWidth: 880, alignment: .leading).padding(.horizontal, 24).padding(.bottom, 20)
                        .frame(maxWidth: .infinity)
                }.id(scrollPosition)
            }
            AppBottomBar {
                Text(
                    LibraryPresentation.range(
                        offset: model.offset, count: messages.count, total: model.total, unit: "条通知")
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Text("仅系统通知").font(.caption).foregroundStyle(.tertiary).help(NotificationCoverage.notice)
                Spacer()
                LibraryPageControls(
                    offset: model.offset, count: messages.count, total: model.total, isLoading: model.loading,
                    previous: { model.paginate(-1) }, next: { model.paginate(1) })
            }
        }.background(.background)
    }

    private var scrollPosition: [String] {
        [
            model.selectedID ?? "", String(model.offset), model.search, model.dateScope.rawValue,
            model.dateScope == .custom ? Dates.string(model.fromDate) : "",
            model.dateScope == .custom ? Dates.string(model.toDate) : "",
        ]
    }

    private func dayTitle(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "今天" }
        if Calendar.current.isDateInYesterday(date) { return "昨天" }
        return date.formatted(date: .complete, time: .omitted)
    }
}
