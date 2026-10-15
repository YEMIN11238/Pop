Pop · macOS 划词翻译与截图 OCR

在不同应用中快速取词、翻译和识别图片文字，支持本地词典及自定义 AI 服务。
支持 macOS 15+，Apple Silicon 和 Intel。无需开发工具或编译。

安装：把 Pop.app 拖入「应用程序」，然后从「应用程序」打开。
启动默认显示设置页，关闭设置后仍可用菜单栏或快捷键调用。
第一次查词：按 ⌥A，输入 apple 后回车，在「简明英汉词典」卡片复制结果。
查本地词典不需 API Key、联网、录屏或辅助功能权限；系统翻译可能另行提示下载语言包。

当前发布包没有 Apple Developer ID 签名与公证。首次打开可能被系统拦截；确认来自本仓库后，先尝试打开一次，再到「系统设置 → 隐私与安全性」选择「仍要打开」。无需关闭系统安全保护。
截图需录屏权限；跨应用划词、回填需辅助功能权限。暂不授权时，仍可手动输入、粘贴文字和选择本地图片 OCR。
⌥D 划词翻译；⌥S 截图翻译；⌥A 输入翻译；⌥⇧S 截图 OCR；⌥C 静默截图 OCR。
系统翻译的语言包首次准备可能需要联网。Vision OCR 与随包词典可本地使用。Apple 系统服务的静默翻译和原图翻译浮层需要 macOS 26+，并已安装对应语言包。
自定义云 API 需自行填写地址、模型、密钥并启用；本地模型需先安装、下载并运行。第三方费用由服务商决定。

2026-10-16 实测：Pop 0.3.3，macOS 27.0.1，Apple Silicon。用户在 TextEdit 选中英文并按 ⌥D 后，取词与系统翻译成功，复制粘贴一致；通过 OCR 窗口「截图 OCR」按钮完成真实屏幕框选、Vision 识别及复制粘贴。本地词典与选图 OCR 也已完成实测，无个人云 API Key。
产品页动图为三个场景的真实操作关键步骤回放，并非连续录屏。本轮未验证 ⌥A / ⌥⇧S 的实际按键触发、译文回填、其他 macOS 或 Intel 的 GUI、云 API、本地模型、首次 Gatekeeper 放行或首次语言包下载。完整范围：https://github.com/YEMIN11238/Pop/blob/main/docs/demo-notes.md

更新：退出 Pop，用新版替换「应用程序」中的 Pop.app，再启动。无需删除本机设置。签名变化后如权限失效，按首次使用教程检查并重新授权。
产品介绍：https://yemin11238.github.io/Pop/
首次使用：https://github.com/YEMIN11238/Pop/blob/main/docs/first-use.md
源码与完整说明：https://github.com/YEMIN11238/Pop
下载更新：https://github.com/YEMIN11238/Pop/releases/latest

Pop 是受 Bob 使用方式启发的独立实现，不承诺全部功能或显示内容一致。
项目代码采用 MIT，第三方材料保留各自许可证；声明随应用资源一并提供。
