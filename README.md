# Swift CI line coverage

**91.1%** — 6,470 / 7,104 executable lines.

Source commit: [`cd4a498b0c52`](https://github.com/mingmingtsao/mini-sandbox/commit/cd4a498b0c52183154f0949809720949b6ada5bb).

Scope: all Swift files under `Sources/`, including files with zero hits. Excludes `Tests/`, `Tools/`, Python, Go and generated code.

Executed checks: `ContractChecks`, `AuthorizationChecks`, `ModelTransportChecks --offline`, `HostIntegrationChecks`, `StructuredModelChecks`, `WorkbenchChecks`, `SharedAuthorityChecks`, `WorkspaceChecks`, `WorkspaceTransferChecks`, `VMChecks`, `RuntimeReceiveChecks`, `PresentationChecks (validated)`, `ExecutionBoundaryChecks`, `ExecutionBoundaryChecks --final-effect-clock`, `ExecutionBoundaryChecks --native-repairs`, `ExecutionBoundaryChecks --native-response`, `MCPGatewayChecks --transport-unit`, `MCPGatewayChecks (loopback)`, `MCPGatewayChecks (independent loopback)`, `ExecutionBoundaryChecks --mcp (loopback)`, `ExecutionBoundaryChecks --mcp-transaction (loopback)`, `WorkbenchChecks --composition-mcp (loopback)`, `MiniSandbox --diagnostics-json (validated)`. Compiling another target does not count as exercising it.

[CI run](https://github.com/mingmingtsao/mini-sandbox/actions/runs/40211112860)

| Source | Covered / executable lines | Coverage |
|---|---:|---:|
| [Sources/MiniSandboxApp/MiniSandboxApp.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/MiniSandboxApp/MiniSandboxApp.swift) | 151 / 229 | 65.9% |
| [Sources/SandboxContracts/Contracts.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxContracts/Contracts.swift) | 101 / 103 | 98.1% |
| [Sources/SandboxHost/AgentRuntimeProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/AgentRuntimeProbe.swift) | 146 / 235 | 62.1% |
| [Sources/SandboxHost/AnthropicNativeRequest.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/AnthropicNativeRequest.swift) | 133 / 133 | 100.0% |
| [Sources/SandboxHost/AnthropicStreamDecoder.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/AnthropicStreamDecoder.swift) | 113 / 114 | 99.1% |
| [Sources/SandboxHost/AuthorizationController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/AuthorizationController.swift) | 397 / 423 | 93.9% |
| [Sources/SandboxHost/ControlledRunOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ControlledRunOutput.swift) | 136 / 136 | 100.0% |
| [Sources/SandboxHost/EnvironmentInspector.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/EnvironmentInspector.swift) | 32 / 33 | 97.0% |
| [Sources/SandboxHost/HeadlessVMProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/HeadlessVMProbe.swift) | 30 / 281 | 10.7% |
| [Sources/SandboxHost/HostMCPGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/HostMCPGateway.swift) | 290 / 291 | 99.7% |
| [Sources/SandboxHost/HostModelGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/HostModelGateway.swift) | 400 / 406 | 98.5% |
| [Sources/SandboxHost/MCPCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/MCPCredentials.swift) | 11 / 11 | 100.0% |
| [Sources/SandboxHost/MCPModelHandoff.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/MCPModelHandoff.swift) | 10 / 10 | 100.0% |
| [Sources/SandboxHost/MCPProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/MCPProtocol.swift) | 62 / 62 | 100.0% |
| [Sources/SandboxHost/MCPRepositoryAdapter.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/MCPRepositoryAdapter.swift) | 15 / 15 | 100.0% |
| [Sources/SandboxHost/MCPTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/MCPTransport.swift) | 104 / 105 | 99.0% |
| [Sources/SandboxHost/ModelCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ModelCredentials.swift) | 71 / 148 | 48.0% |
| [Sources/SandboxHost/ModelJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ModelJSON.swift) | 130 / 134 | 97.0% |
| [Sources/SandboxHost/ModelStructured.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ModelStructured.swift) | 120 / 121 | 99.2% |
| [Sources/SandboxHost/ModelTools.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ModelTools.swift) | 64 / 69 | 92.8% |
| [Sources/SandboxHost/ModelTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/ModelTransport.swift) | 404 / 411 | 98.3% |
| [Sources/SandboxHost/NativeResponseChannel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/NativeResponseChannel.swift) | 90 / 90 | 100.0% |
| [Sources/SandboxHost/NativeResponseSerializer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/NativeResponseSerializer.swift) | 260 / 266 | 97.7% |
| [Sources/SandboxHost/RunClock.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/RunClock.swift) | 69 / 73 | 94.5% |
| [Sources/SandboxHost/RunLifecycle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/RunLifecycle.swift) | 188 / 190 | 98.9% |
| [Sources/SandboxHost/RuntimeJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/RuntimeJSON.swift) | 155 / 156 | 99.4% |
| [Sources/SandboxHost/SecurityEvent.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/SecurityEvent.swift) | 23 / 25 | 92.0% |
| [Sources/SandboxHost/VMDiagnosticSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/VMDiagnosticSession.swift) | 68 / 69 | 98.6% |
| [Sources/SandboxHost/VMProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/VMProtocol.swift) | 41 / 41 | 100.0% |
| [Sources/SandboxHost/VMVerifiedBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/VMVerifiedBundle.swift) | 48 / 48 | 100.0% |
| [Sources/SandboxHost/WorkspaceCopy.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/WorkspaceCopy.swift) | 793 / 813 | 97.5% |
| [Sources/SandboxHost/WorkspaceGrantQuota.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/WorkspaceGrantQuota.swift) | 151 / 151 | 100.0% |
| [Sources/SandboxHost/WorkspaceTransfer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxHost/WorkspaceTransfer.swift) | 297 / 297 | 100.0% |
| [Sources/SandboxWorkbench/ConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/ConnectionSettings.swift) | 82 / 89 | 92.1% |
| [Sources/SandboxWorkbench/ConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/ConnectionSettingsView.swift) | 127 / 132 | 96.2% |
| [Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift) | 43 / 50 | 86.0% |
| [Sources/SandboxWorkbench/RunComposition.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/RunComposition.swift) | 298 / 305 | 97.7% |
| [Sources/SandboxWorkbench/WorkbenchModel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/WorkbenchModel.swift) | 346 / 367 | 94.3% |
| [Sources/SandboxWorkbench/WorkbenchView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/cd4a498b0c52183154f0949809720949b6ada5bb/Sources/SandboxWorkbench/WorkbenchView.swift) | 471 / 472 | 99.8% |
