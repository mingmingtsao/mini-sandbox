# 持续集成

[`CI` 工作流](../../.github/workflows/ci.yml) 在 Pull Request（包括 Draft）及 `main` 的 push 上执行，也提供 [手动触发入口](https://github.com/mingmingtsao/mini-sandbox/actions/workflows/ci.yml)。README 顶部的状态徽章绑定 `main`，点击可查看该分支的运行记录。历史 PR 不会仅因新增工作流而自动补跑，需更新到包含该工作流的分支并触发新的 PR 事件。

## 检查范围

| 检查 | Runner | 内容 |
|---|---|---|
| Workflow syntax and Python lint | GitHub 托管 Ubuntu 24.04 | 固定版本 actionlint；`scripts`、`Tests`、`Tools` 的 Python 语法；校验 SHA-256 后的 ruff 0.17.1 执行 `ruff check` 与 `ruff format --check`（配置见 `ruff.toml`） |
| Python safety and host fixtures | GitHub 托管 Ubuntu 24.04 / Python 3.13 | 打包路径与所有权；回环 OAuth/MCP fixtures；覆盖率计数；guest builder、runtime、capture 和 VM 构建器安全回归 |
| Go guest protocol | GitHub 托管 Ubuntu 24.04 / go.mod 固定版本 | guest 协议与身份解析的 `-race` 检查；交叉编译 Linux ARM64 guest probe |
| macOS build, contracts and packaging | GitHub 托管 macOS 26 / Apple Silicon | 工具链 `swift format lint --strict`（配置见 `.swift-format`）；全部 Debug targets；`ContractChecks`；公共 API 编译边界；无凭据 CLI selector 和 driver 超时/子进程清理；Release App 构建、ad-hoc 签名及严格签名验证 |
| Swift line coverage | GitHub 托管 macOS 26 / Apple Silicon | 独立插桩构建；运行离线 Swift、运行时/镜像边界、原生视图及认证回环检查；统计全部 `Sources/` 行覆盖率；保存报告 artifact 与摘要 |
| CI | GitHub 托管 Ubuntu 24.04 | 汇总以上五项结果；任何失败、跳过或取消都不能被当作通过 |
| Publish main coverage badge | GitHub 托管 Ubuntu 24.04 | 仅主线成功运行后，将覆盖率徽章与报告更新到 `ci-coverage` 分支 |

Swift 运行集合由 `scripts/swift-coverage.py` 的 `CHECKS` 统一维护。包括 `ContractChecks`、`AuthorizationChecks`、`ModelTransportChecks --offline`（排除隔离 Keychain CRUD）、`HostIntegrationChecks`、`StructuredModelChecks`、`WorkbenchChecks`、`SharedAuthorityChecks`、`WorkspaceChecks`、`WorkspaceTransferChecks`、`VMChecks`、`RuntimeReceiveChecks` 和 `BusinessIngressChecks`，以及任务/连接原生视图、执行边界额外 selector、MCP transport、Claude MCP 与模型反射等认证回环和 App 只读诊断。仓库使用这些可执行入口，而非 `swift test`。所有回环 driver 显式使用插桩构建的二进制，计数随子进程合并。

Python 按测试目录分别发现，避免没有包标记的子目录被顶层 discovery 静默跳过。故意包含错误逻辑、供 Agent 修复的 `Tools/AgentRuntime/fixture/test_logic.py` 不作为成功回归运行。CI 不构建完整 guest 镜像、不下载真实 CLI 产物。

回环 HTTP fixture 直接使用数字地址绑定，跳过 `HTTPServer` 默认的反向 DNS 查询；回归检查在禁止 `socket.getfqdn` 的情况下验证启动与 HTTP 行为，避免宿主 DNS 延迟吞掉 driver 的超时预算。

## 代码扫描与依赖更新

[`CodeQL` 工作流](../../.github/workflows/codeql.yml) 在 PR、`main` push、每周一定时及手动触发时运行，分别分析 GitHub Actions、Python、Go（交叉编译 guest probe 与协议测试）和 Swift（macOS 26 上 `swift build`）。结果上传到仓库的 Code scanning；该工作流只申请 `security-events: write`、`contents: read` 与 `actions: read`。

[Dependabot](../../.github/dependabot.yml) 每周检查 GitHub Actions 更新，新版本发布满 7 天后才会提出 PR，SHA 与版本注释一并更新。仓库同时启用 Dependabot 安全告警、secret scanning 与 push protection。

## 工具链

macOS runner 已从 `macos-15` 更新为 `macos-26`，与主线使用的 Swift 工具链保持一致。[2026-10-25 的主线运行](https://github.com/mingmingtsao/mini-sandbox/actions/runs/40199585315) 已通过全部 CI 检查，日志记录 macOS 26.6.2、Xcode 26.6、Swift 6.3.3；最新结果以徽章及运行页面为准。

## 权限与运行边界

- 只使用 GitHub 托管临时 runner，不使用自托管 Mac。
- 检查任务仅允许 `contents: read`，汇总 job 无仓库权限。仅覆盖率发布 job 使用 `contents: write`；该 job 不在 PR 上运行，且依赖全部检查成功。
- 检查任务的 checkout 不持久化凭据；覆盖率发布任务使用 checkout 管理的临时凭据，仅向 `ci-coverage` 分支普通推送报告，不强制覆盖历史。Actions 固定到完整 commit SHA；actionlint 与 ruff 下载后校验固定 SHA-256。
- 不引用仓库 secrets、不配置产品凭据，不使用 `pull_request_target` 或特权 `workflow_run` 链。
- 仅上传覆盖率报告 artifact（保留 14 天），不发布 Release、不上传分发包、不执行自动合并，也不改分支保护。版本发布由维护者按 [CHANGELOG](../../CHANGELOG.md) 打 tag 并创建 GitHub Release。
- 同一 PR 的旧运行会在新提交到来时取消；每个 job 有超时。工具链具体版本记录在运行日志，runner 镜像仍会由 GitHub 更新。

## 不代表通过的项目

本 CI 不启动 VM，不运行真实 Agent、真实模型服务或外部 OAuth/MCP 账户。原生视图检查仅在自身进程的屏幕外窗口中，通过真实产品视图、合成控件事件和像素断言核对状态；不替代完整外部 GUI 验收。环境诊断只查询自己的 Keychain namespace 是否可达，不读取凭据值、不写入条目；真实凭据存取验收需另列证据。fixture 回环测试不等于真实外部服务联调；ad-hoc 签名不等于 Developer ID 签名、公证或分发许可。完整 App→VM→Agent→模型/工具→审阅导出→Stop 验收仍需单列真机证据。

## 本地复现

在受支持的 Apple Silicon Mac 上：

```sh
git ls-files -z '*.swift' | xargs -0 swift format lint --strict --parallel
uvx ruff@0.17.1 check . && uvx ruff@0.17.1 format --check .
python3 -m compileall -q scripts Tests Tools
python3 -m unittest discover -s Tests/PackagingTests -v
python3 -m unittest discover -s Tests/Fixtures/host_services -v
python3 -m unittest discover -s Tests/CoverageTests -v
for suite in AgentRuntimeTests GuestFixtureTests AgentProtocolProbeTests VMChecks; do
  python3 -m unittest discover -s "Tests/$suite" -v
done
go test -C Tests/GuestFixtureTests -race -count=1 -v ./...
swift build
swift run --skip-build ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/StructuredModelCLITests -v
python3 -m unittest discover -s Tests/MCPIntegrationTests -v
python3 scripts/build-app.py --configuration release --sign-identity -
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
python3 scripts/swift-coverage.py
```

macOS 本地测试先设置 `export TMPDIR="$(cd "$TMPDIR" && pwd -P)"`，避免系统 `/var` 别名被防符号链接检查拒绝。覆盖率 runner 自动创建并使用物理临时目录；ACL fixture 会清除自己设置的 deny-delete ACL，保证退出清理。

工作流语法由 actionlint 1.7.12 检查。以对应 PR 的确切提交及 Actions run 为准：本地通过、尚未运行、排队、取消与远端成功是不同状态。

覆盖率统计、徽章发布和数据范围见 [覆盖率说明](coverage.md)。
