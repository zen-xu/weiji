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
      Onboarding/                 通知访问探测、启动状态与首次设置
      Notifications/              通知解码、采集与状态页面
      Messages/                   消息展示与档案页面
      Files/                      普通文件发现、索引与页面
      Images/                     图片发现、关联、解码、缓存与页面
      MCP/                        查询与提醒配置工具、stdio / HTTP 传输与接入页面
      Reminders/                  规则、匹配、提醒收件箱、安静时段与合并调度
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

`LibraryWorker` 将档案访问限制在所属串行队列：写队列处理采集、索引和档案操作，消息/文件与图库使用独立只读工作器。可替代的 UI 查询使用 `performLatest`，输入变化立即 `invalidate`，过期工作不执行、不交付；不要将写任务交给此接口。`BackgroundWorkToken` 跨主线程与工作队列传递取消状态，`PreviewPreparation` 分小批准备图片，避免单次解码循环长期独占采集队列。初始化新档案完成后再调度正常只读查询。

`NotificationCaptureCache` 仅保存有限的行摘要，由 Archive 的写队列拥有；本地变更版本与 SQLite data_version 共同保证失效，不能只按通知行号跳过。采集仍逐轮读取源快照，失败或较新归档冲突的记录不进入复用缓存。日志 outbox 的 `events_pending` 索引与只更新未同步行的条件必须一起保留。

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
python3 -B Tests/Integration/test_mcp_queries.py .build/debug/WeChatListener
python3 -B Tests/Integration/test_mcp_http.py .build/debug/WeChatListener
python3 -B Tests/Integration/test_mcp_stdio.py .build/debug/WeChatListener --http
# 可选：启动合成演示界面，确认 GUI 启动即提供服务
python3 -B Tests/Integration/test_mcp_http.py .build/debug/WeChatListener --gui
```

查询由最多 4 个并发工作任务执行，与网络状态队列分离。SQL 分页、读取快照、精简结果和 AI 查询约定见 [MCP.md](MCP.md)。查询基准可单独执行 `WECHAT_RUN_BENCHMARKS=1 bash Scripts/test.sh -c release --filter mcpQueryPerformance`，使用 12,000 条合成通知，不读取真实档案。

原来的 App `--self-test` 入口已迁移到独立测试目标；该参数现在给出迁移提示，不会运行测试或创建档案。

## 启动与权限检查

`ApplicationRootView` 根据 `StartupCoordinator` 切换检查页、访问引导、首次配置和主界面。每次正常启动都先用 GUI 进程执行只读通知源探测；`NotificationAccessChecker` 检查文件头及采集依赖的 SQLite 列，不解码或导入通知，不查询 TCC 数据库。结果表示当前进程的有效读取能力，不能作为全局完全磁盘访问开关状态。权限由用户在系统设置中授予，见 [Apple 文件访问控制说明](https://support.apple.com/en-ca/guide/security/secddd1d86a6/web)。

`Preferences.onboardingCompleted` 为可选字段，兼容旧设置。只有检查通过并成功保存首次配置后，才调用一次 `AppModel.startUp()`；返回用户仍须重新检查，首次配置完成标记不能跳过权限检查。应用重新激活时复查未完成的引导，点击“开始使用”前再次检查；退出取消未完成的任务。HTTP MCP 独立启动，仅查询既有档案。`--demo` 使用独立合成资料，跳过真实通知检查和首次配置。

`StartupTests` 覆盖真实合成 SQLite 的只读/缺失/权限/繁忙/格式结果，以及启动门控、撤权、重复请求、保存失败、取消和旧设置迁移。运行 `bash Scripts/test.sh --filter startup --filter notificationAccessProbe`。真实系统授权后的返回与重启流程，需要解锁 Mac 后人工检查。

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
python3 -B Tests/Integration/test_mcp_stdio.py 'dist/微迹.app/Contents/MacOS/WeChatListener'
python3 -B Tests/Integration/test_signing_identity.py
```

`build.sh` 用 SwiftPM 显式指定 `--arch arm64` 构建 release 产品，将可执行文件和图标复制为 `.app`，然后复用现有的固定证书签名并严格校验。测试通过 `check.sh` 单独执行。Bundle ID、安装路径、数据目录和 MCP 工具保持兼容。

从 v0.4.1 起打包与发布仅支持 Apple Silicon（arm64），签名前及正式打包时均检查架构，不再编译或合并 Intel 切片。正式版本从 0.1.0 开始，GitHub 自动检查、发布保护条件及 CI 专用固定签名见 [Releasing.md](Releasing.md)。

首次本机签名配置及授权迁移见 [Signing.md](Signing.md)。`.build/`、`dist/` 和本机签名配置不纳入版本管理。

界面布局和交互约定见 [Interface.md](Interface.md)。真实窗口验证受锁屏状态影响时，须明确区分离屏内容截图和实际交互结果。

提醒收件箱由 `AppModel` 持有，生产提示卡片与侧边栏共享同一个实例；规则预览使用独立内存实例。收件箱在主 actor 一次发布批量变更，串行 utility 队列合并过时写任务并原子保存，退出前 flush。`ReminderWindowController` 只维护一个到期计时器；休眠恢复和时区变化会重新核对。匹配与展示策略分离：MCP 示例测试只测条件，不推进实际提醒或冷却状态。规则新字段使用兼容解码；旧 MCP 更新省略节奏参数时保留既有值。

规则同步的 `ReminderRuleSyncState` 使用多值因果寄存器而非时间戳覆盖，保存删除标记并紧凑保留当前版本。`ReminderRuleStore` 将本机规则和因果状态置于同一锁及原子写入中，MCP 输出不暴露内部同步元数据。`ReminderRuleSyncWorker` 在后台使用协调访问处理选定目录及文件冲突，`ReminderRuleSync` 负责书签、监听、请求合并、重试和取消。参见 [iCloud Drive 同步](RuleSync.md)。
