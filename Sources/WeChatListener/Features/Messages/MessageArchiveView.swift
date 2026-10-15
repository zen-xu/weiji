import AppKit
import SwiftUI

struct MessageArchiveView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let displayedMessages = model.messages
        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索消息、发送者、群名…", text: $model.search).textFieldStyle(.plain)
                    if !model.search.isEmpty {
                        Button {
                            model.search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }.buttonStyle(.plain)
                    }
                }.padding(10).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                Picker("时间", selection: $model.dateScope) {
                    ForEach(DateScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.labelsHidden().frame(width: 120)
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
                Text(
                    model.selected?.identitySource == "display_title_fallback"
                        ? "此会话按通知标题分组，同名联系人可能混在一起。" : "只包含系统通知；免打扰、前台消息和自己发送的内容可能缺失。")
                Spacer()
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 26).padding(.bottom, 14)
            Divider()
            if model.messages.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: model.search.isEmpty ? "bubble.left.and.text.bubble.right" : "magnifyingglass")
                        .font(.system(size: 42, weight: .light)).foregroundStyle(AppTheme.accentColor.opacity(0.7))
                    Text(model.stats?.messages == 0 ? "从下一条通知开始，留下记录" : "当前筛选没有匹配的通知").font(.title3.weight(.medium))
                    Text(
                        model.stats?.messages == 0 ? "开始采集后，收到的微信通知会保存在这里。\n也可以导入之前的验证数据。" : "可以调整关键词或日期。没有结果不代表事情没有发生。"
                    )
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if model.stats?.messages == 0 {
                        HStack {
                            Button("导入旧数据", action: model.importArchive)
                            Button("查看采集状态") { model.page = .overview }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(displayedMessages.enumerated()), id: \.element.id) { index, message in
                            if index == 0
                                || !Calendar.current.isDate(
                                    message.date, inSameDayAs: displayedMessages[index - 1].date)
                            {
                                Text(message.date.formatted(date: .complete, time: .omitted)).font(
                                    .caption.weight(.medium)
                                ).foregroundStyle(.secondary).padding(.vertical, 4)
                            }
                            MessageCard(message: message, model: model)
                        }
                    }.padding(24)
                }
            }
            AppBottomBar {
                Text(
                    model.total == 0
                        ? "0 条通知" : "第 \(model.offset + 1)–\(model.offset + model.messages.count) 条，共 \(model.total) 条"
                ).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.paginate(-1)
                } label: {
                    Image(systemName: "chevron.left")
                }.disabled(model.offset == 0 || model.loading)
                Button {
                    model.paginate(1)
                } label: {
                    Image(systemName: "chevron.right")
                }.disabled(model.offset + model.messages.count >= model.total || model.loading)
                Button {
                    model.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.help("刷新本地档案")
            }
        }
    }
}
