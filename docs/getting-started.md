# 运行指南

本文从零开始说明如何构建、运行和测试 mini-sandbox。系统设计见[架构设计](architecture.md)。

## 目录

1. [环境要求](#1-环境要求)
2. [获取代码](#2-获取代码)
3. [五分钟快速验证](#3-五分钟快速验证)
4. [构建](#4-构建)
5. [运行桌面应用](#5-运行桌面应用)
6. [命令行诊断](#6-命令行诊断)
7. [准备 VM 运行时（进阶）](#7-准备-vm-运行时进阶)
8. [本地 fixture 模式（开发者）](#8-本地-fixture-模式开发者)
9. [运行测试](#9-运行测试)
10. [常见问题](#10-常见问题)
11. [数据位置与清理](#11-数据位置与清理)

---

## 1. 环境要求

| 项 | 要求 | 说明 |
|---|---|---|
| 硬件 | Apple Silicon Mac（arm64） | 需要 Virtualization.framework；不支持 Intel Mac |
| 系统 | macOS 14 或更高 | CI 与主线验证使用 macOS 26.6 |
| Swift 工具链 | Swift 6.x（推荐 Xcode 26.6 / Swift 6.3） | 仅安装 Command Line Tools 即可构建；**不需要** `xcodebuild` |
| Python | Python 3.9+（推荐 3.13） | 构建脚本、测试驱动；只用标准库 |
| Go（可选） | **1.26.5**（精确版本） | 仅构建诊断 guest 与运行 Go 协议测试时需要 |
| 磁盘 | 构建约 2 GB；VM 运行时额外约 1 GB | 运行时镜像与 CLI 磁盘放在仓库外 |
| 网络 | 仅下载源码与第三方运行时输入时需要 | 构建 App 与运行离线测试不需要网络 |

检查环境：

```sh
uname -m            # 应输出 arm64
sw_vers
swift --version
python3 --version
go version          # 可选
```

## 2. 获取代码

```sh
git clone https://github.com/mingmingtsao/mini-sandbox.git
cd mini-sandbox
```

> **macOS 临时目录提示**：多项检查拒绝穿越符号链接的路径，而 macOS 的 `$TMPDIR` 位于 `/var` 别名下。在运行任何测试前，先在当前终端执行：
>
> ```sh
> export TMPDIR="$(cd "$TMPDIR" && pwd -P)"
> ```

## 3. 五分钟快速验证

```sh
swift build                                       # 构建全部 target（Debug）
swift run --skip-build MiniSandbox --diagnostics-json   # 输出本机环境报告
swift run --skip-build ContractChecks             # 契约检查，应显示 7/7 passed
```

`--diagnostics-json` 的输出示例：

```json
{
  "architecture" : "arm64",
  "availableDiskBytes" : 165126201344,
  "checkedAt" : "2026-10-25T21:43:03Z",
  "keychainQueryAvailable" : true,
  "keychainStatus" : -25300,
  "logicalCPUCount" : 10,
  "operatingSystem" : "Version 26.6.2 (Build 25G83)",
  "physicalMemoryBytes" : 34359738368,
  "virtualizationSupported" : true
}
```

`virtualizationSupported` 必须为 `true`。`keychainStatus` 为 `-25300`（`errSecItemNotFound`）表示 Keychain 可查询、只是诊断条目不存在，属于正常情况。

## 4. 构建

| 目标 | 命令 | 产物 |
|---|---|---|
| 全部 target（Debug） | `swift build` | `.build/debug/` |
| 仅 App 可执行文件（Release） | `swift build -c release --product MiniSandbox` | `.build/release/MiniSandbox` |
| 打包签名的 `.app` | `python3 scripts/build-app.py --configuration release --sign-identity -` | `dist/MiniSandbox.app` |
| 诊断 VM 程序 | `python3 scripts/build-vm-probe.py --configuration debug` | `dist/VMProbe/VMProbe` |

`build-app.py` 的行为：

- 编译 Release 产品，生成 `Info.plist`（bundle id `dev.mini-sandbox.app`），用 `scripts/app.entitlements`（仅含 `com.apple.security.virtualization`）签名并严格校验；
- `--sign-identity -` 为本地 ad-hoc 签名；也可传入已安装的签名身份名称；
- **从不递归删除**：已存在的 `dist/MiniSandbox.app` 会被移到 `dist/.MiniSandbox-backup-*/`；不是本脚本生成的同名目录会被拒绝覆盖；
- 输出 JSON，包含可执行文件 SHA-256、签名方式和 `"notarized": false`。

验证签名与权利：

```sh
codesign --verify --strict --verbose=2 dist/MiniSandbox.app
codesign -d --entitlements - --xml dist/MiniSandbox.app
```

## 5. 运行桌面应用

### 5.1 启动

```sh
python3 scripts/build-app.py --configuration release --sign-identity -
open dist/MiniSandbox.app
```

开发时也可以直接运行未打包的可执行文件（无需签名即可查看界面，但启动 VM 需要带权利签名的 App）：

```sh
swift run MiniSandbox
```

> ad-hoc 签名的 App 只适合本机运行。复制到其他 Mac 时可能被 Gatekeeper 拦截；请在目标机器上自行构建，**不要**为此全局关闭系统安全功能。

### 5.2 界面导览

窗口包含三个标签页：

| 标签页 | 用途 |
|---|---|
| **Tasks** | 主流程：选择项目、运行时镜像与 CLI 磁盘，配置模型/MCP 连接，输入任务，确认权限，审批请求，查看输出，Stop，审阅结果并导出 |
| **Workbench** | 授权工作台：当前运行的授权快照、待审批动作（原生审批面板）、宿主执行活动与 guest 诊断分区、可信拒绝计数、Stop |
| **Environment** | 本机环境检查：系统、架构、虚拟化能力、Keychain 可达性、CPU/内存/磁盘 |

### 5.3 配置模型连接

在 Tasks 页底部展开 **Model connection**（Workbench 页也有同样的面板）：

1. 当前仅支持 **DeepSeek flash（Anthropic 协议）**；
2. 在 “Enter replacement API key” 安全输入框中填入 API key，点击 **Save to Keychain**（service `dev.mini-sandbox.model`）；
3. 点击 **Check stored credential** 确认已保存（不会向服务商发送请求）；
4. **Delete stored credential** 删除已保存的凭据。

注意：输入框不会预填已保存的值；配置变更只对**下一次运行**生效，变更时会先终止绑定旧连接的运行。每次启动 App 后连接处于不可用状态，需要重新 Check 或 Save。

### 5.4 配置本机 MCP（可选）

在 Tasks 页底部展开 **MCP connection**，填写 “127.0.0.1 port” 与 “Temporary host bearer”，点击 **Configure local connection**；**Disconnect** 断开并终止绑定该连接的运行。

MCP 设置只接受 `127.0.0.1` 上的端口号和一个仅保存在内存中的 bearer 令牌，对应固定的本机仓库 profile（仓库 A 可读，勾选后可请求写；仓库 B 永不授予）。它不会启动命令，也不支持远端地址。

### 5.5 创建并运行任务

1. **Choose project…**：选择项目目录。导入时自动排除 `.git`、`.ssh`、`.env*`、私钥类文件；上限 16 MiB / 1,000 项；
2. **Choose runtime…**：选择业务运行时镜像目录（见 [§7.4](#74-构建业务运行时镜像)）；
3. **Choose CLI disk…**：选择固定版本 Claude Code 只读磁盘（见 [§7.5](#75-准备固定版本-cli-磁盘)）；
4. **Agent** 选择 Claude Code 2.1.309（Codex / DSH 显示为未实现）；
5. 在 **Task** 中输入任务描述（≤ 8,192 字节）；如需 MCP，勾选 “Use the configured local repository MCP”，可再勾选允许请求写入；
6. 阅读限制说明并勾选 “I authorize this task in the isolated project copy…”；
7. 点击 **Start task**。

运行期间，每一次模型请求和每一次工具权限（读文件、改文件、执行命令、MCP 调用）都会出现内嵌审批，显示完整内容：

- **Approve this action** 只批准这一次，必须显式点击；
- **Deny** 或超时视为拒绝；
- **Stop** 始终可见，点击后立即撤销本次运行的全部授权并停止 VM。

Workbench 页提供同一授权账本的视图：点击 **Review** 打开原生审批面板（**Approve once** / **Deny** / **Cancel / deny**，回车默认为拒绝，Esc 为取消并拒绝），以及 **Stop and revoke**。

> **当前构建的出口状态**：正式构建中 `BusinessModelActivation.credentialEgressEnabled` 固定为 `false`，Tasks 页会显示 “Business model egress is disabled in this build”，**Start task 按钮不可用**。这是有意的安全门禁：真实凭据出口需要独立人工复核后才能启用（见 [business-egress-review.md](engineering/business-egress-review.md)）。要体验完整流程，请使用 [§8 本地 fixture 模式](#8-本地-fixture-模式开发者)。

### 5.6 审阅与导出

Agent 结束后，App 等待：guest 完成记录 + 完整文件回传（哈希一致）+ VM 真实停止并删除私有磁盘。三者齐备后：

1. 运行授权被停止；
2. 显示增删改清单与文本预览（二进制、超大文件会注明无法预览）；
3. 点击 **Export reviewed result…** 并选择一个**新目录**，结果原子写入；原项目不会被修改；
4. 不需要结果时点击 **Close review…** 放弃本次审阅。

有未导出结果时退出 App 会弹出确认。

### 5.7 退出

关闭窗口或 Cmd+Q 会走同一个终止握手：先撤销所有授权、等待 VM 和工作区清理完成，再退出。

### 5.8 Keychain 自检（可选）

```sh
dist/MiniSandbox.app/Contents/MacOS/MiniSandbox --keychain-canary-selfcheck
```

使用随机生成的独立条目验证 Keychain 增删改查，只清理自己创建的条目，不读写正式凭据。退出码：`0` PASS、`1` FAIL、`2` BLOCKED。需要通过打包后的 App 运行。

## 6. 命令行诊断

| 命令 | 作用 |
|---|---|
| `MiniSandbox --diagnostics-json` | 输出环境报告 JSON；不启动界面、不读取凭据 |
| `MiniSandbox --keychain-canary-selfcheck` | Keychain 自检（见 §5.8） |
| `dist/VMProbe/VMProbe --capabilities` | 报告虚拟化支持、CPU/内存上限与可执行文件权利；不启动 VM |
| `dist/VMProbe/VMProbe --run --bundle <bundle> --evidence-dir <新目录>` | 启动诊断 guest，完成 ping/pong 与三类宿主拒绝后真实停止 |

`VMProbe` 退出码：`0` 全部检查通过；`1` 准备/检查/停止失败；`2` 不支持虚拟化或缺少权利；`64` 参数错误。

## 7. 准备 VM 运行时（进阶）

任务运行需要两个**不在仓库中**的输入：业务运行时镜像目录和固定版本 CLI 只读磁盘。全部构建步骤离线进行（下载步骤除外），不会在 macOS 上执行任何 Linux 二进制。

### 7.1 目录约定与权限要求

构建工具对路径有严格要求，不满足时会直接拒绝：

- 使用**绝对路径**，不含 `.`、`..`，不穿越符号链接；
- 工作目录放在**仓库外**，叶子目录权限 `0700`，祖先目录属于当前用户或 root 且不可被组/其他用户写入；
- 输出目录必须**尚不存在**；失败时保留部分产物供检查，不要复用；
- 运行期间不要修改输入文件（VZ 会重新打开它们）。

```sh
export ART="$HOME/mini-sandbox-artifacts"
mkdir -m 700 "$ART" "$ART/downloads" "$ART/sources" "$ART/vendor-src" "$ART/vendor"
```

### 7.2 下载锁定的软件包

```sh
# 44 个 Alpine aarch64 APK，逐个校验字节数与 SHA-256
python3 Tools/AgentRuntime/fetch.py "$ART/downloads"

# 业务配置额外需要 Bash（business-dependencies.lock.json）
curl -fL -o "$ART/downloads/bash-5.3.9-r1.apk" \
  https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/bash-5.3.9-r1.apk
shasum -a 256 "$ART/downloads/bash-5.3.9-r1.apk"
# 应为 95f4f976bdf2f4ca18ff41c32916eb6d7b12a0dae12504d55d04427460d6542f
```

### 7.3 构建诊断 guest bundle

业务镜像以诊断 bundle 的内核为基础。需要 Go 1.26.5。

```sh
cd "$ART/sources"
curl -fLO https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-minirootfs-3.24.3-aarch64.tar.gz
curl -fLO https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/alpine-netboot-3.24.3-aarch64.tar.gz
python3 -m pip download --no-deps --only-binary=:all: PySquashfsImage==0.9.0 -d "$ART/sources"
shasum -a 256 *.tar.gz *.whl
cd -
```

期望的 SHA-256 见 [offline-diagnostic-guest.md](engineering/offline-diagnostic-guest.md#inputs-and-reproducibility)；构建器会再次校验。

```sh
mkdir -m 700 "$ART/scratch"
python3 Tools/GuestFixture/build.py \
  --source-dir "$ART/sources" \
  --wheel "$ART/sources/PySquashfsImage-0.9.0-py2.py3-none-any.whl" \
  --scratch "$ART/scratch" \
  --output "$ART/diagnostic-bundle"
python3 Tools/GuestFixture/inspect_bundle.py "$ART/diagnostic-bundle" "$ART/diagnostic-bundle"
```

可选：用 `VMProbe` 验证本机能真正启动 VM：

```sh
python3 scripts/build-vm-probe.py --configuration debug
dist/VMProbe/VMProbe --capabilities
dist/VMProbe/VMProbe --run --bundle "$ART/diagnostic-bundle" --evidence-dir "$ART/vmprobe-evidence-1"
```

### 7.4 构建业务运行时镜像

```sh
python3 Tools/AgentRuntime/build.py "$ART" "$ART/diagnostic-bundle" "$ART/business-image" \
  --claude-business-runtime-v1
```

第一个参数是包含 `downloads/` 的目录。输出目录包含 `Image`、`runtime.cpio.gz`、`runtime.json`（完整清单）和 `business.json`（身份文件）。在 App 中 “Select runtime” 时选择 `$ART/business-image`。

### 7.5 准备固定版本 CLI 磁盘

Claude Code 二进制受其自身许可约束，**不随本仓库分发**，请自行从上游获取固定版本：

```sh
curl -fL -o "$ART/vendor-src/claude" \
  https://downloads.claude.ai/claude-code-releases/2.1.309/linux-arm64-musl/claude
chmod 0400 "$ART/vendor-src/claude"
python3 Tools/AgentRuntime/vendor_data.py "$ART/vendor-src/claude" "$ART/vendor/claude.raw"
```

工具校验输入为 285,493,120 字节、SHA-256 `028ad6b4…b332`，并输出补零到扇区边界的只读磁盘（SHA-256 `c4e512ea…bf43`）。在 App 中 “Select CLI disk” 时选择 `$ART/vendor/claude.raw`。

完整版本、哈希与许可说明见 [runtime-distribution.md](engineering/runtime-distribution.md)。

## 8. 本地 fixture 模式（开发者）

用于在**不使用真实凭据**的情况下走通 App → VM → CLI → 审批 → 审阅导出的完整界面流程。模型上游替换为本机回环的脚本化 provider；所有审批仍需手动点击。该模式只存在于带 `SANDBOX_TEST_FIXTURES` 编译条件的构建中，正式 Release 不包含相关代码。

前提：已完成 [§7](#7-准备-vm-运行时进阶) 的运行时镜像与 CLI 磁盘。

```sh
# 1. 构建 fixture 版本（独立构建目录，不影响正常构建）
swift build --build-path .build/fixtures -Xswiftc -DSANDBOX_TEST_FIXTURES --product MiniSandbox
mkdir -m 700 "$ART/fixture-app"
cp .build/fixtures/debug/MiniSandbox "$ART/fixture-app/MiniSandbox"
codesign --force --sign - --entitlements scripts/app.entitlements "$ART/fixture-app/MiniSandbox"

# 2. 在另一个终端启动脚本化模型 provider，记下输出中的 port
python3 Tools/AgentRuntime/business_fixture.py --serve "$ART/fixture-model-1"
#   {"port": 5xxxx, "scope": "local scripted provider only; App approvals remain manual"}

# 3. 启动 App（root 必须是尚不存在的新目录）
"$ART/fixture-app/MiniSandbox" \
  --local-business-fixture-port <上一步的 port> \
  --local-business-fixture-root "$ART/fixture-run-1"
```

界面会显示醒目的 `LOCAL FIXTURE` 标记。脚本化 provider 按固定脚本驱动 CLI：读取 `logic.py` → 运行 `python3 -B test_logic.py` 观察失败 → 把 `return a - b` 改为 `return a + b` → 重新运行测试。因此请准备一个只含这两个文件的示例项目，并在 Tasks 中选择它：

```sh
mkdir -m 700 "$ART/fixture-project"
cp Tools/AgentRuntime/fixture/logic.py Tools/AgentRuntime/fixture/test_logic.py "$ART/fixture-project/"
```

每个模型请求与工具权限仍需在界面中逐一点击 Approve once；完成后审阅差异并导出到新目录。

如需同时测试 MCP，把第 2 步换成 `python3 Tools/AgentRuntime/business_mcp_fixture.py --serve <新目录> mcp-read`（或 `mcp-write`）。它同时输出 `modelPort` 与 `mcpPort`：启动 App 时用 `modelPort` 作为 `--local-business-fixture-port`，并追加 `--local-mcp-fixture-port <mcpPort>`，然后在 Tasks 中勾选使用 MCP。

详细说明见 [business-app-task.md](engineering/business-app-task.md) 与 [app-fixture-launch.md](engineering/app-fixture-launch.md)。

## 9. 运行测试

项目不使用 `swift test`。每个 Swift 检查都是独立可执行 target，打印 `PASS/FAIL` 与汇总，并以退出码表示结果；Python 测试按目录分别发现。

### 9.1 与 CI 一致的完整离线回归

```sh
export TMPDIR="$(cd "$TMPDIR" && pwd -P)"

# Python 语法与单元测试
python3 -m compileall -q scripts Tests Tools
for suite in PackagingTests Fixtures/host_services CoverageTests \
             AgentRuntimeTests GuestFixtureTests AgentProtocolProbeTests VMChecks; do
  python3 -m unittest discover -s "Tests/$suite" -v
done

# Go guest 协议（需要 Go 1.26.5）
go test -C Tests/GuestFixtureTests -race -count=1 -v ./...

# Swift 构建、契约、公共 API 边界、CLI 与回环驱动
swift build
swift run --skip-build ContractChecks
python3 -m unittest discover -s Tests/APITests -v
python3 -m unittest discover -s Tests/StructuredModelCLITests -v
python3 -m unittest discover -s Tests/MCPIntegrationTests -v

# 打包与签名
python3 scripts/build-app.py --configuration release --sign-identity -
codesign --verify --strict --verbose=2 dist/MiniSandbox.app

# 全部 Swift 检查 + 覆盖率（独立插桩构建，耗时较长）
python3 scripts/swift-coverage.py
```

### 9.2 按模块运行 Swift 检查

先 `swift build`，然后：

| 模块 | 命令 |
|---|---|
| 契约 | `swift run --skip-build ContractChecks` |
| 授权与生命周期 | `swift run --skip-build AuthorizationChecks`；`swift run --skip-build SharedAuthorityChecks` |
| 模型网关 | `swift run --skip-build ModelTransportChecks --offline`；`HostIntegrationChecks`；`StructuredModelChecks`；`BusinessIngressChecks` |
| MCP 网关 | `python3 Tests/MCPIntegrationTests/test_loopback.py --binary .build/debug/MCPGatewayChecks --scope default` |
| 执行边界 | `swift run --skip-build ExecutionBoundaryChecks`（另有 `--final-effect-clock`、`--native-response`、`--native-repairs` 选择器）；回环：`python3 Tests/ExecutionBoundaryChecks/loopback.py --binary .build/debug/ExecutionBoundaryChecks` |
| VM 协议 | `swift run --skip-build VMChecks`；`swift run --skip-build RuntimeReceiveChecks` |
| 工作区 | `swift run --skip-build WorkspaceChecks`；`swift run --skip-build WorkspaceTransferChecks` |
| 工作台 | `swift run --skip-build WorkbenchChecks`（可用 `--composition-close-only` 等选择器）；`python3 Tests/MCPIntegrationTests/composition_close.py --binary .build/debug/WorkbenchChecks` |

注意：`MCPGatewayChecks` 需要回环 fixture，请通过上表中的 Python 驱动运行；直接运行完整套件会因缺少 fixture 而失败。`ModelTransportChecks` 不带 `--offline` 时会包含隔离 Keychain 增删改用例。

### 9.3 覆盖率

```sh
python3 scripts/swift-coverage.py            # 生成 coverage-report/
python3 scripts/swift-coverage.py --skip-build   # 复用已有插桩构建
open coverage-report/README.md
```

统计口径见 [coverage.md](engineering/coverage.md)。

### 9.4 真实 VM 验证（可选）

CI 不启动 VM。需要真机证据时，参考：

| 验证 | 文档 |
|---|---|
| 诊断 VM 正常运行与启动中取消 | [headless-vm.md](engineering/headless-vm.md#opt-in-real-lifecycle-regression) |
| 运行时命令执行与取消 | [agent-runtime.md](engineering/agent-runtime.md#reproduction) |
| 工作区传输与导出 | [workspace-transfer.md](engineering/workspace-transfer.md#reproduce) |
| 业务 VM 连接边界矩阵 | [business-vm-evidence.md](engineering/business-vm-evidence.md) |
| 真实 CLI 工具循环（回环模型） | [business-cli-loopback-evidence.md](engineering/business-cli-loopback-evidence.md) |
| 真实 CLI 调用本机 MCP | [business-cli-mcp-evidence.md](engineering/business-cli-mcp-evidence.md) |

这些探针通过 `python3 Tools/WorkspaceTransfer/build_host.py <mode> <新目录>` 构建，再用 `scripts/vm-probe.entitlements` 做 ad-hoc 签名。

## 10. 常见问题

| 现象 | 原因与处理 |
|---|---|
| 测试报 symlink / unsafe ancestor 错误 | `$TMPDIR` 位于 `/var` 别名下。执行 `export TMPDIR="$(cd "$TMPDIR" && pwd -P)"` |
| `xcode-select: error: tool 'xcodebuild' requires Xcode` | 只影响 `xcodebuild -version` 这类命令；构建只需要 `swift`，可忽略 |
| `build-app.py` 报 `Unmarked output preserved; move it aside` | `dist/MiniSandbox.app` 不是本脚本生成的。手动移走该目录后重试（脚本从不删除未知目录） |
| `build-app.py` 报 `Unsafe output directory` | 仓库目录或 `dist/` 可被组/其他用户写入，或属于其他用户。修正权限（如 `chmod go-w dist`） |
| Environment 页显示虚拟化不可用 / VMProbe 退出码 2 | 不是 Apple Silicon、在不支持嵌套虚拟化的 VM 中运行，或可执行文件缺少 `com.apple.security.virtualization` 权利。请使用 `build-app.py` / `build-vm-probe.py` 构建的产物 |
| Tasks 页 Start 按钮灰色 | 正式构建出口门禁关闭（见 §5.5）；或尚未选择项目/运行时/CLI 磁盘、未勾选确认、未配置模型连接 |
| 窗口显示 “App composition unavailable; authority disabled” | 无法创建审计目录或文件。检查 `~/Library/Application Support/MiniSandbox/Audit` 是否可写、磁盘是否已满 |
| `fetch.py` 报 `private download directory required` | 下载目录必须属于当前用户且不可被组/其他用户写入：`chmod 700 "$ART/downloads"` |
| `vendor_data.py` 报 `immutable exact regular input` | 输入必须属于当前用户、只读（`chmod 0400`）、单链接、大小精确；输出父目录必须为 `0700` |
| 构建器报输出已存在 | 所有构建输出目录必须是新的；换一个目录名，保留旧目录供检查 |
| Go 构建失败或版本不符 | guest 探针要求精确的 Go 1.26.5，且禁用模块下载 |
| ad-hoc 签名的 App 在另一台 Mac 上无法打开 | 未做 Developer ID 签名与公证。在目标机器上从源码构建 |

## 11. 数据位置与清理

| 数据 | 位置 | 清理方式 |
|---|---|---|
| 审计日志 | `~/Library/Application Support/MiniSandbox/Audit/*.jsonl` | 每次启动新建一个文件，无自动轮转；可手动归档或删除 |
| 任务副本与结果 | `~/Library/Application Support/MiniSandbox/Tasks/<UUID>/` | App 退出后无法重新打开旧任务；导出后可手动删除 |
| 模型凭据 | Keychain：`dev.mini-sandbox.model` / `deepseek` | App 中点击 Delete，或在“钥匙串访问”中删除 |
| 构建产物 | `.build/`、`dist/`、`coverage-report/` | 可直接删除；`dist/.MiniSandbox-backup-*` 为历史 App 备份 |
| 运行时与 CLI 磁盘 | 你选择的 `$ART` 目录 | 自行管理；注意第三方许可，不要提交到 Git |
