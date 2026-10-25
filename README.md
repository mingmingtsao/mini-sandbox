# Swift CI line coverage

**78.7%** — 8,713 / 11,068 executable lines.

Source commit: [`00ed93864979`](https://github.com/mingmingtsao/mini-sandbox/commit/00ed93864979c773dee608c22e17f90a586c1bca).

Scope: all Swift files under `Sources/`, including files with zero hits. Excludes `Tests/`, `Tools/`, Python, Go and generated code.

Executed checks: `ContractChecks`, `AuthorizationChecks`, `ModelTransportChecks --offline`, `HostIntegrationChecks`, `StructuredModelChecks`, `WorkbenchChecks`, `SharedAuthorityChecks`, `WorkspaceChecks`, `WorkspaceTransferChecks`, `VMChecks`, `RuntimeReceiveChecks`, `PresentationChecks (validated)`, `BusinessIngressChecks`, `MCPGatewayChecks (Claude loopback)`, `ExecutionBoundaryChecks (reflection loopback)`, `ExecutionBoundaryChecks`, `ExecutionBoundaryChecks --final-effect-clock`, `ExecutionBoundaryChecks --native-repairs`, `ExecutionBoundaryChecks --native-response`, `MCPGatewayChecks --transport-unit`, `MCPGatewayChecks (loopback)`, `MCPGatewayChecks (independent loopback)`, `ExecutionBoundaryChecks --mcp (loopback)`, `ExecutionBoundaryChecks --mcp-transaction (loopback)`, `WorkbenchChecks --composition-mcp (loopback)`, `MiniSandbox --diagnostics-json (validated)`. Compiling another target does not count as exercising it.

[CI run](https://github.com/mingmingtsao/mini-sandbox/actions/runs/40240391549)

| Source | Covered / executable lines | Coverage |
|---|---:|---:|
| [Sources/MiniSandboxApp/MiniSandboxApp.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/MiniSandboxApp/MiniSandboxApp.swift) | 151 / 257 | 58.8% |
| [Sources/SandboxContracts/Contracts.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxContracts/Contracts.swift) | 101 / 103 | 98.1% |
| [Sources/SandboxHost/AgentRuntimeProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/AgentRuntimeProbe.swift) | 146 / 235 | 62.1% |
| [Sources/SandboxHost/AnthropicNativeRequest.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/AnthropicNativeRequest.swift) | 149 / 149 | 100.0% |
| [Sources/SandboxHost/AnthropicStreamDecoder.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/AnthropicStreamDecoder.swift) | 113 / 114 | 99.1% |
| [Sources/SandboxHost/AuthorizationController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/AuthorizationController.swift) | 398 / 424 | 93.9% |
| [Sources/SandboxHost/BusinessDisplayOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessDisplayOutput.swift) | 75 / 75 | 100.0% |
| [Sources/SandboxHost/BusinessHTTPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessHTTPIngress.swift) | 84 / 93 | 90.3% |
| [Sources/SandboxHost/BusinessModelActivation.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessModelActivation.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/BusinessRuntimeBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessRuntimeBundle.swift) | 58 / 80 | 72.5% |
| [Sources/SandboxHost/BusinessVMConnection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessVMConnection.swift) | 0 / 192 | 0.0% |
| [Sources/SandboxHost/BusinessVMEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessVMEffects.swift) | 0 / 120 | 0.0% |
| [Sources/SandboxHost/BusinessVMSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/BusinessVMSession.swift) | 0 / 340 | 0.0% |
| [Sources/SandboxHost/ClaudeMCPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ClaudeMCPIngress.swift) | 138 / 142 | 97.2% |
| [Sources/SandboxHost/ClaudeModelAdmission.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ClaudeModelAdmission.swift) | 43 / 45 | 95.6% |
| [Sources/SandboxHost/ClaudeRequestSelectors.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ClaudeRequestSelectors.swift) | 8 / 8 | 100.0% |
| [Sources/SandboxHost/ControlledRunOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ControlledRunOutput.swift) | 150 / 158 | 94.9% |
| [Sources/SandboxHost/EnvironmentInspector.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/EnvironmentInspector.swift) | 32 / 33 | 97.0% |
| [Sources/SandboxHost/HeadlessVMProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/HeadlessVMProbe.swift) | 30 / 281 | 10.7% |
| [Sources/SandboxHost/HostCLIPermissionGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/HostCLIPermissionGateway.swift) | 78 / 183 | 42.6% |
| [Sources/SandboxHost/HostMCPGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/HostMCPGateway.swift) | 378 / 403 | 93.8% |
| [Sources/SandboxHost/HostModelGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/HostModelGateway.swift) | 447 / 483 | 92.5% |
| [Sources/SandboxHost/LocalClaudeFixtureCredential.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/LocalClaudeFixtureCredential.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/MCPCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/MCPCredentials.swift) | 21 / 21 | 100.0% |
| [Sources/SandboxHost/MCPModelHandoff.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/MCPModelHandoff.swift) | 10 / 10 | 100.0% |
| [Sources/SandboxHost/MCPProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/MCPProtocol.swift) | 62 / 62 | 100.0% |
| [Sources/SandboxHost/MCPRepositoryAdapter.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/MCPRepositoryAdapter.swift) | 15 / 15 | 100.0% |
| [Sources/SandboxHost/MCPTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/MCPTransport.swift) | 167 / 172 | 97.1% |
| [Sources/SandboxHost/ModelCredentialReflection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelCredentialReflection.swift) | 280 / 283 | 98.9% |
| [Sources/SandboxHost/ModelCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelCredentials.swift) | 77 / 148 | 52.0% |
| [Sources/SandboxHost/ModelJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelJSON.swift) | 130 / 134 | 97.0% |
| [Sources/SandboxHost/ModelStructured.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelStructured.swift) | 129 / 129 | 100.0% |
| [Sources/SandboxHost/ModelTools.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelTools.swift) | 83 / 91 | 91.2% |
| [Sources/SandboxHost/ModelTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/ModelTransport.swift) | 444 / 475 | 93.5% |
| [Sources/SandboxHost/NativeResponseChannel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/NativeResponseChannel.swift) | 103 / 120 | 85.8% |
| [Sources/SandboxHost/NativeResponseSerializer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/NativeResponseSerializer.swift) | 273 / 281 | 97.2% |
| [Sources/SandboxHost/RunClock.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/RunClock.swift) | 69 / 73 | 94.5% |
| [Sources/SandboxHost/RunLifecycle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/RunLifecycle.swift) | 286 / 350 | 81.7% |
| [Sources/SandboxHost/RuntimeJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/RuntimeJSON.swift) | 155 / 156 | 99.4% |
| [Sources/SandboxHost/SecurityEvent.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/SecurityEvent.swift) | 23 / 25 | 92.0% |
| [Sources/SandboxHost/VMDiagnosticSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/VMDiagnosticSession.swift) | 68 / 69 | 98.6% |
| [Sources/SandboxHost/VMProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/VMProtocol.swift) | 41 / 41 | 100.0% |
| [Sources/SandboxHost/VMVerifiedBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/VMVerifiedBundle.swift) | 48 / 48 | 100.0% |
| [Sources/SandboxHost/WorkspaceCopy.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/WorkspaceCopy.swift) | 841 / 865 | 97.2% |
| [Sources/SandboxHost/WorkspaceEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/WorkspaceEffects.swift) | 96 / 96 | 100.0% |
| [Sources/SandboxHost/WorkspaceGrantQuota.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/WorkspaceGrantQuota.swift) | 191 / 191 | 100.0% |
| [Sources/SandboxHost/WorkspaceRunSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/WorkspaceRunSession.swift) | 65 / 103 | 63.1% |
| [Sources/SandboxHost/WorkspaceTransfer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxHost/WorkspaceTransfer.swift) | 377 / 377 | 100.0% |
| [Sources/SandboxWorkbench/BusinessTaskController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/BusinessTaskController.swift) | 232 / 618 | 37.5% |
| [Sources/SandboxWorkbench/BusinessTaskView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/BusinessTaskView.swift) | 291 / 573 | 50.8% |
| [Sources/SandboxWorkbench/ConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/ConnectionSettings.swift) | 83 / 90 | 92.2% |
| [Sources/SandboxWorkbench/ConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/ConnectionSettingsView.swift) | 130 / 137 | 94.9% |
| [Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift) | 43 / 50 | 86.0% |
| [Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift) | 0 / 0 | n/a |
| [Sources/SandboxWorkbench/MCPConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/MCPConnectionSettings.swift) | 51 / 55 | 92.7% |
| [Sources/SandboxWorkbench/MCPConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/MCPConnectionSettingsView.swift) | 67 / 74 | 90.5% |
| [Sources/SandboxWorkbench/RunComposition.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/RunComposition.swift) | 359 / 372 | 96.5% |
| [Sources/SandboxWorkbench/WorkbenchModel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/WorkbenchModel.swift) | 353 / 374 | 94.4% |
| [Sources/SandboxWorkbench/WorkbenchView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/00ed93864979c773dee608c22e17f90a586c1bca/Sources/SandboxWorkbench/WorkbenchView.swift) | 471 / 472 | 99.8% |
