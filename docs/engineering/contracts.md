# 公共契约

候选接口依据：[#3 FINAL_SPEC §5](https://github.com/mingmingtsao/mini-sandbox/blob/docs/final-sandbox-spec-20261023/docs/prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md)。此模块定义数据与纯检查，不提供运行时授权服务，也不暴露 guest 控制接口。

## 运行快照

`RunGrant` 绑定 run ID、epoch、镜像摘要、适配器版本、工作区快照、策略摘要、审批快照、连接/资源范围、显式拒绝与资源限制。构造和 Codable 解码均校验字段；有效期必填，重复连接、无效摘要和非法限制被拒绝。

`decision` 仅作当前快照的精确范围检查。未知连接、未授予资源、过期或尚未生效均拒绝，显式拒绝优先。返回 `.allowed` 不是执行许可：Host Core 仍须校验实际连接身份、当前运行/epoch、撤销、适配器范围、上游权限和必要的单次审批。

不支持通配资源或按风险等级自动放行。资源标识的解析与规范化由受信适配器负责，不把字符串名称当成业务权限证明。

## 待审批动作

`ActionBinding` 保存已由宿主验证的规范化请求字节及 SHA-256，绑定运行、epoch、连接、schema、操作和实际资源。输入最大 64 KiB，摘要不能代替原始请求。

`PendingAction` 由宿主创建 ID/nonce，包含展示快照和最多五分钟有效期。它刻意不提供 Decodable，不能从 guest JSON 构造已批准对象。`matches` 只做不可变绑定比较，不消费动作，不表示审批完成；原子消费、撤权线性化、持久 dispatch 意图和重放防护由后续 Host Core 实现。

本模块不解析任意 JSON 或声称完成规范化。适配器必须先拒绝重复键、歧义资源和无法稳定规范化的请求，再构造绑定；不得直接将 guest 原始数据传入。

## 事件

`SecurityEvent` 位于 `SandboxHost`，构造器仅对该模块内部开放；外部 App/适配器只能读取与编码事件，不能直接构造 hostEnforcement。它仅 Encodable，guest 原始诊断不能反序列化为宿主可信事件；未来接收器必须强制使用 `guestDiagnostic` 来源。此编译边界不抵抗已被攻陷的宿主进程。

`isHostRejection` 只选取 `hostEnforcement + deny + notDispatched`。去重、单调序号分配、持久化、日志脱敏以及执行点来源约束属于后续审计服务，不能仅凭枚举值宣称事件可信。

## 验证覆盖

`swift run ContractChecks` 覆盖构造与解码失败、显式拒绝及时间条件重叠、未知资源/连接、限制、动作改参/epoch/nonce 和重复连接。`python3 -m unittest discover -s Tests/APITests -v` 验证外部构造/解码编译失败，并运行宿主内部事件来源过滤断言。它是 S12/S14/S15/S23 的基础契约测试，不代替对应真实运行验收。

E01 当前仅验证基础 `.app` 打包/启动；E02 及真实 Agent/MCP、安全集成仍为 NOT_RUN。缺少平台/账号时另记 BLOCKED，不用 fixture 结果替代。
