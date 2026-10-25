# 更新日志

本项目的重要变更记录在此文件中。格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循[语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

## [0.1.0] - 2026-10-26

首个公开版本：在 Apple Silicon Mac 上以隔离 Linux VM 运行 Claude Code，凭据只留在宿主，每一次外部请求和工具权限都经原生审批，结果审阅后导出到新目录。

### 新增

- **原生工作台**：Tasks、Workbench、Environment 三个视图；项目、运行时与 CLI 磁盘选择，逐次内嵌审批，运行输出，随时可用的 Stop，结果审阅与新目录导出（#4、#8、#24、#25、#38）。
- **宿主授权账本**：不可变 `RunGrant`、一次性审批、原子消费、派发意图持久审计、连接撤销与到期，所有组件共享同一运行生命周期（#6、#17）。
- **最终效果门禁**：网络启动、socket 写入与文件写入前在同一把锁内重新采样可信时钟并校验运行状态（#19、#23）。
- **固定模型网关**：DeepSeek `deepseek-flash`，Anthropic 与 OpenAI 兼容协议，流式响应、工具调用往返、请求私有的凭据反射检查（#7、#9、#10、#21、#31、#36）。
- **MCP 网关**：本机仓库 profile，工具目录冻结、资源级授权与逐次审批；CLI 的 MCP 调用绑定实际 VM 连接（#5、#14、#37）。
- **Linux VM 运行时**：可复现的离线诊断 guest、无界面诊断 VM、固定版本 Claude Code 2.1.309 业务运行时；VM 无网卡、无宿主共享目录，连接所有权由宿主绑定（#11、#12、#15、#18、#33、#34）。
- **工作区**：私有项目副本、与 VM 的双向有界传输、不可变结果审阅、任务配额与取消、原子导出（#13、#26、#35）。
- **协议探针**：固定版本 CLI 的有界协议采集与请求结构度量（#16、#20）。
- **构建与打包**：`build-app.py` 生成带虚拟化权利的签名 App，支持 `--test-fixtures` 本地 fixture 版本、`VERSION` 文件与 `--build-number`；`build-vm-probe.py` 构建诊断 VM 程序（#29、#43）。
- **持续集成**：Workflow 语法、Python、Go、macOS 构建打包与 Swift 行覆盖率五项检查，覆盖率徽章自动发布；swift-format 与 ruff 格式检查（#22、#28、#30、#32、#40、#41、#44）。
- **文档**：产品规格 v2、架构设计、运行指南与按模块组织的文档索引（#1、#3、#42、#43）。
- **项目治理**：安全策略、贡献指南、Issue 与 PR 模板、CODEOWNERS、NOTICE、CodeQL 代码扫描与 Dependabot（#45）。

### 安全

- 正式构建启用固定 DeepSeek 业务路由的凭据出口；逐次审批、实际 VM 连接绑定与最终生命周期门禁保持不变（#43）。

[Unreleased]: https://github.com/mingmingtsao/mini-sandbox/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/mingmingtsao/mini-sandbox/releases/tag/v0.1.0
