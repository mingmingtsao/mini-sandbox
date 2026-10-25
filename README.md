# mini-sandbox

[![CI](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml?query=branch%3Amain)
[![Swift line coverage](https://raw.githubusercontent.com/mingmingtsao/mini-sandbox/ci-coverage/coverage.svg)](https://github.com/mingmingtsao/mini-sandbox/tree/ci-coverage)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

面向 Apple Silicon Mac 的 Agent 安全工作台。通过宿主侧授权、逐次审批、审计和隔离运行时，控制模型请求、工具调用及工作区数据的流转。

当前主线已包含原生工作台、模型与 MCP 网关、VM/CLI 实验运行时，以及副本审阅和新目录导出组件。项目仍在集成阶段，完整 App → VM → Agent → 模型/工具 → 审阅导出 → Stop 流程尚未完成端到端验收。

## 当前能力

| 方向 | 已合入内容 | 说明 |
|---|---|---|
| 原生工作台 | 审批与活动视图、模型连接设置、Stop 和关闭时的撤权与清理 | [工作台](docs/engineering/native-workbench.md) |
| 授权与审计 | 一次性审批、共享运行状态、到期与撤权控制、具体执行点的时钟校验 | [共享授权](docs/engineering/shared-run-authority.md) · [执行时钟](docs/engineering/final-effect-clock.md) |
| 模型接入 | 固定宿主路由、OpenAI/Anthropic 兼容协议、流式响应及有界工具往返 | [模型网关](docs/engineering/host-model-integration.md) · [原生请求](docs/engineering/anthropic-native-requests.md) |
| MCP | 受审批约束的宿主 HTTP 网关及回环测试服务 | [MCP 集成](docs/engineering/host-mcp-integration.md) |
| VM 与 CLI | 离线 Linux guest 构建、无网卡/无宿主共享目录的实验运行时、固定版本 CLI 请求捕获 | [运行时](docs/engineering/agent-runtime.md) · [CLI 捕获](docs/engineering/pinned-cli-local-capture.md) |
| 工作区 | 私有副本、不可变审阅、新目录导出、任务级配额及取消绑定的 VM 数据传输 fixture | [副本与导出](docs/engineering/workspace-copy.md) · [VM 传输](docs/engineering/workspace-transfer.md) |

## 快速开始

需要 Apple Silicon Mac、Xcode 或 Command Line Tools，以及 Python 3。建议使用与 CI 一致的 Xcode 26.6 / Swift 6.3 工具链；当前 CI 已验证 macOS 26.6.2、Swift 6.3.3。Swift 包的部署目标为 macOS 14，最低系统版本仍需单独验证。

编译全部 Debug 目标并查看宿主环境诊断：

```sh
swift build
swift run --skip-build MiniSandbox --diagnostics-json
```

构建并打开本地应用：

```sh
python3 scripts/build-app.py --configuration release --sign-identity -
open dist/MiniSandbox.app
```

应用默认提供工作台与环境检查入口。运行 VM/CLI 实验需要另外准备固定版本 guest、工具链和输入产物，步骤见对应工程文档。

本地打包使用 ad-hoc 签名；可通过 `--sign-identity` 指定已安装身份。打包脚本拒绝链接输出目录及未标记的旧 App，已标记旧产物会保留到 `dist/.MiniSandbox-backup-*`。Developer ID 分发签名、公证和异机安装尚未完成验收。

## 检查与 CI

仓库使用独立的可执行检查入口，`swift test` 不是当前测试入口。完成 `swift build` 后，可运行：

```sh
swift run --skip-build ContractChecks
swift run --skip-build AuthorizationChecks
swift run --skip-build WorkspaceChecks
swift run --skip-build WorkspaceTransferChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
```

[GitHub Actions](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml) 在 PR、`main` push 和手动触发时运行。当前包含 Python 安全回归、回环 OAuth/MCP fixtures、全部 Debug 目标编译、公共契约/API 检查及 Release App 打包和严格签名验证；汇总检查名为 `CI`。

CI 徽章显示 `main` 的构建状态；覆盖率徽章显示最近成功的主线 CI 中，现有 `ContractChecks` 对 `Sources/**/*.swift` 的实际行覆盖率，未执行的源码也计入分母。点击覆盖率徽章可查看每个文件的明细及对应提交。该数值不包含 Python、Go 或 VM/GUI 验收；完整口径见 [覆盖率说明](docs/engineering/coverage.md)。

精确 CI 范围及复现命令见 [持续集成说明](docs/engineering/ci.md)；其他组件检查入口见相应工程文档。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Sources/SandboxContracts` | 不可变运行快照、资源范围与审批绑定契约 |
| `Sources/SandboxHost` | 授权、审计、模型/MCP 网关、VM 和工作区组件 |
| `Sources/SandboxWorkbench` | 工作台、连接设置及运行生命周期编排 |
| `Sources/MiniSandboxApp` | SwiftUI 应用与诊断入口 |
| `Tools` | 离线 guest、运行时、CLI 捕获及工作区传输实验工具 |
| `Tests` | Swift 检查入口、Python 回归与测试 fixtures |
| `scripts` | 本地应用与 VM 探针的构建、签名工具 |
| `docs` | 产品规格、工程说明与各阶段验证记录 |

## 文档与当前边界

实施以已合入的 [v2 规格](docs/prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md) 为基线。[产品资料](docs/prd/README.md) 保留原始设计与历史原型；各工程文档记录对应增量的范围、复现步骤和历史验证结果。

完整业务流程、GUI/Keychain 实机交互、真实外部服务联调及发布验收仍需补齐。工作区传输目前是数据 fixture，具体文件写入/发布与共享授权时钟的完整绑定仍待集成；组件代码合入和 CI 通过不代表这些工作已完成。

## 许可证

[Apache License 2.0](LICENSE)。guest 和工具链依赖的再分发要求另见 [离线 guest 说明](docs/engineering/offline-diagnostic-guest.md)。
