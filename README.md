# Pop

macOS 菜单栏翻译与 OCR 工具。支持划词、截图、图片识别、离线英汉词典和自带密钥的 AI 翻译服务。

**普通用户无需编译。** 从 [最新版本](https://github.com/YEMIN11238/Pop/releases/latest) 下载 `Pop-0.3.3-universal.dmg`，打开后把 **Pop.app 拖入 Applications（应用程序）**，再从应用程序打开 Pop。也可以下载同版 ZIP，解压后将 Pop.app 移入应用程序。

## 系统要求与首次打开

- **macOS 15 或更高版本**。通用安装包包含 Apple 芯片（arm64）与 Intel（x86_64）程序。Windows、Linux 和 macOS 14 及更早版本不支持。
- 首次启动显示设置页；之后从菜单栏图标或快捷键调用翻译、OCR。
- 0.3.3 使用 ad hoc 签名，**没有 Apple Developer ID 签名或公证**。从网络下载后 macOS 可能拦截：先尝试打开一次，再到「系统设置 → 隐私与安全性」，找到 Pop 的提示并选择「仍要打开」。在确认文件来自本仓库后使用系统提供的此选项；无需关闭系统安全保护。
- 截图功能需要「隐私与安全性 → 录屏与系统录音」（部分系统称「屏幕录制」）授权；跨应用取词、回填需要「辅助功能」。按系统提示开启，要求重新打开时执行即可。
- 免费系统翻译首次使用某个语言对时，可能需要联网下载 Apple 语言包。OCR 与随包英汉词典可本地使用；语言支持受 macOS 和服务商限制。
- macOS 15 支持普通窗口中的系统翻译。使用 Apple 系统服务的静默翻译和原图翻译需要 macOS 26+；较早系统可配置云翻译服务。
- 下载页附 `SHA256SUMS.txt`，可用 `shasum -a 256 文件名` 比对。签名变动后的更新可能需要重新授予系统权限。

## 主要功能

| 场景 | 功能 |
| --- | --- |
| 翻译 | 划词、输入、剪贴板、截图翻译；自动目标语言；多服务结果；朗读、复制与回填 |
| OCR | 截图、访达选图、剪贴板图片、静默识别、多图队列、二维码；可编辑并合并识别文本 |
| 本地服务 | Apple 系统翻译、Vision OCR、系统朗读、ECDICT 离线英汉词典 |
| AI / 云服务 | OpenAI 兼容接口、DeepSeek、Gemini、Claude、Ollama 等；可配置 URL、模型、密钥与提示词；原生协议按服务类型区分 |
| 日常使用 | 快捷键、收藏、历史、Markdown / 公式 / 图表、文本预处理、设置备份与恢复 |
| 扩展 | 部分 `.bobplugin` API 兼容、URL / AppleScript、PopClip / Raycast / Alfred 集成包 |

默认快捷键：`⌥D` 划词翻译，`⌥S` 截图翻译，`⌥A` 输入翻译，`⌥⇧S` 截图 OCR，`⌥C` 静默截图 OCR。可在设置中修改；与其他应用冲突时需改键。

免费服务不需要 Pop 账户或购买许可证。第三方云 API 的费用、可用模型和额度由服务商决定；Pop 不提供或内置他人的 API Key。DeepSeek 等使用 OpenAI 兼容服务，Gemini、Claude、Ollama 可选各自原生协议，详见 [云服务说明](CLOUD_SERVICES.txt)。

## 项目范围

Pop 是受 Bob 使用方式启发的独立实现，与 Bob 及其开发者无隶属关系。本仓库不包含 Bob 的二进制、反编译输出、词库或提取的界面图片；公开版本用 macOS 系统符号绘制工具栏和服务图标。

**目前不承诺与 Bob 完全相同。** Bob 账户、托管云额度与服务端内容不包含在内；词典数据、部分图标与文案不同；部分 OCR / TTS 提供商、插件 API、复杂排版、跨软件回填与多屏行为仍需继续验证。不能导入完整 Bob 私有配置或历史。内置服务可以直接开始使用；第三方 API、语言模型、插件与集成需要用户自行配置。

## 数据与隐私

- 设置和默认开启的翻译历史保存在本机 `~/Library/Application Support/Pop/`。可在设置里关闭保存历史。
- API Key 保存在 macOS 钥匙串。仅启用的服务会收到对应查询；云 OCR 会发送你选择的图片，远程图片加载默认关闭。
- 插件会执行 JavaScript 并可能发起网络请求。独立插件进程并非 macOS 安全沙盒，只安装可信插件。
- 仓库与安装包不包含开发者的个人设置、历史或凭据。应用没有自动上传诊断的端点。

## 从源码构建

普通下载用户不需要这些工具。开发者需要 **Xcode 26+ / macOS SDK 26+、Swift 6 工具链**；程序的部署目标仍为 macOS 15。部分 macOS 26 API 有运行版本保护。

```sh
git clone https://github.com/YEMIN11238/Pop.git
cd Pop
bash Scripts/build.sh --output "$PWD/dist.noindex" --scratch-path "$PWD/.build-release.noindex"
```

打包脚本用法见 `bash Scripts/package-release.sh --help`。测试：

```sh
swift test --scratch-path .build-tests.noindex
# 对已构建的包做集成自检：会启动临时本地测试端点，检查系统语言服务。
dist.noindex/Pop.app/Contents/MacOS/Pop --self-check
```

数据库已随源码和安装包提供，不需要在首次使用时下载。重新生成请参考 `Scripts/build-dictionary.py --help`；[固定上游数据与哈希](Resources/Dictionaries/ECDICT-provenance.json) 随包保存。

## 许可证与反馈

项目代码使用 [MIT License](LICENSE)。第三方代码、词典和字体保留各自许可证，见 [第三方材料说明](THIRD_PARTY_NOTICES.txt) 与 `Licenses/`。应用图标由项目发起人提供。服务商名称只用于说明可连接的接口。

问题请提交到 [Issues](https://github.com/YEMIN11238/Pop/issues)，附 macOS 版本、芯片类型、Pop 版本和复现步骤；不要提交密钥、完整个人配置或敏感原文。发布包的验证范围会写在每版 Release 说明中。
