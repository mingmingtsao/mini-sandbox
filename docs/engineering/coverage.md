# Swift CI 覆盖率

README 的覆盖率徽章显示最近一次成功主线 CI 的 **Swift 源码行覆盖率**。它是执行到的可执行源码行数 / 全部可执行源码行数，不是测试通过率，也不是功能或安全验收完成比例。

## 统计范围

- 分母包含 `Sources/` 下全部 Swift 文件，包括未被检查触达的文件。当前覆盖 `SandboxContracts`、`SandboxHost`、`SandboxWorkbench` 和 `MiniSandboxApp`。
- 实际执行集合包含全部离线 Swift 检查入口、额外的执行边界 selector、两组 MCP 网关回环检查、两组执行边界 MCP 回环检查、工作台 MCP 关闭回环检查，以及经过 JSON 断言的 App 环境诊断。完整集合以 `scripts/swift-coverage.py` 的 `CHECKS` 为准。
- `RuntimeReceiveChecks` 将现有 guest 接收检查接入 SwiftPM；`VMChecks` 运行协议和状态检查，不创建 VM。`ModelTransportChecks --offline` 执行 32 组检查，明确排除默认套件中的隔离 Keychain CRUD 用例，原用例仍保留。工作台检查使用假凭据；环境诊断只查询自己的 Keychain namespace 是否可达，不读取凭据值、不写入条目。
- 不包含 `Tests/`、`Tools/`、自动生成代码、Python 和 Go。公开 API 编译检查、Release 打包及签名验证也不产生这个指标的运行计数。
- 不设置最低百分比门槛；统计失败、缺失源码映射或缺少原始计数会使覆盖率 job 失败，不会用虚构数值代替。

## 生成与查看

`scripts/swift-coverage.py` 使用独立的 `.build/coverage` 插桩构建，逐一执行检查，以全新的临时目录接收 `LLVM_PROFILE_FILE` 原始计数，再用 `llvm-profdata merge` 和 [`llvm-cov export`](https://llvm.org/docs/CommandGuide/llvm-cov.html#export-command) 汇总。回环 driver 显式接收该构建的 `--binary`，避免误运行普通 Debug 二进制。导出加载全部产品源码对象；任何检查失败或缺少计数均不能生成新的成功报告。

每次运行生成：

- `coverage-report/coverage.svg`：README 使用的百分比徽章。
- `coverage-report/coverage.json`：可执行行数、命中行数、每文件明细、提交及 CI 运行地址。
- `coverage-report/README.md`：可直接查看的逐文件报告。
- `coverage-report/llvm.json`：完整 LLVM 段和函数明细，用于定位未覆盖分支；保存在 artifact，不推送到徽章分支。

报告会写入 Actions 运行摘要，并作为 `swift-coverage` artifact 保存 14 天。只有 `main` 上全部 CI 检查成功后，独立发布任务才会更新 [`ci-coverage` 分支](https://github.com/mingmingtsao/mini-sandbox/tree/ci-coverage)。发布任务会核对报告提交，并在主线已向前移动时跳过旧报告；PR 不具有覆盖率发布权限。

徽章链接到带提交记录的报告，反映最近一次成功发布的结果；GitHub 图片缓存可能使显示稍有延迟。无需额外覆盖率服务、账户或仓库 secret。

## 本地复现

在与 CI 一致的 Apple Silicon Mac / Swift 工具链上：

```sh
python3 scripts/swift-coverage.py
```

若已有同一源码版本的插桩构建，可使用 `--skip-build`。调整实际执行集合时，应同步修改脚本的 `CHECKS` 和本文范围说明；未运行的检查不能列为已覆盖。

## 当前覆盖边界

本次在相同产品源码上测得：单独 `ContractChecks` 为 101 / 7,104 行（1.4%）；接入现有离线检查、guest 接收和只读诊断后为 5,847 / 7,104 行（82.3%）。这只是本次本地测量；主线徽章以成功 Actions 产物为准。

现有可离线运行的入口已全部接入。余量主要位于 SwiftUI 交互、真实 VM 启停/套接字回调、真实 Keychain 行为和系统错误分支。继续提高这些部分需要对应功能测试和实机验收，不应缩小分母或用编译结果替代执行证据。
