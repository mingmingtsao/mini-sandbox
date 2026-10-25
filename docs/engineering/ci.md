# 持续集成

`.github/workflows/ci.yml` 在 Pull Request（包括 Draft）及 `main` 的 push 上执行，也提供手动触发入口。首次工作流合入默认分支前，手动入口可能尚不可用；历史 PR 不会仅因新增工作流而自动补跑，需更新到包含该工作流的分支并触发新的 PR 事件。

## 检查范围

| 检查 | Runner | 内容 |
|---|---|---|
| Workflow and Python syntax | GitHub 托管 Ubuntu 24.04 | 固定版本 actionlint；`scripts`、`Tests` 的 Python 语法 |
| Python safety and host fixtures | GitHub 托管 Ubuntu 24.04 / Python 3.13 | 打包路径与所有权回归；仅回环监听、使用假资源的 OAuth/MCP fixtures |
| macOS build, contracts and packaging | GitHub 托管 macOS 15 / Apple Silicon | 全部 Debug targets；`ContractChecks`；公共 API 编译边界；Release App 构建、ad-hoc 签名及严格签名验证 |
| CI | GitHub 托管 Ubuntu 24.04 | 汇总以上结果；任何失败、跳过或取消都不能被当作通过 |

`ContractChecks` 是当前契约测试入口；没有使用不适用的 `swift test`。当前默认分支没有 Go module，因此不添加零测试的 Go job。后续模块合入时应显式补充其测试入口，不能把本工作流的绿色结果外推到尚未接入的测试套件。

## 权限与运行边界

- 只使用 GitHub 托管临时 runner，不使用自托管 Mac。
- 工作流令牌仅允许 `contents: read`；汇总 job 无仓库权限。
- checkout 不持久化凭据，Actions 固定到完整 commit SHA；actionlint 下载校验固定 SHA-256。
- 不引用仓库 secrets、不配置产品凭据，不使用 `pull_request_target` 或特权 `workflow_run` 链。
- 不发布 Release、不上传分发包、不执行自动合并，也不改分支保护。维护者可在确认运行稳定后将汇总检查 `CI` 设为必需检查。
- 同一 PR 的旧运行会在新提交到来时取消；每个 job 有超时。工具链具体版本记录在运行日志，runner 镜像仍会由 GitHub 更新。

## 不代表通过的项目

本 CI 不启动 VM，不运行真实 Agent、真实模型服务、外部 OAuth/MCP 账户、GUI 交互或 Keychain CRUD。fixture 回环测试不等于真实外部服务联调；ad-hoc 签名不等于 Developer ID 签名、公证或分发许可。完整 App→VM→Agent→模型/工具→审阅导出→Stop 验收仍需单列真机证据。

## 本地复现

在受支持的 Apple Silicon Mac 上：

```sh
python3 -m compileall -q scripts Tests
python3 -m unittest discover -s Tests/PackagingTests -v
python3 -m unittest discover -s Tests/Fixtures/host_services -v
swift build
swift run --skip-build ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 scripts/build-app.py --configuration release --sign-identity -
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
```

工作流语法由 actionlint 1.7.12 检查。以对应 PR 的确切提交及 Actions run 为准：本地通过、尚未运行、排队、取消与远端成功是不同状态。
