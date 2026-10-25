# Swift CI 覆盖率

README 的覆盖率徽章显示最近一次成功主线 CI 的 **Swift 源码行覆盖率**。它是执行到的可执行源码行数 / 全部可执行源码行数，不是测试通过率，也不是功能或安全验收完成比例。

## 统计范围

- 分母包含 `Sources/` 下全部 Swift 文件，包括未被检查触达的文件。当前覆盖 `SandboxContracts`、`SandboxHost`、`SandboxWorkbench` 和 `MiniSandboxApp`。
- 实际执行集合为现有 CI 的 `ContractChecks`。其他检查目标只被编译，不能算作执行覆盖；因此当前百分比可能很低。
- 不包含 `Tests/`、`Tools/`、自动生成代码、Python 和 Go。公开 API 编译检查、Release 打包及签名验证也不产生这个指标的运行计数。
- 不设置最低百分比门槛；统计失败、缺失源码映射或缺少原始计数会使覆盖率 job 失败，不会用虚构数值代替。

## 生成与查看

`scripts/swift-coverage.py` 使用独立的 `.build/coverage` 插桩构建，执行 `ContractChecks`，以全新的临时目录接收 `LLVM_PROFILE_FILE` 原始计数，再用 `llvm-profdata merge` 和 [`llvm-cov export`](https://llvm.org/docs/CommandGuide/llvm-cov.html#export-command) 汇总。导出会加载全部产品源码对象，避免只报告测试程序直接链接的契约模块而抬高比例。

每次运行生成：

- `coverage-report/coverage.svg`：README 使用的百分比徽章。
- `coverage-report/coverage.json`：可执行行数、命中行数、每文件明细、提交及 CI 运行地址。
- `coverage-report/README.md`：可直接查看的逐文件报告。

报告会写入 Actions 运行摘要，并作为 `swift-coverage` artifact 保存 14 天。只有 `main` 上全部 CI 检查成功后，独立发布任务才会更新 [`ci-coverage` 分支](https://github.com/mingmingtsao/mini-sandbox/tree/ci-coverage)。发布任务会核对报告提交，并在主线已向前移动时跳过旧报告；PR 不具有覆盖率发布权限。

徽章链接到带提交记录的报告，反映最近一次成功发布的结果；GitHub 图片缓存可能使显示稍有延迟。无需额外覆盖率服务、账户或仓库 secret。

## 本地复现

在与 CI 一致的 Apple Silicon Mac / Swift 工具链上：

```sh
python3 scripts/swift-coverage.py
```

若已有同一源码版本的插桩构建，可使用 `--skip-build`。调整实际执行集合时，应同步修改脚本的 `CHECKS` 和本文范围说明；未运行的检查不能列为已覆盖。
