# mini-sandbox

macOS Agent 安全工作台。当前代码提供原生环境检查、可打包的应用入口，以及运行授权、待审批动作和安全事件的公共数据模型。

## 构建与运行

构建环境需要 Apple Silicon Mac、Swift 6 工具链和 macOS SDK。包的部署目标暂设为 macOS 14；当前实际验证平台为 macOS 26.6.2，最低支持版本仍需实机验证。

```sh
swift build
swift run ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/PackagingTests -v
swift run MiniSandbox --diagnostics-json
python3 scripts/build-app.py
open dist/MiniSandbox.app
```

`ContractChecks` 为不依赖 XCTest 的可执行测试入口，适用于仅安装 Command Line Tools 的环境；任一断言失败返回非零退出码。`swift test` 不是本仓库当前的测试入口。

打包脚本拒绝链接输出目录及未标记的旧 App；已标记旧产物在成功替换时保留到 `dist/.MiniSandbox-backup-*`，不会递归删除。旧版未标记产物请先自行移开，失败暂存目录也保留供检查。

本地打包默认使用 ad-hoc 签名，不代表 Developer ID 分发签名或已公证。可通过 `--sign-identity` 指定已安装身份；公证与分发验收尚未接入。

## 模块

- `SandboxContracts`：不可变运行快照、精确资源范围、拒绝优先的纯范围检查和动作参数绑定。
- `SandboxHost`：真实宿主能力检查及只允许宿主模块构造的事件模型；不创建 VM、不读取凭据值。
- `MiniSandboxApp`：SwiftUI 窗口展示检查结果；同一打包二进制提供 JSON 诊断入口。
- `Tests/SandboxContractsTests`：契约断言与拒绝路径测试。

## 当前边界

环境检查通过不等于可运行 Agent。Linux 镜像、VM/vsock、真实模型代理、运行时撤权和原子审批消费、文件导入导出、MCP 连接尚未实现。

公共契约以 [候选实施规格 #3](https://github.com/mingmingtsao/mini-sandbox/pull/3) 为依据，在该规格确认前作为候选接口；不启用旧设计中的原始密钥内存注入或覆盖宿主项目路径。

完整设计见 [产品资料](docs/prd/README.md)，公共契约边界见 [契约说明](docs/engineering/contracts.md)。
