# Copilot Native

原生 macOS 模拟面试问答助手，使用 Swift 6、SwiftUI 和 SwiftData，最低支持 macOS 26

## 使用

1. 用 Xcode 打开 `Copilot Native.xcodeproj`，选择 **Copilot Native** Scheme 并运行
2. 点击工具栏的 **+**，一起填写问题和 Markdown 答案
3. 在题库页输入中文、英文或拼音搜索，问题命中排在答案命中之前
4. 若没有本地结果，输入至少 2 个字符并停止输入约 700 毫秒后，应用会自动请求 AI
5. 在 **模型设置** 中填写兼容 OpenAI Chat Completions 的 HTTPS 接口地址、模型名称和 API Key，可先测试连接；AI 答案可审核编辑后保存到题库

题库只保存在本机。API Key 存在本应用的 macOS 钥匙串中，不写入工程文件
本地没有匹配结果时，当前搜索内容会发送到你配置的远程模型接口

## 验证

```sh
xcodebuild -project 'Copilot Native.xcodeproj' -scheme 'Copilot Native' -configuration Debug -destination 'platform=macOS,arch=arm64' build
xcodebuild -project 'Copilot Native.xcodeproj' -scheme 'Copilot Native' -configuration Debug -destination 'platform=macOS,arch=arm64' test
```

`project.yml` 是 XcodeGen 的工程定义；仓库已经包含生成好的 `.xcodeproj`，打开和构建无需安装 XcodeGen
