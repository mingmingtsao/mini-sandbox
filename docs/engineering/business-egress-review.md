# S02 业务出口集成人工复核包

## 启用记录

| 项 | 内容 |
| --- | --- |
| 日期 | 2026-10-26 |
| 决定人 | 仓库维护者 [@mingmingtsao](https://github.com/mingmingtsao) |
| 改动 | `Sources/SandboxHost/BusinessModelActivation.swift`：`credentialEgressEnabled` 由 `false` 改为 `true` |
| 范围 | 正式构建的固定 `deepseek-flash` Anthropic 业务路由（`https://api.deepseek.com/anthropic/v1/messages?beta=true`）；固定 Claude Code 2.1.309 CLI 与业务镜像；单个任务、2 CPU / 1 GiB、无 NIC / 宿主共享目录 |
| 不变的约束 | 每个模型请求与 CLI 工具权限仍需逐次原生审批；必须绑定实际 VM owner；凭据只在宿主网关通过最终生命周期门禁后读取；Stop / 过期 / 连接撤销后不再发出新请求 |
| 不包含 | 远端或真实 MCP 出口、自定义路由、其他模型或 Agent |
| 复核依据 | 下文复核包（候选 `3e44ab0`）及其列出的假 canary 与实际 VM 证据；本记录是维护者的启用决定，**不等同于**下文所要求的独立真人复核结论。若后续补充独立复核，请在此表追加审阅者、精确 head 与结论 |

以下为启用前的复核包原文，其中“仍为 `false`”等表述描述的是当时的候选状态。

本包供独立真人审阅后决定是否允许一次有限的真实模型 C08 验收。它本身不是批准，也不启用真实凭据出口。核对时的源码候选是 `3e44ab0223408f5c8f2873ffb24caeec918de10d`；下列行号均属于该提交。后续候选必须列明与此提交的相关差分，不能把本文或旧结论自动套到新 head。

## 已有批准及审阅范围

用户明确转述 GitHub 用户 **q96456** 已通过 [PR #31](https://github.com/mingmingtsao/mini-sandbox/pull/31)，结论只绑定 head `b04250751ef51cd9f22442ce22b7e1b6cd93f253`。这是用户报告的人工审阅记录；不声称存在由系统代写或核验的 GitHub review。旧结论不覆盖此后新增的 Claude 业务路由、实际 VZ owner、业务 App/CLI 接线或本次候选的全部改动。已核对 `ModelCredentialReflection.swift` 本身相对该获批 head 无差分；新增集成仍需本次复核。

本次需要审阅的是：同一请求使用的宿主凭据是否仍只进入固定上游鉴权及请求私有反射 guard；所有下游内容是否先经过该 guard，再通过绑定实际 VM 的最终消费者；Stop、过期及 owner 退休是否能在最后一次实际调用前阻断效果。`BusinessModelActivation.credentialEgressEnabled` 在候选中仍为 `false`（`Sources/SandboxHost/BusinessModelActivation.swift:5`）。本包未访问真实 key，未改变该常量。

## 入口到最终消费者

文件链接指向仓库源码；审阅应使用上述固定提交的内容和行号。

| 边界 | 具体位置 | 需要确认的事实 |
| --- | --- | --- |
| 真实 VM 入站 owner | [BusinessVMConnection.swift](../../Sources/SandboxHost/BusinessVMConnection.swift)，40、90、128、161 行 | 仅实际 session 的 listener/device 可构造 owner；固定 run/runtime/epoch/service；descriptor 只移交一次；退休关闭原 VZ 连接。模型服务端口为 4064。 |
| HTTP/CLI 方言 | [BusinessHTTPIngress.swift](../../Sources/SandboxHost/BusinessHTTPIngress.swift)，32、93 行；[AnthropicNativeRequest.swift](../../Sources/SandboxHost/AnthropicNativeRequest.swift) | 有界、严格解析 CLI 请求与 selector；所有语义适配在批准前完成。guest 不能指定真实 provider 地址或凭据。 |
| 完整批准与出口身份 | [HostModelGateway.swift](../../Sources/SandboxHost/HostModelGateway.swift)，223、244、317、348 行 | v4 envelope 包含完整 canonical body、selectors、connection/account/route 版本及实际 runtime/channel；工厂要求同一个 owner；execute 在消费票据前拒绝非 VZ、错 owner 及纯解析 proposal。旧 raw callback / 内存出口不能 dispatch v4。 |
| 固定模型路由与私有凭据 | [ModelTransport.swift](../../Sources/SandboxHost/ModelTransport.swift)，158、173、179、190、214 行 | 两次启用门禁均在凭据准备前；唯一业务目的地为 `https://api.deepseek.com/anthropic/v1/messages?beta=true`；同一次 credential read 同时用于 `x-api-key` 与请求私有 guard。无 guest 凭据字段、通用自定义路由或请求间 guard 缓存。 |
| 实际网络开始 | [ModelTransport.swift](../../Sources/SandboxHost/ModelTransport.swift)，402–427 行；[RunLifecycle.swift](../../Sources/SandboxHost/RunLifecycle.swift)，31、161 行 | operation 锁 → 实际 owner 锁 → lifecycle 最终 clock → scope/owner/期限检查 → 直接 `URLSessionDataTask.resume()`；绑定 VM 的 operation 不能直接调用 legacy start。 |
| 反射判定 | [ModelCredentialReflection.swift](../../Sources/SandboxHost/ModelCredentialReflection.swift)，31、38、45 行；[ModelTransport.swift](../../Sources/SandboxHost/ModelTransport.swift)，451、493、520 行 | 解码后的文本、结构化值/键、暴露的 metadata/usage、SSE 跨片及完整工具参数/raw fragment 在释放前检查；结束清除请求私有引用。HTTP 错误 body 不返回给下游。 |
| 成功与审计 | [HostModelGateway.swift](../../Sources/SandboxHost/HostModelGateway.swift)，422、445、454–487 行 | provisional 安全文本可增量释放；成功终结及 audit-held 后缀等 durable completion；开始后的拒绝记录 unknown，不重试、不伪造成功。 |
| 最终模型字节 | [ControlledRunOutput.swift](../../Sources/SandboxHost/ControlledRunOutput.swift)，118、136、161 行；[RunLifecycle.swift](../../Sources/SandboxHost/RunLifecycle.swift)，182 行；[NativeResponseChannel.swift](../../Sources/SandboxHost/NativeResponseChannel.swift)，74、92、119 行 | writer/owner 先持有，随后 lifecycle clock/撤销检查，再直接有界 nonblocking `send`；每次 partial/EAGAIN/EINTR 重试重新入门禁。不是提前发放的可转移 permit，也不是稍后执行的裸闭包。 |
| 实际 CLI 接收与 stdout/stderr | [business_cli.py](../../Tools/AgentRuntime/business_cli.py)，143、195、216、230 行 | guest loopback proxy 4061 → VZ 4064；固定真实 CLI 子进程使用正常 stream-json；stdout/stderr 由有界 control frame 回传。fixture 不替 CLI 生成 tool_result。 |
| App 输出 | [BusinessTaskController.swift](../../Sources/SandboxWorkbench/BusinessTaskController.swift)，285、340、418 行；[BusinessDisplayOutput.swift](../../Sources/SandboxHost/BusinessDisplayOutput.swift)，34、44、49 行；[RunLifecycle.swift](../../Sources/SandboxHost/RunLifecycle.swift)，234 行 | VM control 内容经哈希/大小/运行身份检查和具体 display 最终门禁后，UI 才读取已接受的不可变 history。Stop 同步撤销 run/VM/workspace/display 并解开审批等待。 |

UI display 是生命周期消费者，**不是另一个持有真实 key 的扫描器**。其反射保障依赖真实凭据从未进入 guest，以及模型响应已在宿主 transport 释放前拦截。此包不声称能检测任意编码/变换后的秘密、无关秘密、任意跨字段拼接或通用 DLP；也不声称安全清零堆内存。完整算法边界见 [model-credential-reflection.md](model-credential-reflection.md)。

## 可复现的假 canary 检查

以下命令从固定候选的干净 checkout 执行。它们使用随机内存 canary 或公开 fixture 假值，不读 Keychain、不接真实 provider。需要 macOS/Swift；实际 VM 项还需要支持 Virtualization 的主机和已核验的业务镜像、固定 CLI 磁盘。不要给测试参数替换成真实 key。

传输矩阵与实际 AF_UNIX peer：

```sh
swift build --product StructuredModelChecks
swift run --skip-build StructuredModelChecks
swift build --product ExecutionBoundaryChecks
python3 Tests/ModelReflectionTests/loopback.py
swift run --skip-build ExecutionBoundaryChecks --native-response
swift run --skip-build ExecutionBoundaryChecks --native-repairs
swift run --skip-build ExecutionBoundaryChecks --final-effect-clock
```

实际 VZ/CLI 的 SSE metadata 反射负例（每次新建输出目录；下列三个输入路径对应已保存的本机证据）：

```sh
set -eu
# 维护者私有证据目录 mini-sandbox-artifacts-20261025（未纳入仓库）；复现时换成你自己的私有目录
TASK_EGRESS_ARTIFACTS="$EVIDENCE_ROOT"
TASK_EGRESS_IMAGE="$TASK_EGRESS_ARTIFACTS/business-image-v5"
TASK_EGRESS_VENDOR="$TASK_EGRESS_ARTIFACTS/vendor/claude.raw"
TASK_EGRESS_OUT="$TASK_EGRESS_ARTIFACTS/s02-review-$(uuidgen)"
mkdir -m 700 "$TASK_EGRESS_OUT"
python3 Tools/WorkspaceTransfer/build_host.py business-fixture "$TASK_EGRESS_OUT/build" > "$TASK_EGRESS_OUT/build.log" 2>&1
codesign --force --sign - --entitlements scripts/vm-probe.entitlements "$TASK_EGRESS_OUT/build/host"
python3 Tools/AgentRuntime/business_fixture.py "$TASK_EGRESS_OUT/build/host" "$TASK_EGRESS_IMAGE" "$TASK_EGRESS_VENDOR" "$TASK_EGRESS_OUT/evidence" reflection
```

`business-fixture` 编译时显式设置 `SANDBOX_TEST_FIXTURES`。该入口的凭据提供者固定为公开假值，目的地固定为本机 loopback，不接收任意 host/key/provider；这些构造器不在正常 App 中。`build.json` 保存完整编译命令和源码/Contracts 对象哈希，编译前后不一致即拒绝证据；其中 host hash 是签名前值。这个 fixture 会自动批准其固定诊断请求，不能用于真实任务审批，也不能当作用户操作过 App 的证据。

## 已核对的证据

| 层次 | 实际结果 | 证据与限制 |
| --- | --- | --- |
| 传输/结构矩阵 | 63 组通过；修复前同源回归 52 通过、11 失败 | 维护者本机临时日志 `mini-sandbox-safety-reflection-{red,green}.log`（未纳入仓库）。含解码 primitives、metadata、工具参数、跨片、audit-held 正反例。 |
| 实际 HTTP → AF_UNIX peer | 13 cases / 13 HTTP arrivals；每例 credential read/resume 各 1；所有重建输出无完整 canary | 维护者本机临时日志 `mini-sandbox-native-reflection-loopback.log`（未纳入仓库）。五个反射非流式及 error-body 例为 0 peer bytes；三个 SSE 反射例允许安全前缀/metadata，但无完整秘密和成功终结；四个正例保持真实有效内容。 |
| 实际 VZ → CLI | 1 次上游请求；`nativeWriteCalls=0`、`nativeBytes=0`、`acceptedFinals=0`；已接受 stdout/stderr canary occurrences=0；实际停止且 callbacks settled | `cli-reflection-fixture-v1/host.log` 与 `fixture.json`，fixture `host_exit=0`、`errors=[]`。对应测试在读取报告后还断言 private disk 已删除。该例覆盖 SSE message metadata 含活动假凭据的形态。 |

实际 VM 证据位于上述 `TASK_EGRESS_ARTIFACTS` 下，构建为 `business-fixture-host-v11`。独立核对了原始日志，并比较其 `build.json` 中以下 8 个源文件哈希，全部与固定候选一致：`ModelCredentialReflection.swift`、`ModelTransport.swift`、`HostModelGateway.swift`、`NativeResponseChannel.swift`、`RunLifecycle.swift`、`BusinessVMConnection.swift`、`ControlledRunOutput.swift`、`Tools/AgentRuntime/BusinessFixtureProbe.swift`。其他文件以完整 inventory 为准，不能把部分匹配外推为整个 App 二进制一致。

- `business-fixture-host-v11/build.json` SHA-256：`b68a8ee16f191598fb5e1e84c4f75bdb1c9457649d8cbb40200a6dc76324f5ee`。
- `business-image-v5/runtime.cpio.gz` SHA-256：`76124ff1500810098e24a467d28e4e06da207ff7556b607e8e5738e3d75f2acb`。
- `vendor/claude.raw` SHA-256：`c4e512ea944c420c80285b4c4bd817098d9845ac6aa6e423bbbb58b8d3a9bf43`；固定 CLI 为 Claude Code 2.1.309。

以上是本机保留的证据位置，不声称它们已上传或仅凭路径便可由其他机器访问。真人可在这台主机查阅原件，或对同一源码和输入重新执行命令。

## 独立代码复核结论与有限放行对象

本轮安全复核与业务实现分开阅读了 model v4 完整批准、实际 VM/channel 所有权、网络 start、native 最终 send、CLI 权限及 model-only App 的异步撤销/清理/采用路径。实际发现并修复了权限 reply 超过动作期限仍能发送、模型批准缺少实际 runtime/channel 强绑定等问题；随后复核未发现已确认的新绕路。独立实际权限测试还证明过期、持锁等到过期、not-before 和 Stop 后 0 send/0 bytes；它是另一项安全验证，详见 [cli-permission-clock.md](cli-permission-clock.md)。复核者参与了 guard/lifecycle 的实现和测试，因此这不是独立真人审阅，也不是自我授权。

App 源码复核范围：Stop 同步撤销并取消真实 owner，关闭等待导入/run/export 和实际清理，结果采用绑定实际停止报告，stdout/stderr 只投影已接受 history。MCP 有独立协议、反射和目录冻结范围，此包不为真实 MCP 出口放行。

请真人在新结论中写明**精确集成 head、审阅者、日期、允许/不允许及范围**。有限运行的审阅对象为：固定 `deepseek-flash` Anthropic 业务路由、固定 CLI/镜像、一个新 run 的合成 C08 项目任务，最多 15 分钟、2 CPU/1 GiB、无 NIC/宿主共享目录；模型请求与正常 CLI 工具动作仍逐项批准，真实 key 仅由宿主管理，不进入源码、命令参数、guest 或证据。真实 MCP、自定义路由、长期启用、main 合并和 Release 不属于该对象。

这项人工结论只解除对应复核前置条件；实际启用仍需单独、可审阅的有限任务改动及精确制品记录。文档及假 canary 通过不代表已允许真实出站。任何改变上述 route、guard、批准绑定、最终 consumer 或 CLI/UI 出口的后续差分必须重新标明，并由真人决定原结论是否仍适用。
