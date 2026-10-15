# Salmon macOS 云端构建

1. 将当前代码提交并推送到 `codex/macos-*` 命名的分支，自动启动构建。
2. 打开仓库的 **Actions** 页面。
3. 选择 **Salmon macOS Release**。
4. 查看新构建；如需手动重建，点击 **Run workflow**，选择当前代码所在分支。
5. 两个任务完成后，在运行页面底部下载构建产物：
   - `Salmon-macOS-arm64-版本号`
   - `Salmon-macOS-x64-版本号`

每份产物都包含 DMG 和对应的 SHA-256 文件。

构建前会运行客服配置、DNS 和首页布局相关测试。工作流使用 `--env stable`，
生成 Release 模式安装包，当前未配置 Apple Developer 签名和公证。公开发行仍需
Developer ID Application 证书与 Apple 公证，否则 Gatekeeper 会提示无法验证开发者。
