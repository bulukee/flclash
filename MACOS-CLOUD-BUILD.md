# Salmon macOS 云端构建

1. 将当前 `FlClash` 目录完整上传到 GitHub 仓库。
2. 打开仓库的 **Actions** 页面。
3. 选择 **Salmon macOS Release**。
4. 点击 **Run workflow**。
5. 两个任务完成后，在运行页面底部下载构建产物：
   - `Salmon-macOS-arm64-1.1.22`
   - `Salmon-macOS-x64-1.1.22`

每份产物都包含 DMG 和对应的 SHA-256 文件。

该工作流默认生成未经过 Apple Developer 公证的测试发行包。公开商业发行仍需
Developer ID Application 证书与 Apple 公证，否则 Gatekeeper 会提示无法验证开发者。
