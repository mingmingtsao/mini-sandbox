# 文档索引

[返回仓库首页](../README.md)

## 从这里开始

| 文档 | 内容 |
|---|---|
| [运行指南](getting-started.md) | 环境要求、构建、运行 App、准备 VM 运行时、fixture 模式、测试、常见问题 |
| [架构设计](architecture.md) | 信任边界、总体架构、模块规格（M1–M12）、关键流程、授权模型、端口协议、资源上限、分工、已知限制 |
| [产品规格 v2](prd/desktop-sandbox/implementation-v2/README.md) | 产品实施基线、验收用例、里程碑、资料来源 |

## 工程文档（按模块）

工程文档记录各模块的接口约定、边界、限制与验证证据，多为英文。模块编号与[架构设计 §4](architecture.md#4-模块规格)一致。

### M1 契约层

| 文档 | 说明 |
|---|---|
| [contracts.md](engineering/contracts.md) | `RunGrant`、`ActionBinding`、`PendingAction`、`SecurityEvent` 的约束与验证 |

### M2 授权、生命周期与审计

| 文档 | 说明 |
|---|---|
| [authorization.md](engineering/authorization.md) | 授权账本：审批、撤销、派发意图、容量上限、审计事件清单 |
| [shared-run-authority.md](engineering/shared-run-authority.md) | 组合根共享同一 Authority 与生命周期引用 |
| [final-effect-clock.md](engineering/final-effect-clock.md) | 最终效果门禁的时钟采样与锁顺序 |

### M3 模型网关

| 文档 | 说明 |
|---|---|
| [model-transport.md](engineering/model-transport.md) | 固定上游的模型传输与凭据接口 |
| [host-model-integration.md](engineering/host-model-integration.md) | 模型网关：提案、审批、执行、完成审计 |
| [structured-model-tools.md](engineering/structured-model-tools.md) | 结构化消息、工具调用往返与流式增量 |
| [anthropic-native-requests.md](engineering/anthropic-native-requests.md) | 有界 Anthropic 原生请求字节绑定 |
| [claude-business-ingress.md](engineering/claude-business-ingress.md) | 固定版本 Claude CLI 请求准入 |
| [model-credential-reflection.md](engineering/model-credential-reflection.md) | 响应中的凭据反射检查边界 |
| [request-shape-metrics.md](engineering/request-shape-metrics.md) | 可选的请求结构度量 |

### M4 MCP 网关

| 文档 | 说明 |
|---|---|
| [host-mcp-integration.md](engineering/host-mcp-integration.md) | 宿主 MCP 网关：协议子集、目录冻结、资源授权、生命周期 |
| [claude-mcp-client.md](engineering/claude-mcp-client.md) | 固定版本 Claude MCP 客户端与本机仓库适配器 |

### M5 CLI 工具权限网关

| 文档 | 说明 |
|---|---|
| [cli-permission-clock.md](engineering/cli-permission-clock.md) | 工具权限回复的最终时钟校验 |

### M6 受控输出

| 文档 | 说明 |
|---|---|
| [controlled-execution-output.md](engineering/controlled-execution-output.md) | 受控执行开始与输出接收 |
| [native-response-consumer.md](engineering/native-response-consumer.md) | 原生响应消费者与本地 socket 投递 |

### M7 VM 管理与运行时

| 文档 | 说明 |
|---|---|
| [business-vm-owner.md](engineering/business-vm-owner.md) | 业务 VM 会话、连接所有权与停止报告 |
| [business-runtime-profile.md](engineering/business-runtime-profile.md) | Claude 业务运行时镜像配置与 guest 协议 |
| [headless-vm.md](engineering/headless-vm.md) | 无界面诊断 VM（`VMProbe`） |
| [agent-runtime.md](engineering/agent-runtime.md) | 运行时镜像、命令执行协议与资源预算 |
| [offline-diagnostic-guest.md](engineering/offline-diagnostic-guest.md) | 可复现的离线诊断 guest 构建 |
| [runtime-distribution.md](engineering/runtime-distribution.md) | 第三方输入版本、哈希与许可 |

### M8 工作区

| 文档 | 说明 |
|---|---|
| [workspace-copy.md](engineering/workspace-copy.md) | 导入副本、审阅、新目录导出 |
| [workspace-transfer.md](engineering/workspace-transfer.md) | 宿主与 VM 之间的文件树传输 |
| [workspace-final-effects.md](engineering/workspace-final-effects.md) | 已安装运行的工作区会话与最终文件效果 |
| [workspace-directory-search.md](engineering/workspace-directory-search.md) | 祖先目录搜索描述符 |

### M9 工作台与编排 · M10 App 外壳

| 文档 | 说明 |
|---|---|
| [native-workbench.md](engineering/native-workbench.md) | 原生授权工作台、连接设置、组合根关闭语义 |
| [business-app-task.md](engineering/business-app-task.md) | Tasks 页任务流程与本地 fixture 构建 |
| [app-fixture-launch.md](engineering/app-fixture-launch.md) | fixture App 的资源文件启动方式 |
| [app-virtualization-signing.md](engineering/app-virtualization-signing.md) | App 虚拟化权利签名 |
| [foundation-validation.md](engineering/foundation-validation.md) | 基础应用验证 |

### M11 Agent 协议探针

| 文档 | 说明 |
|---|---|
| [agent-protocol-probe.md](engineering/agent-protocol-probe.md) | 固定版本 Agent 协议探针 |
| [pinned-cli-local-capture.md](engineering/pinned-cli-local-capture.md) | 固定版本 CLI 本地采集 |
| [claude-broker-restricted-profile.md](engineering/claude-broker-restricted-profile.md) | 受限客户端配置 |
| [claude-broker-coding-profile.md](engineering/claude-broker-coding-profile.md) | 编码客户端配置 |

### M12 测试与 CI

| 文档 | 说明 |
|---|---|
| [ci.md](engineering/ci.md) | CI 检查范围、权限边界与本地复现 |
| [coverage.md](engineering/coverage.md) | Swift 行覆盖率口径与徽章发布 |

### 真实运行证据与复核

| 文档 | 说明 |
|---|---|
| [business-vm-evidence.md](engineering/business-vm-evidence.md) | 业务 VM 连接边界矩阵 |
| [business-cli-loopback-evidence.md](engineering/business-cli-loopback-evidence.md) | 真实 CLI 工具循环（回环模型） |
| [business-cli-mcp-evidence.md](engineering/business-cli-mcp-evidence.md) | 真实 CLI 调用本机 MCP |
| [business-egress-review.md](engineering/business-egress-review.md) | 业务出口人工复核包 |

## 产品资料

| 文档 | 说明 |
|---|---|
| [产品资料首页](prd/README.md) | 产品设计入口 |
| [桌面级安全沙箱](prd/desktop-sandbox/README.md) | 历史设计文档、评审与 v2 基线入口 |
| [FINAL_SPEC](prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md) | 当前产品实施基线 |
| [ACCEPTANCE](prd/desktop-sandbox/implementation-v2/ACCEPTANCE.md) | 37 项验收用例 |
| [ROADMAP](prd/desktop-sandbox/implementation-v2/ROADMAP.md) | 产品工程里程碑 |
| [SOURCES](prd/desktop-sandbox/implementation-v2/SOURCES.md) | 资料出处与待实测边界 |

## 文档约定

- **当前实现以代码为准**：工程文档描述接口约定与边界；架构设计是汇总入口；冲突时以源码和最新提交为准。
- **证据与声明分开**：文档中的 PASS 只来自实际运行；fixture、回环测试不等于真实外部服务联调。
- **新增模块或改变边界时**：同步更新[架构设计](architecture.md)对应的模块规格，并在本索引登记新文档。
