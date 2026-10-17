import SwiftUI

struct ReminderRuleSyncView: View {
    @ObservedObject var sync: ReminderRuleSync
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: "icloud").foregroundStyle(.secondary)
                Toggle(
                    "iCloud Drive 同步",
                    isOn: Binding(get: { sync.enabled }, set: { if $0 { sync.chooseFolder() } else { sync.disable() } })
                )
                .toggleStyle(.switch).controlSize(.small)
                Spacer()
                if sync.busy { ProgressView().controlSize(.small) }
                if sync.enabled {
                    Button("立即同步") { sync.request() }.disabled(sync.busy)
                    Menu {
                        Button("更改同步文件夹…") { sync.chooseFolder() }
                        Button("关闭同步") { sync.disable() }
                    } label: {
                        Image(systemName: "ellipsis")
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }
            Text(sync.status).font(.caption).foregroundStyle(.secondary)
            if !sync.enabled {
                Text("每台 Mac 选择同一个 iCloud Drive 文件夹，仅同步提醒规则。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let issue = sync.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }.padding(.horizontal, 20).padding(.vertical, 14)
    }
}
