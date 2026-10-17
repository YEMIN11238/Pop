# 智谱与硅基流动预设来源

核对日期：2026-10-17。内置的是接口配置模板，不是云账户、模型权重或托管免费额度。两个模板初始关闭，需要用户填写个人 API Key 后自行启用。

- [智谱 OpenAI API 兼容文档](https://docs.bigmodel.cn/cn/guide/develop/openai/introduction)：官方基础地址为 `https://open.bigmodel.cn/api/paas/v4/`，使用个人 API Key。
- [智谱 GLM-4 文档](https://docs.bigmodel.cn/cn/guide/models/text/glm-4)：模型预设采用当前文档的 `glm-4-flash-250414`、`glm-4-flashx-250414`、`glm-4-plus`。Bob 截图中的旧 `GLM-4-Flash` 展示名不作为当前 API 别名仍有效的证据。
- [硅基流动 Chat Completions](https://docs.siliconflow.cn/docs/api/chat-completions-post)和[文本生成指南](https://docs.siliconflow.cn/docs/userguide/capabilities/text-generation)：OpenAI 兼容基础地址为 `https://api.siliconflow.cn/v1`，公共 API 要求个人 Bearer API Key。文档示例包含 `deepseek-ai/DeepSeek-V3.2` 与 `deepseek-ai/DeepSeek-V4-Flash`。
- [硅基流动的 Bob 教程](https://docs.siliconflow.cn/docs/usercases/use-siliconcloud-in-bob)：Bob 内置默认模型是 `Qwen/Qwen2.5-7B-Instruct`。这能证明参考产品的集成方式，不能证明 Pop 获得相同免密钥合作额度。

模型列表是可编辑建议，用户仍可填入账户实际可用的完整模型 ID。模型上下线、价格和账户限制以提供商为准；Pop 不为某个预设承诺免费。升级只补充缺失且禁用的模板，不覆盖原服务的名称、模型、地址、密钥身份、启用状态或顺序；保存后删除的模板不会在下次启动时自动恢复。
