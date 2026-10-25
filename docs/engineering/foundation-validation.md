# 基础应用验证

本页记录基础应用阶段的验证结果，范围为 App 构建、宿主环境探针与公共契约。

| 检查 | 结果 | 证据与边界 |
|---|---|---|
| 公共契约 | PASS | `swift run ContractChecks`：7/7；构造/解码、拒绝与时间重叠、请求绑定、重复连接 |
| 拒绝优先回归有效性 | PASS | 临时取消 deny 检查后对应测试 FAIL；恢复后 7/7 PASS |
| 事件 API 边界 | PASS | `python3 -m unittest discover -s Tests/APITests -v`：4/4；公共构造/解码被编译器拒绝，宿主内部来源过滤通过 |
| 打包路径保护 | PASS | `python3 -m unittest discover -s Tests/PackagingTests -v`：7/7；真实临时文件系统，Swift/codesign 为 fixture；拒绝链接及未标记产物、重复构建保留旧包、签名失败不破坏旧包 |
| Debug / Release 构建 | PASS | Swift Package 可构建原生 SwiftUI App，不依赖 IDE |
| 本地 App 包 | PASS | `python3 scripts/build-app.py`，ad-hoc 签名及 `codesign --verify --strict` 成功 |
| 打包二进制诊断 | PASS | `dist/MiniSandbox.app/Contents/MacOS/MiniSandbox --diagnostics-json` 输出真实系统/资源/虚拟化及 Keychain 查询结果 |
| App 窗口启动 | PASS | `open dist/MiniSandbox.app` 后存在对应 bundle 的原生窗口；窗口检查与截图确认显示环境检查而非模拟 VM 运行 |
| GUI 自动化交互 | BLOCKED | 该轮本机桌面自动化驱动启动失败 |
| 正式签名、公证、异机安装 | BLOCKED | 无 Developer ID 身份；本次为本机 ad-hoc 包 |

实测环境：Apple Silicon、macOS 26.6.2、Swift 6.3.3、Command Line Tools。Swift 包部署目标为 macOS 14。

当前 CLT 不提供 XCTest，所有契约断言通过 `ContractChecks` 可执行入口运行；退出码非零即失败。Keychain 探针仅在应用自己的服务命名空间执行不返回数据的查询，不证明凭据写入、解锁或刷新可用。
