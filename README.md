# mini-sandbox

[![CI](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml?query=branch%3Amain)
[![Swift line coverage](https://raw.githubusercontent.com/mingmingtsao/mini-sandbox/ci-coverage/coverage.svg)](https://github.com/mingmingtsao/mini-sandbox/tree/ci-coverage)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)
![Platform: macOS 14+ Apple Silicon](https://img.shields.io/badge/platform-macOS%2014%2B%20%7C%20Apple%20Silicon-lightgrey)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)

**面向 Apple Silicon Mac 的 AI Agent 安全工作台。**
Agent 在没有网卡、没有宿主共享目录的 Linux 虚拟机里修改项目副本；模型与 MCP 凭据只留在宿主，每一次外部请求和工具权限都由你在原生界面中逐次批准，结果审阅后导出到新目录。

> **快速导航**：[运行指南](docs/getting-started.md) · [架构设计](docs/architecture.md) · [文档索引](docs/README.md) · [产品规格](docs/prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md)

---

## 为什么需要它

让 AI Agent 直接在本机运行，意味着它能读取你的全部文件、拿到你的 API key、访问任意网络。mini-sandbox 把这些能力拆开，由宿主逐项控制：

| 风险 | mini-sandbox 的做法 |
|---|---|
| Agent 读取无关文件 | 只把你选择的项目**复制**进 VM；自动排除 `.git`、`.ssh`、`.env*`、私钥类文件 |
| API key / 令牌泄露 | 凭据存在 macOS Keychain，仅宿主在发出请求的瞬间读取；VM 内只有公开占位值 |
| 任意网络访问 | VM **没有网卡**；只能通过 vsock 访问宿主为本次运行开放的固定通道 |
| 未经同意的操作 | 每次模型请求、文件读写、命令执行、MCP 调用都需原生审批；默认拒绝 |
| 覆盖原项目 | 结果先审阅差异，再导出到**新目录**；原项目从不被修改 |
| 停不下来 | Stop 立即撤销本次运行的全部授权并停止 VM，旧批准全部失效 |

## 功能

| 方向 | 功能 | 文档 |
|---|---|---|
| 原生工作台 | 项目与任务配置、连接设置、内嵌审批、运行输出、Stop 与资源清理 | [工作台](docs/engineering/native-workbench.md) · [App 任务](docs/engineering/business-app-task.md) |
| 授权与审计 | 一次性审批、资源范围、到期与撤权、最终效果时钟门禁、append-only 审计 | [授权](docs/engineering/authorization.md) · [共享授权](docs/engineering/shared-run-authority.md) · [执行时钟](docs/engineering/final-effect-clock.md) |
| 模型接入 | 宿主固定路由、Anthropic/OpenAI 兼容协议、流式响应、凭据反射检查 | [模型网关](docs/engineering/host-model-integration.md) · [原生请求](docs/engineering/anthropic-native-requests.md) |
| MCP | 宿主 HTTP 网关、工具目录冻结、资源级授权与逐次审批 | [MCP 集成](docs/engineering/host-mcp-integration.md) · [Claude MCP 客户端](docs/engineering/claude-mcp-client.md) |
| VM 与 CLI | 离线 Linux guest、固定版本 Claude Code CLI、无网卡无共享目录 | [VM 所有权](docs/engineering/business-vm-owner.md) · [运行时](docs/engineering/business-runtime-profile.md) |
| 工作区 | 私有项目副本、VM 双向传输、不可变结果审阅、新目录导出、配额与取消 | [副本与导出](docs/engineering/workspace-copy.md) · [VM 传输](docs/engineering/workspace-transfer.md) |

## 架构一览

```text
MiniSandbox.app ─ 可信宿主
├── SwiftUI 界面    Tasks · Workbench · Environment；原生审批与 Stop
└── RunComposition  组合根，持有唯一授权账本与审计文件
    ├── 授权与审计  RunAuthorizationController · RunLifecycle · JSONL 审计
    ├── 模型网关    严格解析 → 审批 → 读取 Keychain 凭据 → TLS → 固定模型服务
    ├── MCP 网关    资源范围 → 审批 → 注入宿主令牌 → 本机 MCP 服务
    ├── 权限网关    CLI 工具权限请求 → 审批 → 原样回传
    ├── 受控输出    通过最终效果门禁后才写回 guest
    ├── VM 管理     Virtualization.framework；0 网卡、0 共享目录
    └── 工作区      导入副本 → 回传校验 → 审阅 → 导出到新目录
          │
          │  vsock（唯一通道）
          ▼
Linux arm64 VM ─ 不可信
└── guest 驱动 + Claude Code CLI + 项目副本
```

模块规格、端到端时序、授权模型、端口协议与分工见 **[架构设计](docs/architecture.md)**。

## 快速开始

**环境要求**：Apple Silicon Mac、macOS 14+、Swift 6（Xcode 或 Command Line Tools）、Python 3.9+。完整说明见 **[运行指南](docs/getting-started.md)**。

```sh
git clone https://github.com/mingmingtsao/mini-sandbox.git
cd mini-sandbox

# 1. 构建并检查本机环境（virtualizationSupported 应为 true）
swift build
swift run --skip-build MiniSandbox --diagnostics-json

# 2. 打包并打开应用（本地 ad-hoc 签名，带虚拟化权利）
python3 scripts/build-app.py --configuration release --sign-identity -
open dist/MiniSandbox.app

# 3. 运行离线回归（示例）
export TMPDIR="$(cd "$TMPDIR" && pwd -P)"
swift run --skip-build ContractChecks
swift run --skip-build WorkspaceChecks
```

运行真实任务还需要准备 Linux 运行时镜像和固定版本 CLI 磁盘（均不在仓库中），步骤见 [运行指南 §7](docs/getting-started.md#7-准备-vm-运行时进阶)。不使用真实凭据体验完整界面流程，见 [本地 fixture 模式](docs/getting-started.md#8-本地-fixture-模式开发者)。

## 项目状态

当前为 **v0.1.0 开发预览**，以本机构建与验证为主。

| 项 | 状态 |
|---|---|
| 真实模型出口 | 自 2026-10-26 起正式构建**已启用**固定 DeepSeek 业务路由（[启用记录](docs/engineering/business-egress-review.md#启用记录)）；每个请求仍需逐次审批，凭据只在宿主读取 |
| Agent | Claude Code 2.1.309；Codex、DSH 尚未实现 |
| 模型 | DeepSeek `deepseek-flash`（Anthropic 兼容协议） |
| MCP | 本机 `127.0.0.1` 固定仓库 profile；远端 HTTP、OAuth、stdio 连接器尚未实现 |
| 分发 | 仅本地 ad-hoc 签名，未公证；运行时镜像与 CLI 需自行构建/获取 |
| CI | 构建、契约、离线回归、打包签名与覆盖率；不启动 VM、不连接真实服务 |

完整限制与规格差异见 [架构设计 §12–§13](docs/architecture.md#12-实现现状与已知限制)。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Sources/SandboxContracts` | 运行授权快照、资源范围、待审批动作等数据契约 |
| `Sources/SandboxHost` | Host Core：授权与审计、模型/MCP/权限网关、受控输出、VM 管理、工作区 |
| `Sources/SandboxWorkbench` | 组合根、任务协调、工作台、连接设置与 SwiftUI 视图 |
| `Sources/MiniSandboxApp` | App 入口、命令行诊断、环境检查页 |
| `Tools/` | guest 镜像构建、guest 驱动、协议探针、工作区传输与诊断 VM 工具 |
| `Tests/` | Swift 可执行检查、Python/Go 测试与回环驱动、fixtures |
| `scripts/` | App 与 VM 探针的构建签名脚本、覆盖率脚本、权利文件 |
| `VERSION` | 应用版本号（`build-app.py` 读取，发版时只改这一处） |
| `docs/` | [架构设计](docs/architecture.md)、[运行指南](docs/getting-started.md)、[工程文档](docs/README.md)、[产品规格](docs/prd/README.md) |

## 文档

| 文档 | 适合谁 |
|---|---|
| [运行指南](docs/getting-started.md) | 第一次构建、运行、测试；准备 VM 运行时；排查问题 |
| [架构设计](docs/architecture.md) | 理解信任边界、模块规格与分工、关键流程与授权模型 |
| [文档索引](docs/README.md) | 按模块查找全部工程文档与验证证据 |
| [持续集成](docs/engineering/ci.md) · [覆盖率](docs/engineering/coverage.md) | CI 检查范围与本地复现 |
| [产品规格 v2](docs/prd/desktop-sandbox/implementation-v2/README.md) | 产品边界、验收用例与里程碑 |
| [运行时来源与分发](docs/engineering/runtime-distribution.md) | 第三方依赖版本、哈希与许可 |

## 参与开发

1. 从 `main` 新建分支，提交信息遵循 `feat:` / `fix:` / `docs:` / `test:` / `ci:` 前缀；
2. 本地至少运行与改动相关的检查（见 [运行指南 §9](docs/getting-started.md#9-运行测试)）；
3. 提交 Pull Request，CI 全部通过后合并。

安全相关的设计约束（不得把凭据放进 guest、不得放开网络、不得宿主裸跑 Agent）见 [产品规格](docs/prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md)。

## 许可证

本仓库源码以 [Apache License 2.0](LICENSE) 发布。Linux、Alpine 软件包与 Claude Code 等第三方组件**不**因此重新授权，其分发要求见 [运行时来源与分发](docs/engineering/runtime-distribution.md) 与 [离线 guest 文档](docs/engineering/offline-diagnostic-guest.md#redistribution-checklist)。
