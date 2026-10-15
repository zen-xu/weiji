# 固定本机签名

旧构建使用 `codesign --sign -`。这种 ad-hoc 签名的 designated requirement（DR）绑定二进制哈希，更新代码后身份就变化，旧的隐私授权可能无法匹配。固定证书签名让不同版本使用同一证书约束和 Bundle ID。

Apple 的 [TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements) 说明了系统如何用 DR 识别隐私授权对应的程序及其更新；[TN2206](https://developer.apple.com/library/archive/technotes/tn2206/_index.html) 说明本机自签名身份的适用边界。

## 首次配置

```bash
python3 Scripts/setup_signing.py --confirm-local-trust
```

这一步会：

- 创建名为 `WeChatListener Local Code Signing` 的本机专用证书及 RSA 私钥，证书限于代码签名用途。
- 将私钥作为不可导出项导入当前用户默认钥匙串，仅为 `/usr/bin/codesign` 预先授权访问。生成期间的私钥文件保存在 0700 临时目录，结束时删除。
- 为这张证书添加用户级、限定 `codeSign` 策略的信任。这是一项持久信任设置，需要明确同意；系统可能要求你完成身份验证。
- 在忽略的 `.local-signing/identity.json` 固定证书指纹和钥匙串路径，并保存公开证书。私钥不保存在项目中。再次运行时复用身份；证书缺失、过期或钥匙串不可访问时不会自动生成替代身份。

项目忽略 `.local-signing/`、钥匙串和常见私钥文件。删除或更换签名证书会改变身份。新机器需自行配置签名并首次授权。本机证书不是 Apple Developer ID，也不能用于 Apple 公证发行。

已有 Apple 签名身份时可直接选择，无需创建本机证书：

```bash
security find-identity -v -p codesigning
CODE_SIGN_IDENTITY='上一步列出的证书指纹' bash build.sh
```

## 构建和升级验证

```bash
bash Scripts/check.sh
bash build.sh
python3 Tests/Integration/test_signing_config.py
python3 Tests/Integration/test_signing_identity.py
```

`swift build` 可直接进行未打包的开发构建；`build.sh` 打包默认要求固定证书，检查成功后才开始 release 编译。签名脚本不保留旧的临时签名规则，并拒绝仍依赖 `cdhash` 的证书构建；证书不可用时停止，不静默降级。

身份测试编译两个代码和版本号不同的合成 App，验证它们的 DR 一致、双方可满足对方的 DR；同时验证相同 Bundle ID 的 ad-hoc 签名及不同 Bundle ID 的同证书程序不能冒充它。测试不打开系统隐私数据库，也不申请完全磁盘访问。通过身份测试不等于已实测 TCC 授权跨升级保留。

从旧临时签名迁移时，退出 App，更新固定路径 `/Applications/微信消息监听.app`，再在系统“完全磁盘访问”中删除旧条目、添加新 App 并重新打开。新身份需要你首次手动授权。之后应继续使用同一证书、Bundle ID 和安装路径；不要用临时签名构建覆盖已授权版本。

仅合成测试明确需要临时签名时：

```bash
CODE_SIGN_IDENTITY=- bash build.sh
```

## 更名为“微迹”

1.6.0（build 13）将显示名称和新打包产物改为 `微迹.app`。继续使用原来的证书、`local.xzy.WeChatListener` Bundle ID、`WeChatListener` 可执行文件及应用数据目录，MCP 服务名称和地址也不变。已有档案与设置无需迁移。

本轮只生成 `dist/微迹.app`，保留当前 `/Applications/微信消息监听.app` 运行。历史验证记录中的旧名称与备份路径仍指向实际文件。后续安装优先覆盖原有安装位置，避免同时运行两份应用；如需把安装路径也改为 `/Applications/微迹.app`，须在解锁后验证系统权限条目及有效读取能力。签名身份匹配不代表已经验证授权保留。

## 本轮状态

2026-10-15：经用户明确同意，已创建并固定本机专用签名证书，配置用户级 `codeSign` 信任；再次运行配置会复用原身份。8 项配置检查通过。两份不同代码和版本号的合成 App 的 DR 一致、双向匹配通过；临时签名及其他 Bundle ID 的程序不能满足该身份规则。

已用该证书构建 1.4.3（build 9），164 项 Swift 检查、MCP 独立进程检查及严格签名校验通过。已备份旧版并更新 `/Applications/微信消息监听.app`，安装版与构建产物二进制一致，GUI 已重新打开；已有 MCP 进程保持运行。旧版副本位于 `Backups/微信消息监听-before-fixed-signing-741bafb9dd.app`。

签名迁移首次启动时，GUI 运行状态为 `blocked`，需要用户手动重新添加完全磁盘访问授权并重开 App。当前已验证签名身份跨代码更新稳定，尚未实测完成首次授权后的 TCC 跨实际升级保留，不能把 DR 测试通过当成已验证 TCC 保留。

SwiftPM 工程化后，release App 仍满足上述同一证书和 Bundle ID 的身份规则，已与安装版双向验证。该次重构仅生成 `dist` 产物，未替换安装版；生产二进制中不再包含测试入口或测试框架。

HTTP MCP 版本 1.5.0（build 10）继续使用同一证书和 Bundle ID，安装前后固定身份要求及严格校验通过。旧 1.4.3 应用备份于 `Backups/微信消息监听-before-http-1.4.3.app`，新版已更新到 `/Applications` 并验证自动提供本机 HTTP 服务。此验证不等同于完成此前待验证的完全磁盘访问授权保留实测。
