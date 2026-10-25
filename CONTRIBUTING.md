# 参与贡献

感谢你对 mini-sandbox 的关注。本文说明开发环境、提交流程、代码规范与评审要求。

## 基本约定

- 保持专业、尊重、就事论事。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私密报告，不要公开提交。
- 动手前建议先阅读[架构设计](docs/architecture.md)，了解模块边界与职责分工。

## 开发环境

按[运行指南](docs/getting-started.md)准备 Apple Silicon Mac、Swift 6 与 Python 3。完成后自检：

```sh
export TMPDIR="$(cd "$TMPDIR" && pwd -P)"
swift build
swift run --skip-build ContractChecks
```

## 工作流程

1. 从最新的 `main` 创建分支，命名为 `feat/<主题>`、`fix/<主题>`、`docs/<主题>`、`test/<主题>` 或 `ci/<主题>`。
2. 一个 PR 只解决一个问题；纯格式化改动单独提交。
3. 提交信息遵循 [Conventional Commits](https://www.conventionalcommits.org/zh-hans/)：`feat`、`fix`、`docs`、`test`、`ci`、`style`、`refactor`、`chore`，可加作用域，例如 `fix(workspace): reject stale review export`。
4. 创建 PR 并按模板填写摘要、测试计划与安全影响。
5. CI 全部通过、完成评审后以 **squash merge** 合并。

## 代码规范

| 语言 | 工具 | 配置 |
|---|---|---|
| Swift | 工具链自带的 `swift format` | [`.swift-format`](.swift-format) |
| Python | [ruff](https://docs.astral.sh/ruff/) 0.17.1 | [`ruff.toml`](ruff.toml) |

提交前在仓库根目录运行：

```sh
git ls-files -z '*.swift' | xargs -0 swift format format --in-place --parallel
git ls-files -z '*.swift' | xargs -0 swift format lint --strict --parallel
uvx ruff@0.17.1 format . && uvx ruff@0.17.1 check .   # 或 pipx run ruff==0.17.1 ...
```

CI 会执行同样的检查。批量格式化提交需登记到 [`.git-blame-ignore-revs`](.git-blame-ignore-revs)；本地可执行 `git config blame.ignoreRevsFile .git-blame-ignore-revs`。

## 测试要求

- 项目使用独立的可执行检查程序，而不是 `swift test`。请按改动模块运行[对应检查](docs/getting-started.md#92-按模块运行-swift-检查)。
- 新功能同时覆盖允许路径与拒绝路径；修复缺陷时先补一个能复现问题的检查。
- 修改 Swift 产品代码时，提交前运行 `python3 scripts/swift-coverage.py`，它执行与 CI 相同的全部 Swift 检查。
- CI 不启动 VM、不连接真实服务。涉及 VM 或真实 CLI 的改动，请在 PR 中附上本机验证记录：命令、输出摘要与制品哈希。

## 安全敏感改动

以下区域的改动由 [CODEOWNERS](.github/CODEOWNERS) 指定的维护者评审：

- 授权、生命周期与审计：`AuthorizationController`、`RunLifecycle`、`RunClock`、`SecurityEvent`、`RunComposition`
- 出口与凭据：`BusinessModelActivation`、`ModelTransport`、`ModelCredential*`、`HostModelGateway`、`HostMCPGateway`、`MCPTransport`
- VM 数据面与工作区：`BusinessVM*`、`ControlledRunOutput`、`NativeResponse*`、`Workspace*`
- 构建、签名与 CI：`scripts/`、`*.entitlements`、`.github/`

必须遵守的约束：

- 真实凭据不得出现在代码、测试、命令行参数、日志或 guest 中；测试一律使用合成 canary。
- 不得为 guest 增加网卡、宿主共享目录或通用转发通道。
- 不得在宿主上执行导入的项目代码或 guest 产物。
- 改变安全边界时，同步更新[架构设计](docs/architecture.md)与相关工程文档。

## 文档与变更记录

- 新增或调整模块边界：更新架构设计中的模块规格，并在[文档索引](docs/README.md)登记新文档。
- 面向用户的改动：在 [CHANGELOG.md](CHANGELOG.md) 的 `[Unreleased]` 小节记录。

## 许可

提交的贡献按 [Apache License 2.0](LICENSE) 授权（见许可证第 5 条）。
