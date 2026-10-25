# mini-sandbox 产品实施方案 v2

本目录定义产品实施基线与验收条件。实际结果以对应代码与制品的验证记录为准。

本文档承接 [#1 已合并设计](https://github.com/mingmingtsao/mini-sandbox/pull/1)。保留原 `source/`、`REVIEW.md`、`ACCEPTANCE.md` 和原型，不修改历史设计；与当前规格冲突时，以本目录的 `FINAL_SPEC.md` 为准。

- [FINAL_SPEC.md](FINAL_SPEC.md)：macOS 产品范围、技术架构、凭据与权限、模型/MCP、文件、安全审计和生命周期。
- [PR1_REVIEW.md](PR1_REVIEW.md)：基于 #1 早期快照的静态评审及对抗性比较。
- [ACCEPTANCE.md](ACCEPTANCE.md)：37 项产品功能、安全、可用性和发布验收条件。
- [ROADMAP.md](ROADMAP.md)：11 个产品实现里程碑及依赖。
- [SOURCES.md](SOURCES.md)：资料出处、假设及尚需实测的边界。

## 裁决摘要

1. 保留 #1 易懂的授权 UI、后果描述和审批快照。
2. 采用无通用网络的 VM＋宿主受限服务网关；长期凭据不进入不可信 Agent/MCP 执行域，取消自动明文内存注入兜底。
3. 授权绑定实际运行、连接、操作和资源；低风险分类和工具自报不会自动扩权。
4. 默认在隔离副本中修改项目，用户审阅后导出到新目录，不自动覆盖宿主项目。
5. 安全计数仅使用宿主执行点事件；guest 上报仅作诊断。未实测功能不能显示为已完成。
