# 自动构建与发布

正式发布从 **0.1.0** 开始。之前 1.x 编号是本地开发构建，保留在历史验证记录中，不重写 Git 历史。版本唯一来源为 `Resources/Info.plist`：`CFBundleShortVersionString` 使用稳定 SemVer，`CFBundleVersion` 保持递增（0.1.0 为 build 18）。不改变档案格式或已有应用数据。

## 日常 CI

推送 `main`、创建或更新 PR，以及手动运行 [CI](https://github.com/zen-xu/wechat-listener/actions/workflows/ci.yml) 时，在 Apple Silicon 和 Intel 的 macOS 15 runner 上执行：

1. 使用 Xcode 26.2 的 Swift 工具链，校验版本、发布保护条件和 Swift 格式。
2. 执行完整 Swift Testing、签名配置以及 stdio/HTTP MCP 合成集成检查，不跳过图片检查，不读取真实通知或微信文件。
3. 生成临时签名的本架构开发 App，并上传 7 天保留的 CI 构建附件。开发附件不应覆盖已授权的固定签名安装版。

PR 检查不读取发布 Secret，工作流默认只有仓库读取权限。Actions 固定完整提交 SHA，Dependabot 每月检查更新。runner 和工具链以实际工作流运行结果为准，参考 [GitHub runner 清单](https://github.com/actions/runner-images/tree/main/images/macos)。

## 发布版本

修改版本及构建号、提交并等待 CI 后，推送与版本完全一致的标签：

```bash
git tag -a v0.1.0 -m '微迹 0.1.0'
git push origin v0.1.0
```

下一版本例如 `0.1.1` / build 19，使用新标签 `v0.1.1`；不移动旧标签、不覆盖已发布资产。当前只接受三段稳定版，预发布版本需先扩展校验与发布策略。

[Release](https://github.com/zen-xu/wechat-listener/actions/workflows/release.yml) 先在两种架构上复用完整 CI，再校验标签等于 App 版本、提交属于 main 历史。随后才导入固定发布证书，分别编译 arm64 / x86_64，用 lipo 合并、统一签名，并验证两种架构、证书要求及打包版本。对最终产物再运行 MCP 进程检查与跨构建签名身份检查。

发布附件：

- `Weiji-<版本>-macos-universal.dmg`：应用、Applications 快捷入口及安装说明。
- `Weiji-<版本>-macos-universal.zip`：同一份签名 App。
- `release-manifest.json`：源提交、版本、构建号、架构、最低系统、证书指纹和下载文件摘要。
- `SHA256SUMS`：ZIP、DMG 和 manifest 的 SHA-256。

ZIP 解压后重新校验签名和版本，DMG 验证完整性。附件齐备且摘要一致后创建草稿、上传、核对远端文件名与大小，最后公开该 Release（仓库仍保持私有）。中断时保留草稿，可重跑同一标签的失败任务；已经正式发布的版本拒绝覆盖。

## CI 签名

本机签名私钥不可导出，继续保存在本机，不上传。CI 使用独立、长期复用的项目发布证书，公钥证书固定在 `Resources/ReleaseSigning.cer`，私钥 PKCS#12 及其密码放在 GitHub 加密 Secrets：

- `RELEASE_CERTIFICATE_BASE64`
- `RELEASE_CERTIFICATE_PASSWORD`
- `RELEASE_CERTIFICATE_SHA1`

首次配置命令是 `python3 -B Scripts/setup_ci_signing.py --repo zen-xu/wechat-listener`。它生成新的 CI 专用密钥，上传到明确指定仓库；临时私钥文件自动删除，不触碰本机钥匙串、信任或固定签名。再次运行保留原 Secret，不自动轮换；部分配置或公钥不一致时拒绝覆盖。

只有通过检查的标签发布 job 能访问发布 Secrets；证书导入临时 runner 钥匙串，后续步骤只接收证书指纹和钥匙串路径，结束时清理。导入程序拒绝在本机或自托管 runner 上修改钥匙串，遵循 [GitHub 的证书导入方式](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。丢失或更换 Secret 会改变后续签名身份，必须明确安排迁移，不能静默重新生成。

这是固定的自签项目证书，不是 Apple Developer ID，产物尚未公证。首次打开可能需要在系统设置“隐私与安全性”中允许。从原本机证书切换到 CI 发布证书，需要重新添加一次完全磁盘访问；后续 CI 构建复用同一证书与 Bundle ID，但 TCC 授权保留仍需真实升级验收。不要关闭系统安全检查，也不要用临时签名开发附件覆盖正式安装版。

本机继续 `bash build.sh` 使用原本机证书；`bash build.sh --universal` 生成通用 App。自动发布不安装或重启本机 App，不更改当前安装版、系统权限或已存档通知。
