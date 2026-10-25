# 来源与验证边界

- [已合并的 PR #1](https://github.com/mingmingtsao/mini-sandbox/pull/1)：产品定位、模块、接口、界面、已有 REVIEW 与原型。
- [PR #1 早期设计快照](https://github.com/mingmingtsao/mini-sandbox/tree/54c0e6f3d9541b47f9ee1fd3b363ef63b813fd28)：静态对抗评审的固定对象，不等于合并时最终内容。
- 赛题原文及规则：组织方照片，2026-10-25 23:59 截止（UTC+08:00）。

## 技术资料

- **[W1]** Apple Virtualization.framework 与 Virtio socket：https://developer.apple.com/documentation/virtualization ，https://developer.apple.com/documentation/virtualization/vzvirtiosocketdevice
- **[W2]** MCP 协议与授权：https://modelcontextprotocol.io/specification
- **[W3]** MCP 安全与授权最佳实践：https://modelcontextprotocol.io/docs/2026-07-28/tutorials/security/security_best_practices
- **[W4]** Docker Sandboxes 对照实现：https://docs.docker.com/ai/sandboxes/architecture/
- **[W5]** Kubernetes NetworkPolicy 能力边界：https://kubernetes.io/docs/concepts/services-networking/network-policies/
- **[W6]** Claude Code gateway：https://code.claude.com/docs/en/llm-gateway
- **[W7]** Codex provider：https://developers.openai.com/codex/config-file/config-advanced
- **[W8]** Linux mlock 与 namespaces：https://man7.org/linux/man-pages/man2/mlock.2.html ，https://man7.org/linux/man-pages/man7/user_namespaces.7.html
- DeepSeek Harness：https://github.com/deepseek-ai/deepseek-harness

**这些资料仅是方案依据，不构成应用、隔离、认证、Agent 或 MCP 已通过实测的证明。** 所有实际验收应记录运行环境、版本、代码 SHA 和复现证据。
