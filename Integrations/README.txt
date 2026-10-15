Pop 第三方集成包
用于调用已安装的 Pop；第三方宿主需自行安装。

这些集成调用已安装 Pop 的 com.local.pop AppleScript request 命令，使用 {path, body} 结构。请求受理后，译文或 OCR 显示在 Pop，脚本返回的“已提交”不是译文。不会自动安装、运行第三方宿主，也不自动分配热键。

PopClip
双击 PopClip/pop.popclipext 或 PopClip/pop.popclipextz 由 PopClip 导入。选中文字后点 Pop 按钮。包使用 Config.json、经典 shellScriptFile 和用户提供的 Pop 图标；Config-reference.plist 只是包外的等价参考，包中没有两个 Config。未签名的本地扩展可能由 PopClip 提示确认。

Raycast
在 Raycast Settings > Extensions 使用 Add Script Directory，选择本目录 Raycast 文件夹。不要只拷贝单个 .sh，request.js 与 icon.png 需保留在同目录。提供 8 个 Script Commands：文字、划词、输入、剪贴板、截图翻译及截图/剪贴板/连续 OCR。文字命令接受一个原始 text 参数。

Alfred
双击 Alfred/pop.alfredworkflow 在支持 Workflows 的 Alfred 中导入。source 文件夹是可读源文件，不需另外安装。关键词：
    pop 文字          翻译文字
    pops              划词翻译
    popi              输入翻译
    popclip           剪贴板翻译
    popsnip           截图翻译
    popocr            截图 OCR
    popocrc           剪贴板 OCR
    popocra           连续 OCR
需要用户自行配置的 Pop 服务和相应系统权限。截图、划词等动作仍受 Pop 自身能力与权限状态限制。

参数与隐私
文字以 argv 传给 JXA，然后由 JSON.stringify 构造 path/body，不拼接成 JavaScript 或 AppleScript 源码，不使用 eval。PopClip 从 POPCLIP_TEXT 读取文字后，以一个双引号包裹的 argv 值传递；Alfred Run Script 为 argv 模式，未使用 {query} 插值。集成没有网络客户端、日志文件、剪贴板改写或配置读取逻辑；Pop 选中的服务仍可能按用户配置发送文字给服务商。macOS 可能要求宿主应用的自动化权限，需在系统正常授权流程处理。

检查范围与限制
verify_integrations.py 检查 zsh 语法与权限、plist、元数据、workflow 连线、ZIP CRC/目录及与可读源文件的一致性；编译 JXA，并以 dry-run 执行 16 次特殊文字 argv 往返和 7 类动作路由。测试覆盖 Unicode、emoji、CRLF、引号、反斜线及 shell/JS 注入字面值，不启动 Pop、不扫描已安装宿主，也不发送真实请求。
这些结构检查不替代宿主中的安装、自动化授权及实际窗口操作测试。请在自己使用的 PopClip、Raycast 或 Alfred 版本中完成验证。这些是 Pop 的独立配套集成，不会更改已装 Bob 扩展的目标。

重新生成
在项目目录执行 python3 Integrations/build_integrations.py。
再次检查执行 python3 Integrations/verify_integrations.py，完整 JSON 结果输出到标准输出。
如需保存，可加 --output /指定目录/checks.json；父目录会自动创建。检查仅构造 dry-run 请求，不会安装或发送实际 Pop 请求。生成脚本和检查脚本需要 macOS 和 Python 3；交付的集成本身只使用 macOS 内置 zsh/osascript。

格式依据（官方）
https://www.popclip.app/dev/packages
https://www.popclip.app/dev/shell-script-actions
https://www.popclip.app/dev/script-variables
https://www.popclip.app/dev/top-level-properties
https://www.popclip.app/dev/icons
https://github.com/raycast/script-commands
https://github.com/raycast/script-commands/blob/master/documentation/ARGUMENTS.md
https://www.alfredapp.com/help/workflows/inputs/keyword/
https://www.alfredapp.com/help/workflows/actions/run-script/

图标来自本项目 Resources/AppIcon.iconset，沿用用户提供的 Pop 图标；代码独立编写。未打包第三方示例代码或 Bob 包内资源。
