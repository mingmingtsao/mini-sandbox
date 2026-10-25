# mini-sandbox

[![CI](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml?query=branch%3Amain)
[![Swift line coverage](https://raw.githubusercontent.com/mingmingtsao/mini-sandbox/ci-coverage/coverage.svg)](https://github.com/mingmingtsao/mini-sandbox/tree/ci-coverage)
[![License: Apache-2.0](https://img.shields.io/badge/License-Apache--2.0-blue.svg)](LICENSE)

面向 Apple Silicon Mac 的 Agent 安全工作台。通过 Linux 虚拟机隔离 Agent 运行环境，在宿主侧管理模型连接、MCP 工具、逐次审批、审计和项目副本。

## 功能

| 方向 | 功能 | 文档 |
|---|---|---|
| 原生工作台 | 项目与任务配置、连接设置、审批、运行输出、Stop 与资源清理 | [工作台](docs/engineering/native-workbench.md) |
| 授权与审计 | 一次性审批、资源范围、到期与撤权控制、执行时钟校验 | [共享授权](docs/engineering/shared-run-authority.md) · [执行时钟](docs/engineering/final-effect-clock.md) |
| 模型接入 | 宿主侧固定路由、OpenAI/Anthropic 兼容协议、流式响应 | [模型网关](docs/engineering/host-model-integration.md) · [原生请求](docs/engineering/anthropic-native-requests.md) |
| MCP | 宿主 HTTP 网关、工具审批和资源范围控制 | [MCP 集成](docs/engineering/host-mcp-integration.md) |
| VM 与 CLI | 离线 Linux guest、固定版本 CLI、无通用网卡和宿主共享目录 | [运行时](docs/engineering/agent-runtime.md) |
| 工作区 | 私有项目副本、不可变结果审阅、新目录导出、任务配额与取消控制 | [副本与导出](docs/engineering/workspace-copy.md) · [VM 传输](docs/engineering/workspace-transfer.md) |

## 快速开始

需要 Apple Silicon Mac、Xcode 或 Command Line Tools，以及 Python 3。推荐使用 Xcode 26.6 / Swift 6.3 工具链。

编译并查看宿主环境信息：

```sh
swift build
swift run --skip-build MiniSandbox --diagnostics-json
```

构建并打开本地应用：

```sh
python3 scripts/build-app.py --configuration release --sign-identity -
open dist/MiniSandbox.app
```

任务运行所需的 Linux guest、固定版本 CLI 和项目副本准备方式，见[运行时文档](docs/engineering/agent-runtime.md)与[工作区文档](docs/engineering/workspace-copy.md)。

本地打包默认使用 ad-hoc 签名，可通过 `--sign-identity` 指定已安装的签名身份。已有应用产物保留在 `dist/.MiniSandbox-backup-*`。

## 仓库结构

| 路径 | 内容 |
|---|---|
| `Sources/SandboxContracts` | 运行快照、资源范围与审批绑定契约 |
| `Sources/SandboxHost` | 授权、审计、模型/MCP 网关、VM 和工作区 |
| `Sources/SandboxWorkbench` | 工作台、连接设置与运行生命周期编排 |
| `Sources/MiniSandboxApp` | SwiftUI 应用与诊断入口 |
| `Tools` | guest、运行时、CLI 与工作区传输工具 |
| `Tests` | Swift、Python 和 Go 测试 |
| `scripts` | 应用与 VM 工具的构建、签名脚本 |
| `docs` | 产品规格与工程文档 |

## 文档

- [产品资料](docs/prd/README.md)
- [产品规格](docs/prd/desktop-sandbox/implementation-v2/FINAL_SPEC.md)
- [持续集成与开发命令](docs/engineering/ci.md)
- [离线 guest 与依赖来源](docs/engineering/offline-diagnostic-guest.md)

## 许可证

[Apache License 2.0](LICENSE)。第三方 guest 和工具链依赖的分发要求见[离线 guest 文档](docs/engineering/offline-diagnostic-guest.md)。
