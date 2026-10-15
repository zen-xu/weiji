# 开发指南

需要 macOS 14+、Swift 6 工具链及其系统 SDK。可以使用 Xcode，也可以使用 Apple Command Line Tools。没有远程 Swift Package 依赖。

## 项目结构

```text
Package.swift                     SwiftPM 产品、平台和目标声明
Sources/
  CSQLite/                        系统 SQLite 的 C 模块声明
  WeChatListener/
    App/                          应用入口、生命周期、状态和本机设置
    CLI/                          命令行参数与 JSON 输出
    Features/
      Notifications/              通知解码、采集与状态页面
      Messages/                   消息展示与档案页面
      Files/                      普通文件发现、索引与页面
      Images/                     图片发现、关联、解码、缓存与页面
      MCP/                        只读查询服务、stdio / HTTP 传输与接入页面
    Models/                       档案值类型
    Persistence/                  SQLite 封装和档案持久化
    Services/                     后台档案队列和目录监听
    Support/                      日期、哈希、JSON 和错误
    UI/                           主窗口、导航、设置和共享组件
Tests/
  WeChatListenerTests/             Swift Testing 集成测试及合成资料
  WeChatListenerBenchmarks/        手动启用的合成性能基准
  Integration/                    MCP 进程及签名工具的 Python 检查
Resources/                        App Bundle 元数据和当前图标
Scripts/                          打包辅助、签名、测试和格式命令
Documentation/                    开发、性能、签名与验证记录
```

应用是一个 SwiftPM 可执行目标；测试通过 `@testable import WeChatListener` 访问内部实现。入口使用 `@main`，测试由独立目标发现并执行，生产 App 不包含测试代码或测试框架。

当前保持原有 Swift 5 语言模式（`swiftLanguageModes: [.v5]`），以保留现有队列和回调的并发语义。切换 Swift 6 严格并发需要单独验证 Sendable 和 actor 隔离。

## 日常开发

```bash
swift build
swift run WeChatListener --help
# 开发界面使用独立演示档案
swift run WeChatListener --demo --data-dir /tmp/wechat-listener-dev
bash Scripts/check.sh
```

`check.sh` 检查 Swift 格式，运行 Swift Testing、签名配置检查和真实 stdio / HTTP MCP 进程检查。测试仅使用自动清理的临时目录与合成通知/文件，不需要本机签名证书或完全磁盘访问权限；HTTP 检查仅访问本机回环端口。图片缓存保留原有文件保护设置，相关读取测试要求 Mac 处于解锁状态。

SwiftPM 的裸可执行文件没有 App Bundle 元数据，开发时版本显示为 `development`。打包后，界面、帮助和 MCP 版本统一读取 Bundle 的 `CFBundleShortVersionString`，版本号只在 `Resources/Info.plist` 维护。

## 测试与基准

```bash
bash Scripts/test.sh
bash Scripts/test.sh --filter imagePreview
WECHAT_RUN_BENCHMARKS=1 bash Scripts/test.sh -c release --filter catalogPerformance
```

在完整 Xcode 工具链下也可以直接使用 `swift test --disable-xctest`。当前 Command Line Tools 虽包含 Swift Testing，却缺少自动框架搜索路径和可选 Foundation overlay 的 Swift 模块；`test.sh` 为该工具链添加测试专用的框架路径与 overlay 兼容参数，不下载第三方框架、不修改工具链文件。正式 `swift build` 和 App 打包不使用这些测试兼容参数。

性能基准默认跳过，避免日常测试生成一万张合成文件。设置环境变量后才执行，测量边界见 [Performance.md](Performance.md)。

HTTP 实现使用系统 `Network.framework`，无第三方 HTTP 运行时依赖。`MCPHTTPRequest` / `MCPHTTPHandler` 负责有界 HTTP 报文及协议检查，`MCPHTTPServer` 在独立串行队列管理监听器和连接；应用启动时自动开启，退出时停止，端口保存在现有 Preferences 中。`mcp-http --port N --data-dir 目录` 可独立验证服务。修改传输时执行：

```bash
python3 -B Tests/Integration/test_mcp_http.py .build/debug/WeChatListener
python3 -B Tests/Integration/test_mcp_stdio.py .build/debug/WeChatListener --http
# 可选：启动合成演示界面，确认 GUI 启动即提供服务
python3 -B Tests/Integration/test_mcp_http.py .build/debug/WeChatListener --gui
```

原来的 App `--self-test` 入口已迁移到独立测试目标；该参数现在给出迁移提示，不会运行测试或创建档案。

## 格式与代码组织

```bash
bash Scripts/format.sh
bash Scripts/format.sh --check
```

使用工具链自带的 `swift-format` 和根目录 `.swift-format`：4 空格缩进、120 字符行宽、排序的 import、多行闭包及参数列表。`.editorconfig` 为编辑器提供相同的基本文本约定。格式检查可以直接放入 CI。

新类型放入对应职责目录。档案扩展使用 `Archive+Feature.swift`，视图扩展使用 `ListenerView+Feature.swift`；消息档案、采集概览、MCP 接入和设置使用各自的 SwiftUI View，共享状态栏提取为 `AppBottomBar`、`DirectoryStatusBar` 等组件，页面优先使用原生 List / Table / Form；主视图负责导航与组合。业务模型、持久化和视图分别存放。新增行为通过 Swift Testing 的 `@Test`、`#require` 或 `#expect` 验证。

## 打包与签名

```bash
bash build.sh
python3 -B Tests/Integration/test_mcp_stdio.py 'dist/微信消息监听.app/Contents/MacOS/WeChatListener'
python3 -B Tests/Integration/test_signing_identity.py
```

`build.sh` 用 SwiftPM 构建 release 产品，将可执行文件和图标复制为 `.app`，然后复用现有的固定证书签名并严格校验。测试通过 `check.sh` 单独执行。Bundle ID、安装路径、数据目录和 MCP 工具保持兼容。

首次本机签名配置及授权迁移见 [Signing.md](Signing.md)。`.build/`、`dist/` 和本机签名配置不纳入版本管理。

界面布局和交互约定见 [Interface.md](Interface.md)。真实窗口验证受锁屏状态影响时，须明确区分离屏内容截图和实际交互结果。
