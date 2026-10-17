# 微迹

微迹是一款原生 macOS 通知档案应用，同时提供供 Codex 接入的 **本地 HTTP MCP 服务**。Swift + SwiftUI + 系统 SQLite，没有第三方运行时依赖，不向远端发送网络请求，也不需要关闭 SIP、调试微信或获取微信数据库密钥。

这是通知档案和本地目录图片索引，不是完整聊天数据库。通知内容可能隐藏、合并或截断；免打扰、前台会话、应用退出/休眠期间和自己发送的消息可能没有通知。没有搜索结果不等于没有发生。

原名“微信消息监听”。改名沿用既有签名证书、Bundle ID、数据目录及 MCP 配置；历史通知和设置无需迁移。新构建产物为 `dist/微迹.app`。旧版安装路径的升级说明见 [签名与升级](Documentation/Signing.md)。

## 下载与版本

正式版本从 **0.1.0** 开始，macOS 14+，提供 Apple Silicon / Intel 通用包。下载见 [GitHub Releases](https://github.com/zen-xu/weiji/releases)；当前仓库私有，需要仓库访问权限。

推送 main / PR 自动检查并构建开发附件；推送 `v<版本>` 标签通过完整检查后，自动使用固定 CI 证书签名并发布 DMG、ZIP 和校验文件。CI 证书与本机开发证书不同，切换时需要重新添加一次磁盘访问权限；当前未经过 Apple Developer ID 公证。操作及安装说明见 [自动发布](Documentation/Releasing.md)。

## 打开与采集

1. 打开 `dist/微迹.app`。
2. 应用先检查能否读取系统通知；未获得访问权限时显示启动引导，点击“打开权限设置”，将这份应用加入“隐私与安全性 → 完全磁盘访问”。可以点击“在 Finder 中显示本应用”定位文件。返回应用会自动复查；授权后仍受阻时，退出并重新打开应用。
3. 首次通过检查后，选择是否自动采集、是否连接微信文件目录，再点击“开始使用”进入主界面。后续启动仍先检查访问权限，通过后直接进入。连续采集默认暂停；进入主界面后会补扫一次系统保留的历史通知。
4. 让微信在后台收到一条有正文的系统通知，检查档案是否新增记录。

从旧版临时签名切换到固定证书签名时，需要重新添加一次完全磁盘访问授权。之后的构建复用同一证书及 Bundle ID，避免身份随二进制变化。配置方法和验证边界见 [Documentation/Signing.md](Documentation/Signing.md)。

访问检查由应用自身进程完成，不以终端是否能读作为依据。通知存储不存在、暂时繁忙或格式不兼容时，会分别提示并提供重试。启动引导完成前不采集通知、不启动文件扫描；HTTP MCP 仍随应用启动，可查询已有档案。

关闭窗口后应用会留在菜单栏运行。“暂停通知采集”只停止读取通知；目录监听继续工作，菜单栏“退出”会停止整个应用。应用不会自动安装登录启动项；设置中的“打开应用后自动开始采集通知”只影响应用启动后的行为。

“所有通知”支持关键词和日期筛选、100 条一页的浏览、按会话查看、复制正文和结构化 JSON。“…”菜单支持导入旧 JSONL、导出当前筛选和数据库备份。设置里可以清空本地档案；不修改微信或系统通知，也不删除导出/备份文件。

## 重要消息提醒

从“微迹 → 提醒规则…”或“设置 → 重要消息提醒”管理规则。可按发送者、会话/频道名称、消息内容和会话类型组合条件，支持包含、相等、ICU 正则及排除项，并选择全部满足（且）或任一满足（或）。

命中后在屏幕右下角显示小浮窗，默认无声、不抢输入、不跳 Dock；多条合并计数，点击“展开”查看详情。可收起后从菜单栏“查看提醒”找回，也可选择 5 分钟、15 分钟或 1 小时后再提醒。“处理当前提醒”移入已处理列表；不会删除消息。侧边栏“提醒收件箱”保留未处理、稍后及已处理状态，重启后恢复。完整屏幕应用和系统锁屏之上的显示不作保证。

消息右键或“…”菜单可从会话、发送者及 @所有人快速预填规则。每条规则支持跨午夜安静时段和同一会话合并间隔，默认保持即时提醒。

支持让 AI 通过 MCP 查看、示例测试、保存及删除规则，App 约 2 秒内同步；已有六个通知/文件工具保持只读。规则写入带版本检查，不会修改磁盘权限或开启采集。示例、MCP 参数及数据边界见 [提醒规则](Documentation/Reminders.md)。

## 群聊展示

消息档案保留通知原始文字。图片通知下方可展示本地图片文件的时间关联；支持本地 DAT 解码、缩略图和 App 内大图预览；不提供手动附件关联。

消息按日期分隔、最新在前，群名、发送者和正文分别展示。选择某个群后不再逐条重复群名；“所有通知”中的群名可点击进入该会话。

通知提供的发送者字段优先；只有“昵称: 正文”或“昵称：正文”格式才尝试拆分，并标注“正文推测”。网址、时间、跨行前缀和合并通知不作为发送者。缺少可靠会话标识时仍保留 `unknown`，展示为“疑似群聊”，不会改变已有分组或把同名群合并。可从通知操作菜单或右键菜单打开“查看原始通知”，核对标题、副标题、正文和消息 ID。

## 普通文件目录探测

“微信文件”页面可选择微信账号目录或其中的 `msg/file` 文件夹。自动监听文件变化，正常监听时每分钟补扫，监听不可用时每 15 秒补扫，建立文件名、大小、修改时间和本机路径索引；也可点“立即扫描”。不读取文档内容，不扫描 `db_storage` 或缓存目录，不移动或上传原文件。图片预览会单独写入本应用的本地缓存，详见下节。

文件列表支持按文件名搜索、分页、通过系统应用打开及 Finder 定位。图片、加密 DAT、无扩展名内部文件、隐藏文件和符号链接不纳入列表。扫描不完整时不会把未访问到的旧文件误标为丢失；目录访问失败会显示错误。

对于 `[文件] 文件名` 格式的通知，应用用完整文件名查找目录候选，列出同名项并标注“未验证消息归属”。时间只用于候选排序，不能证明文件来自该消息或该会话。同名通知、转发、重复下载和多账号都可能产生歧义，不会据此更改消息归档身份。

目录只有文件，没有完整的聊天关系。MCP 的消息与上下文结果附带 `file_candidates`，明确标记 `message_link_verified=false`；新增 `wechat_search_files` 可查询已扫描文件的元数据和本机路径，不触发扫描，也不读取内容。扫描时间和状态可从 `wechat_status.file_discovery` 查看。文件修改或移动后须以新扫描结果为准；目录索引不是文件副本或完整备份。

旧版手动关联功能已移除。升级不删除过去的附件表或已保存副本，但不会再读取或向 MCP 返回这些旧关联。

## 自动目录探测与图片预览

选定账户目录后，App 独立监听 `msg/file` 与 `msg/attach` 的文件变化，通常合并 0.8 秒内的连续事件后自动扫描，持续变更最多等待约 2 秒发起；正常监听时每分钟补扫，监听不可用时每 15 秒补扫。图片以小批次后台解码，让通知采集在批次之间继续运行。无需接入 Codex、无需先收到“[图片]”通知；暂停通知采集或通知访问受阻时，目录监听仍然运行。退出 App 才会停止目录监听。

“目录图片”页面直接列出选定账户的本地图片，同组版本合并并优先显示较清晰的版本；没有任何通知记录的图片也能查看。这里只确认本机存在文件，不确认发送者、收发方向或完整的聊天归属，不创建聊天消息。自动优先解码最近 200 个图片文件，大量历史图片在浏览对应页面时分批按需解码；源文件未下载到本机、目录访问受阻或解码失败时会显示对应状态。

## 图片时间关联与启动补扫

对于 `[图片]` 通知，应用使用通知提供的会话标识定位 `msg/attach/<会话目录>/…/Img`，先定位文件修改时间落在通知送达时间前后 30 秒内的图片，再补充同一会话、同一 Img 子目录、同一文件组的其他版本。较大版本即使晚几分钟下载，也不会因超过时间窗口而被漏掉。每次启动补扫系统仍保留的通知，同时启动独立的目录监听和扫描；连续采集暂停时也会补扫一次。菜单中的“补扫系统保留的历史通知”可再次执行。不会恢复已被系统清除且此前未归档的聊天文字。

如果系统没有保留独立的“[图片]”通知，但同一会话附近有其他已归档通知，应用也会扫描该会话目录：图片最早文件时间在通知前后 30 秒内时，作为目录线索显示在最近的一条通知下，标注“未捕获独立图片通知”。这不会新建图片消息，也不确认图片发送者或收发方向；已有图片通知时优先关联到图片通知。没有会话标识、没有送达时间或附近没有通知的图片，不会冒充已捕获聊天消息。

界面和 MCP 的 `image_associations` 返回候选文件、大小、修改时间、与通知的时间差、目录及时间匹配依据、相邻图片通知 ID。`association_basis`、`within_time_window`、`anchor_file_ids` 区分时间候选与同组版本；`image_notification_captured`、`notification_anchor_kind`、`sender_verified` 标明目录线索的边界，`preferred_for_preview` 标记分辨率较高的可用预览。可信度交由 AI 客户端评估，不生成可信度分数，也不将时间接近当作已确认归属。状态由 `wechat_status.image_associations` 返回。

图片扫描所选账户 `msg/attach` 下合法的会话目录，仅索引 `Img` 中的图片文件，跳过符号链接，限制扫描量。随后分批读取目录图片并生成预览，支持普通图片、旧 XOR DAT 和 V2 AES/raw/XOR DAT。V2 图片密钥从所选微信账号对应的本地 `kvcomm` 缓存文件名派生，并用实际图片验证；只驻留内存，不落盘、不记录到日志、不通过 MCP 返回。不关闭 SIP、不调试微信，也不读取聊天数据库。

成功解码后，同组文件在消息中合并成一个卡片，优先按已解码像素数选择清晰版本；其他版本可展开查看。只有缩略图时会明确标注。列表使用最大边长 1024 的无损 PNG，点击图片或“查看大图”即可在 App 内查看较大版本。大图支持适应窗口、100% 和缩放；默认不将小图拉伸超过实际像素。WXGF 使用系统 VideoToolbox 解码，不依赖 wx-cli、Python 或 FFmpeg；多流文件优先选择彩色流，避免把灰度遮罩当作图片。当前显示静态预览，动画不保证播放或保留透明遮罩；预览最大边长 4096，不能将其视为原始文件的完整无损备份。未匹配到密钥、数据不完整或系统解码失败时显示明确状态。

预览与缩略图保存在 `ImagePreviews/`，目录权限 0700、文件权限 0600；缓存是明文，清空档案会一并删除。不会修改源 DAT。每个源文件上限 32 MB、解码像素上限 4000 万，每轮最多新增 100 个预览；解码失败会在后续扫描重试。旧档案缺少会话目录标识时，可从系统仍保留的同一条通知补充元数据，保留原正文和归档时间；无法补充的旧通知不会跨会话猜测图片。缩略图和原图文件可能同时出现，文件修改时间也不一定代表消息发送时间。

## Codex MCP 接入

应用启动后自动提供 Streamable HTTP MCP 服务，默认地址：

```text
http://127.0.0.1:18765/mcp
```

在 Codex 的 MCP 设置中选择 **Streamable HTTP**，填入该地址并保存。应用的“连接 Codex”页面可复制地址、查看状态、停止/启动服务或修改端口。应用关闭窗口后仍在菜单栏提供服务；退出应用后服务停止。暂停通知采集不影响 MCP 查询。

也可手动配置：

```toml
[mcp_servers.wechat-listener]
url = "http://127.0.0.1:18765/mcp"
```

或使用 CLI：

```bash
codex mcp add wechat-listener --url http://127.0.0.1:18765/mcp
```

已有同名 stdio 配置时，在 Codex 设置中将其替换为 HTTP 地址；更改端口后同步更新客户端配置。按[官方 MCP 文档](https://learn.chatgpt.com/docs/extend/mcp)重新加载服务配置。应用移动或升级不改变 URL。

服务只绑定 IPv4 回环地址 `127.0.0.1`，不开放局域网访问；校验 Host，拒绝带 Origin 的浏览器请求。默认无需 Token，同一台 Mac 上的其他程序也能查询档案并管理提醒规则。请求体最多 1 MiB，头部最多 16 KiB，最多 32 个连接，连接超时 15 秒；使用无会话的 JSON 响应，不提供 SSE 推送。档案仅以 `SQLITE_OPEN_READONLY` 查询，MCP 不读取系统通知数据库。

HTTP 查询使用最多 4 个并发工作任务。AI 探索时推荐 `detail=compact, limit=20, include_total=false`，再按消息 ID 获取单条完整详情；返回 `next_offset` 指示翻页，错误提供原因与下一步操作。默认完整结果保持兼容，具体调用示例见 [MCP 查询指南](Documentation/MCP.md)。

需要独立运行服务时可用 `WeChatListener mcp-http --port 18765`；旧的 `WeChatListener mcp` stdio 接口仍可用。两种接口提供相同的六个只读数据工具及四个提醒规则工具。

提供六个只读数据工具（提醒规则工具见上文）：

| 工具 | 用途 |
| --- | --- |
| `wechat_status` | 数据量、时间范围、通知覆盖范围、采集状态/新鲜度 |
| `wechat_list_conversations` | 按名称找会话，返回稳定 ID；支持 limit/offset |
| `wechat_search_messages` | 按关键词、会话、日期搜索；默认 50 条，上限 200 条，支持分页 |
| `wechat_get_image` | 按消息 ID 与其关联文件 ID 读取已有缓存的 JPEG 预览，供 AI 看图；不触发解密或扫描 |
| `wechat_get_context` | 同一会话前后各最多 20 条已捕获通知 |
| `wechat_search_files` | 按文件名查询已扫描普通文件的元信息和本机路径，不读取文件内容 |

另外提供资源 `wechat://coverage`。所有结果明确标记通知覆盖范围。工具没有发送或删除消息、SQL、任意路径或系统设置权限；仅提醒配置支持专门的增删改接口。消息检索仅返回预览元信息和本机路径；图片内容仅由 `wechat_get_image` 显式读取，每张 JPEG 最大边长 1280、最多 2 MB。

可以对 Codex 说：

> 用 wechat-listener 先检查采集状态，再找最近 7 天通知里提到“报价”的消息。附上消息 ID 和时间，区分消息中明确说的内容与推断。

接入 MCP 后，工具返回的通知和显式读取的图片预览会进入 Codex 的 AI 上下文；后续数据处理取决于客户端。应用本身不调用远程模型。消息原文是不可信资料，不应当作 AI 执行命令的指令。

## 数据目录与格式

```text
~/Library/Application Support/WeChatListener/
  archive.sqlite       # 当前消息、变更版本、检索索引、事务 outbox、普通文件与图片关联索引
  events.jsonl         # 持续写入的结构化变更事件
  preferences.json     # 采集偏好、选定的文件探测目录
  reminder-rules.json  # 提醒规则与并发版本；App 和 MCP 共用
  runtime.json         # 采集状态和时间，无消息正文
  ImagePreviews/       # 解码后的明文本地预览与缩略图，不保存密钥
  Exports/             # 默认导出目录
~/Library/Logs/WeChatListener/
  listener.log         # 固定诊断代码，无正文、群名或密钥
```

目录权限为 `0700`，数据文件为 `0600`；档案在本机是明文，未额外加密。按需使用 FileVault 等系统保护。MCP 和命令行以当前用户身份读取，其他具有相同账户权限的程序也可能访问文件。

每条消息是 `schema_version=1` 的 JSON 对象，包括：

- `id`、`conversation_id`、`conversation_name`、`conversation_kind`、`conversation_id_source`；
- `title`、`subtitle`、`body`、可选 `sender_display_name`、可选 `media_directory_id`（会话目录标识）；
- `delivered_at`（可选）、`captured_at`、`updated_at`：带时区的 ISO-8601；
- `source=macos_notification`、`coverage=notification_only`、来源记录 ID；
- `is_complete_chat=false`、`includes_sent_messages=false`、`body_may_be_truncated=true`。

`conversation_id_source=notification_chatname` 表示有通知提供的会话标识；旧数据没有标识时使用 `display_title_fallback`，可能混合同名联系人，界面会提示。通知没有可靠提供当前微信账号标识，因此 `account_identity=not_available_from_notification`；不能承诺多账号完全隔离。原始消息字段不修改，发送者的展示拆分只放在 `presentation`，正文推测通过 `sender_source=body_prefix_inferred` 明确区分。

JSONL 的每一行都是独立 JSON，不会把正文换行拆成多条记录。事件另带 `event_id`、`event_kind`；SQLite outbox 保证已提交消息可以补写日志。崩溃若发生在追加日志和标记已写之间，事件可能重放，消费者应按 `event_id` 去重；消息快照按 `id` 更新。SQLite 是权威数据源。

备份通过 SQLite 在线备份 API，包含已提交的 WAL 数据；图片缓存不包含在 SQLite 备份中，可从仍存在的源图片重新生成。导出采用一致性快照。清空档案后，若系统仍保留这些通知，再次开始采集可能重新入库。

## 命令行

应用的可执行文件也可直接使用，不需要另装 Python 或 Node：

```bash
APP='/你的路径/微迹.app/Contents/MacOS/WeChatListener'
"$APP" status
"$APP" conversations --query '项目'
"$APP" search --query '报价' --from 2026-10-01 --to 2026-10-15 --limit 50
"$APP" context --message '搜索返回的消息ID' --radius 5
"$APP" import --input '/旧项目/outputs/通知验证数据'
"$APP" source-status
"$APP" scan-files --directory '/微信账号目录'
"$APP" files --query '报价'
```

`from` 日期包含当天，`to` 日期包含当天，按本机时区解释。精确 ISO-8601 时间须带时区；其 `to` 为不包含的上界。搜索按字面匹配，不把输入解释成 SQL 或正则。

`capture-once` 会读取一次系统当前保留的微信通知，需要调用进程有相应读取权限。MCP 不暴露此命令。

## 开发、构建与验证

项目采用 Swift Package Manager，要求 macOS 14+ 和 Swift 6 工具链。直接打开 `Package.swift` 即可用 Xcode 浏览目标和源码。

```bash
swift build
swift run WeChatListener --help
bash Scripts/check.sh
```

源码按应用入口、命令行、持久化和功能目录组织；Swift Testing、性能基准和 MCP 进程测试是独立目标，不会编入生产 App。目录结构、测试、格式及工具链说明见 [开发指南](Documentation/Development.md)。

`Resources/` 保留当前图标 `AppIcon.icns`、源图 `AppIcon.png`、设计提示词 `AppIcon-prompt.txt` 和应用配置 `Info.plist`。版本号统一从打包后的 Bundle 元数据读取。旧图标草稿可从 Git 历史找回。

打包为可安装应用：

```bash
# 仅首次本机配置：创建持久签名私钥，并添加用户级代码签名信任
python3 Scripts/setup_signing.py --confirm-local-trust
bash build.sh
python3 -B Tests/Integration/test_mcp_stdio.py 'dist/微迹.app/Contents/MacOS/WeChatListener'
python3 -B Tests/Integration/test_signing_identity.py
```

`build.sh` 使用 SwiftPM 的 release 产品生成 `.app`，复用固定签名身份并严格校验；`check.sh` 独立检查格式、Swift Testing、签名配置以及真实 stdio / HTTP MCP 进程。Swift 测试保留原有 164 项合成断言并新增 HTTP 检查，不读取真实通知；网络测试仅连接本机回环地址。图片文件保护的读取验证需要 Mac 处于解锁状态。应用运行没有 Python 或第三方运行时依赖。

默认从忽略的 `.local-signing/identity.json` 读取已固定的证书指纹，配置缺失或证书不可用时打包会停止。也可通过 `CODE_SIGN_IDENTITY` 和可选的 `CODE_SIGN_KEYCHAIN` 选择已有身份。本机自签名身份不等于 Developer ID 或 Apple 公证。配置和验证边界见 [签名说明](Documentation/Signing.md)。

性能基准默认跳过，手动运行：

```bash
WECHAT_RUN_BENCHMARKS=1 bash Scripts/test.sh -c release --filter catalogPerformance
```

基准在临时目录生成 10,000 个合成图片文件和 1,000 个文档，测量首次索引、无变化重扫和图片分页查询，完成后删除测试资料；测量边界见 [性能记录](Documentation/Performance.md)。

重扫仍检查文件元数据；大小和修改时间未变时复用格式信息，不改写目录索引。图片列表合并读取同页版本和预览，显示时在后台加载并解压，使用 32 MB 预算的内存缓存。文件和图片搜索在连续输入停顿 250 ms 后查询。

演示界面需要独立合成目录：

```bash
open 'dist/微迹.app' --args --demo --data-dir /tmp/wechat-listener-demo
```

## 已知限制

通知数据库格式属于 macOS 内部实现，系统升级后可能需要适配。采集通过短间隔只读快照完成，不能保证捕获两次快照间已被移除的通知。应用会先保存当前系统仍保留的微信通知，它们可能早于首次运行时间，但不代表能够恢复完整历史。

当前没有自动更新、云同步、远程模型、消息发送或登录自启动服务。旧版验证工具和源数据保持独立，导入可重复执行；不需要卸载或运行 TraceMemo。

界面采用 macOS 原生侧边栏、窗口工具栏、文件表格和分组表单，详细约定及验证边界见 [界面说明](Documentation/Interface.md)。
