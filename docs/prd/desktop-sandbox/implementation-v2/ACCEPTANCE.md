# mini-sandbox 产品验收清单 v2

**本页只是验收设计，全部状态为 `NOT_RUN`；测试脚本、真实 VM、MCP 和应用均未由本 PR 验证。** 通过必须绑定源代码 SHA、产物摘要、环境、步骤和实际日志；模型拒绝执行恶意指令不能替代系统对抗测试。

| 用例 | 场景 | 通过条件 | 状态 |
|---|---|---|---|
| E01 | 正式应用启动 | 打包 App 独立启动，不依赖 IDE 或关闭系统安全防护 | NOT_RUN |
| E02 | 真实 VM | VM、vsock、无通用网卡、停止过程有真机证据 | NOT_RUN |
| E03 | 三 Agent 闭环 | Claude Code/Codex/DSH 分别完成真模型、改文件、测试与 MCP | NOT_RUN |
| E04 | MCP 配置易用性 | 无需在 guest 输入密码或手改敏感配置 | NOT_RUN |
| E05 | HTTP 认证 MCP | 真实调用成功且资源越权、写操作受限 | NOT_RUN |
| E06 | OAuth MCP | 登录、授权回调、失效、刷新和撤权验证 | NOT_RUN |
| E07 | 无凭据 stdio | 只可访问已授权副本和所需能力 | NOT_RUN |
| E08 | 可代理认证 stdio | 至少一个真实程序经受控网关成功调用且不持有长期秘密 | NOT_RUN |
| S01 | 长期凭据隔离 | canary 不进入 guest 环境、配置、磁盘、命令行和日志 | NOT_RUN |
| S02 | 宿主文件边界 | guest 普通用户和 root 不能读取未导入 canary | NOT_RUN |
| S03 | 网络出口边界 | 直接 IP、IPv6、绕过代理不能直连 | NOT_RUN |
| S04 | 运行主体绑定 | 伪造 runId、bridge 或连接标识不能访问其他运行 | NOT_RUN |
| S05 | 连接器隔离 | 不同信任域不共享未授权工作区、文件或连接 | NOT_RUN |
| S06 | 不安全认证降级 | 未知密码/HMAC/私钥方式不自动注入 guest | NOT_RUN |
| S07 | SSRF 与认证泄露 | 任意 URL、重定向、DNS 改变不能挟带凭据 | NOT_RUN |
| S08 | 资源级授权 | 允许操作仓库 A 不意味着可以访问 B 或写入 A | NOT_RUN |
| S09 | 工具自报不可信 | 伪造 readOnlyHint 或工具名称不能增加权限 | NOT_RUN |
| S10 | 完整 MCP 协议表面 | resources/prompts/roots/sampling/elicitation 等未支持能力拒绝 | NOT_RUN |
| S11 | 工具发现变更 | 未知/空/更新目录遵循显式状态与重审 | NOT_RUN |
| S12 | 显式拒绝优先 | 风险标签、默认模板不会恢复已拒绝能力 | NOT_RUN |
| S13 | 批准权限子集 | 不用高风险全选；关闭与超时按拒绝处理 | NOT_RUN |
| S14 | 策略篡改 | 变更镜像、策略、连接等不能复用旧授权扩权 | NOT_RUN |
| S15 | 单次操作绑定 | 改参、跨会话、迟到或重放审批不执行 | NOT_RUN |
| S16 | 停止撤权 | 停止后不得新 dispatch；在途结果如实标记 | NOT_RUN |
| S17 | 启动失败清理 | 任意阶段取消或失败没有遗留有效授权 | NOT_RUN |
| S18 | 故障关闭 | Broker 与审计失败不会退回默认允许或直连 | NOT_RUN |
| S19 | 上游副作用不确定 | 外部写后断连不自动重试，记录 unknown | NOT_RUN |
| S20 | 安全导入 | 目录越界、软硬链接、特殊文件和超大输入被拒绝 | NOT_RUN |
| S21 | 安全导出 | 路径穿越、同名碰撞、中断不可越界或覆盖宿主 | NOT_RUN |
| S22 | 恶意输出 | 终端控制符、网页内容无法执行宿主命令或代批 | NOT_RUN |
| S23 | 可信安全事件 | 只有宿主执行点事件驱动可信拒绝统计 | NOT_RUN |
| S24 | 资源限制 | CPU/内存/磁盘/消息与并发上限有效 | NOT_RUN |
| S25 | 诊断脱敏 | 真实秘密不进入日志、诊断和发布材料 | NOT_RUN |
| S26 | 重启与污染 | 旧 VM 污染不进入新运行，旧授权不复活 | NOT_RUN |
| S27 | OAuth 绑定攻击 | state/PKCE/issuer/resource/audience 绑定与 token 混用拒绝 | NOT_RUN |
| U01 | 非实现者端到端 | 不用手编写配置即可完成产品主流程 | NOT_RUN |
| R01 | 交付制品一致性 | 最终 App/镜像、代码 SHA、测试证据、视频一致 | NOT_RUN |

测试结果允许 `NOT_RUN / BLOCKED / FAIL / PASS`，不得用 mock 冒充真实服务联调；安全门禁不能以其他用例通过率抵消。使用测试账户、canary 凭据和可控外部服务，不对真实账户做破坏性测试。
