# 安全策略

mini-sandbox 的核心价值在于隔离与授权边界。我们重视每一份安全报告，并承诺以协调披露的方式处理。

## 支持的版本

| 版本 | 安全修复 |
|---|---|
| `main` 分支 | ✅ |
| 0.1.x（最新发布版） | ✅ |
| 更早版本 | — |

## 报告漏洞

**请不要**在公开 Issue、Pull Request 或讨论中披露漏洞细节。

请通过 GitHub 私密漏洞报告提交：**[Report a vulnerability](https://github.com/mingmingtsao/mini-sandbox/security/advisories/new)**

报告中请尽量包含：

- 受影响的版本或提交 SHA，以及 macOS 版本与芯片型号
- 问题类型与影响，例如凭据进入 guest、绕过逐次审批、Stop 后仍产生外部效果、导出越界
- 最小复现步骤或概念验证。请使用合成 canary 凭据，**不要**提交真实密钥
- 你建议的修复方向（可选）

## 处理流程

| 阶段 | 目标时间 |
|---|---|
| 确认收到 | 3 个工作日内 |
| 初步评估与严重程度判定 | 10 个工作日内 |
| 修复与发布 | 按严重程度排期，高危问题优先 |

修复发布后，我们会通过 [GitHub Security Advisory](https://github.com/mingmingtsao/mini-sandbox/security/advisories) 公开说明，在报告者同意的前提下致谢，并在需要时申请 CVE。

## 范围

**范围内**（示例）：

- guest 获得宿主长期凭据，或宿主凭据出现在 guest 可见的数据中
- 绕过逐次审批、重放已消费的批准、跨运行或跨 epoch 使用授权
- Stop、过期或连接撤销之后仍产生新的网络请求、socket 写入或文件写入
- guest 数据导致宿主读取未导入的文件，或导出时越界写入
- vsock 协议解析导致宿主崩溃、内存破坏或授权状态错误
- guest 诊断被记录为宿主执行事件

**范围外**：

- 依赖已被攻陷的宿主、root 或同 UID 恶意进程的攻击（见[架构设计 · 信任边界](docs/architecture.md#2-信任边界)）
- Apple Virtualization.framework、Linux 内核、Claude Code CLI、模型或 MCP 服务自身的漏洞，请向相应上游报告；若影响本项目的安全边界，欢迎同时告知我们
- 已批准的模型请求中包含项目内容，这是经用户确认的设计行为
- 社会工程、物理接触、本地资源耗尽类拒绝服务

## 安全研究准则

请仅在你拥有或已获授权的设备与账户上测试，使用合成凭据和本地 fixture（见[运行指南 · 本地 fixture 模式](docs/getting-started.md#8-本地-fixture-模式开发者)），不要访问或修改他人数据。对善意遵守本策略的研究，我们不会追究责任。

---

**English summary.** Please report vulnerabilities privately through [GitHub private vulnerability reporting](https://github.com/mingmingtsao/mini-sandbox/security/advisories/new); do not open public issues. We aim to acknowledge reports within 3 business days and complete initial triage within 10 business days. Security fixes are provided for `main` and the latest 0.1.x release.
