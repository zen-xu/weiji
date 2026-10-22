import Testing

@testable import WeChatListener

@Test("Agent summaries retain paragraphs and align headings, bullets and numbered items")
func notificationSummaryFormatting() {
    let text = "## 发布安排\n\n今晚 **20:00** 发布。\n请提前确认。\n\n- 配置核对\n* 联系值班\n1. 确认负责人\n2、 更新进度\n\n普通段落"
    let blocks = NotificationTextBlock.parse(text)
    #expect(
        blocks == [
            NotificationTextBlock(kind: .heading, text: "发布安排"),
            NotificationTextBlock(kind: .paragraph, text: "今晚 **20:00** 发布。\n请提前确认。"),
            NotificationTextBlock(kind: .bullet("•"), text: "配置核对"),
            NotificationTextBlock(kind: .bullet("•"), text: "联系值班"),
            NotificationTextBlock(kind: .bullet("1."), text: "确认负责人"),
            NotificationTextBlock(kind: .bullet("2、"), text: "更新进度"),
            NotificationTextBlock(kind: .paragraph, text: "普通段落"),
        ])
    #expect(NotificationTextBlock.parse("  \n\n").isEmpty)
    #expect(NotificationTextBlock.parse("第一行\r\n第二行") == [NotificationTextBlock(kind: .paragraph, text: "第一行\n第二行")])
    #expect(
        NotificationTextBlock.parse("#话题\nhttps://example.com\n-1 不是列表").first?.text
            == "#话题\nhttps://example.com\n-1 不是列表")
}

@Test("Long notification previews bound dense text and multiline summaries")
func longNotificationPreviewThreshold() {
    #expect(!LongNotificationBody.needsReader("简短通知"))
    #expect(!LongNotificationBody.needsReader(String(repeating: "字", count: 320)))
    #expect(LongNotificationBody.needsReader(String(repeating: "字", count: 321)))
    #expect(LongNotificationBody.needsReader(Array(repeating: "待办", count: 8).joined(separator: "\n")))
    #expect(!LongNotificationBody.needsReader(String(repeating: "👨‍👩‍👧‍👦", count: 100)))
}
