# Swift CI line coverage

**67.2%** — 7,438 / 11,068 executable lines.

Source commit: [`234ce0d3c5e7`](https://github.com/mingmingtsao/mini-sandbox/commit/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7).

Scope: all Swift files under `Sources/`, including files with zero hits. Excludes `Tests/`, `Tools/`, Python, Go and generated code.

Executed checks: `ContractChecks`, `AuthorizationChecks`, `ModelTransportChecks --offline`, `HostIntegrationChecks`, `StructuredModelChecks`, `WorkbenchChecks`, `SharedAuthorityChecks`, `WorkspaceChecks`, `WorkspaceTransferChecks`, `VMChecks`, `RuntimeReceiveChecks`, `PresentationChecks (validated)`, `ExecutionBoundaryChecks`, `ExecutionBoundaryChecks --final-effect-clock`, `ExecutionBoundaryChecks --native-repairs`, `ExecutionBoundaryChecks --native-response`, `MCPGatewayChecks --transport-unit`, `MCPGatewayChecks (loopback)`, `MCPGatewayChecks (independent loopback)`, `ExecutionBoundaryChecks --mcp (loopback)`, `ExecutionBoundaryChecks --mcp-transaction (loopback)`, `WorkbenchChecks --composition-mcp (loopback)`, `MiniSandbox --diagnostics-json (validated)`. Compiling another target does not count as exercising it.

[CI run](https://github.com/mingmingtsao/mini-sandbox/actions/runs/40235734163)

| Source | Covered / executable lines | Coverage |
|---|---:|---:|
| [Sources/MiniSandboxApp/MiniSandboxApp.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/MiniSandboxApp/MiniSandboxApp.swift) | 151 / 257 | 58.8% |
| [Sources/SandboxContracts/Contracts.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxContracts/Contracts.swift) | 101 / 103 | 98.1% |
| [Sources/SandboxHost/AgentRuntimeProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/AgentRuntimeProbe.swift) | 146 / 235 | 62.1% |
| [Sources/SandboxHost/AnthropicNativeRequest.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/AnthropicNativeRequest.swift) | 142 / 149 | 95.3% |
| [Sources/SandboxHost/AnthropicStreamDecoder.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/AnthropicStreamDecoder.swift) | 113 / 114 | 99.1% |
| [Sources/SandboxHost/AuthorizationController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/AuthorizationController.swift) | 398 / 424 | 93.9% |
| [Sources/SandboxHost/BusinessDisplayOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessDisplayOutput.swift) | 0 / 75 | 0.0% |
| [Sources/SandboxHost/BusinessHTTPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessHTTPIngress.swift) | 0 / 93 | 0.0% |
| [Sources/SandboxHost/BusinessModelActivation.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessModelActivation.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/BusinessRuntimeBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessRuntimeBundle.swift) | 41 / 80 | 51.2% |
| [Sources/SandboxHost/BusinessVMConnection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessVMConnection.swift) | 0 / 192 | 0.0% |
| [Sources/SandboxHost/BusinessVMEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessVMEffects.swift) | 0 / 120 | 0.0% |
| [Sources/SandboxHost/BusinessVMSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/BusinessVMSession.swift) | 0 / 340 | 0.0% |
| [Sources/SandboxHost/ClaudeMCPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ClaudeMCPIngress.swift) | 0 / 142 | 0.0% |
| [Sources/SandboxHost/ClaudeModelAdmission.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ClaudeModelAdmission.swift) | 0 / 45 | 0.0% |
| [Sources/SandboxHost/ClaudeRequestSelectors.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ClaudeRequestSelectors.swift) | 0 / 8 | 0.0% |
| [Sources/SandboxHost/ControlledRunOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ControlledRunOutput.swift) | 149 / 158 | 94.3% |
| [Sources/SandboxHost/EnvironmentInspector.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/EnvironmentInspector.swift) | 32 / 33 | 97.0% |
| [Sources/SandboxHost/HeadlessVMProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/HeadlessVMProbe.swift) | 30 / 281 | 10.7% |
| [Sources/SandboxHost/HostCLIPermissionGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/HostCLIPermissionGateway.swift) | 0 / 183 | 0.0% |
| [Sources/SandboxHost/HostMCPGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/HostMCPGateway.swift) | 316 / 403 | 78.4% |
| [Sources/SandboxHost/HostModelGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/HostModelGateway.swift) | 428 / 483 | 88.6% |
| [Sources/SandboxHost/LocalClaudeFixtureCredential.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/LocalClaudeFixtureCredential.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/MCPCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/MCPCredentials.swift) | 21 / 21 | 100.0% |
| [Sources/SandboxHost/MCPModelHandoff.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/MCPModelHandoff.swift) | 10 / 10 | 100.0% |
| [Sources/SandboxHost/MCPProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/MCPProtocol.swift) | 62 / 62 | 100.0% |
| [Sources/SandboxHost/MCPRepositoryAdapter.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/MCPRepositoryAdapter.swift) | 15 / 15 | 100.0% |
| [Sources/SandboxHost/MCPTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/MCPTransport.swift) | 111 / 172 | 64.5% |
| [Sources/SandboxHost/ModelCredentialReflection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelCredentialReflection.swift) | 280 / 283 | 98.9% |
| [Sources/SandboxHost/ModelCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelCredentials.swift) | 71 / 148 | 48.0% |
| [Sources/SandboxHost/ModelJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelJSON.swift) | 130 / 134 | 97.0% |
| [Sources/SandboxHost/ModelStructured.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelStructured.swift) | 129 / 129 | 100.0% |
| [Sources/SandboxHost/ModelTools.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelTools.swift) | 67 / 91 | 73.6% |
| [Sources/SandboxHost/ModelTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/ModelTransport.swift) | 436 / 475 | 91.8% |
| [Sources/SandboxHost/NativeResponseChannel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/NativeResponseChannel.swift) | 102 / 120 | 85.0% |
| [Sources/SandboxHost/NativeResponseSerializer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/NativeResponseSerializer.swift) | 262 / 281 | 93.2% |
| [Sources/SandboxHost/RunClock.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/RunClock.swift) | 69 / 73 | 94.5% |
| [Sources/SandboxHost/RunLifecycle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/RunLifecycle.swift) | 251 / 350 | 71.7% |
| [Sources/SandboxHost/RuntimeJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/RuntimeJSON.swift) | 155 / 156 | 99.4% |
| [Sources/SandboxHost/SecurityEvent.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/SecurityEvent.swift) | 23 / 25 | 92.0% |
| [Sources/SandboxHost/VMDiagnosticSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/VMDiagnosticSession.swift) | 68 / 69 | 98.6% |
| [Sources/SandboxHost/VMProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/VMProtocol.swift) | 41 / 41 | 100.0% |
| [Sources/SandboxHost/VMVerifiedBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/VMVerifiedBundle.swift) | 48 / 48 | 100.0% |
| [Sources/SandboxHost/WorkspaceCopy.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/WorkspaceCopy.swift) | 841 / 865 | 97.2% |
| [Sources/SandboxHost/WorkspaceEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/WorkspaceEffects.swift) | 96 / 96 | 100.0% |
| [Sources/SandboxHost/WorkspaceGrantQuota.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/WorkspaceGrantQuota.swift) | 184 / 191 | 96.3% |
| [Sources/SandboxHost/WorkspaceRunSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/WorkspaceRunSession.swift) | 0 / 103 | 0.0% |
| [Sources/SandboxHost/WorkspaceTransfer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxHost/WorkspaceTransfer.swift) | 376 / 377 | 99.7% |
| [Sources/SandboxWorkbench/BusinessTaskController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/BusinessTaskController.swift) | 56 / 618 | 9.1% |
| [Sources/SandboxWorkbench/BusinessTaskView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/BusinessTaskView.swift) | 0 / 573 | 0.0% |
| [Sources/SandboxWorkbench/ConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/ConnectionSettings.swift) | 83 / 90 | 92.2% |
| [Sources/SandboxWorkbench/ConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/ConnectionSettingsView.swift) | 130 / 137 | 94.9% |
| [Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift) | 43 / 50 | 86.0% |
| [Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift) | 0 / 0 | n/a |
| [Sources/SandboxWorkbench/MCPConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/MCPConnectionSettings.swift) | 51 / 55 | 92.7% |
| [Sources/SandboxWorkbench/MCPConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/MCPConnectionSettingsView.swift) | 0 / 74 | 0.0% |
| [Sources/SandboxWorkbench/RunComposition.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/RunComposition.swift) | 356 / 372 | 95.7% |
| [Sources/SandboxWorkbench/WorkbenchModel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/WorkbenchModel.swift) | 353 / 374 | 94.4% |
| [Sources/SandboxWorkbench/WorkbenchView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/234ce0d3c5e7afc9ddbd53c86878470b4c0b0cb7/Sources/SandboxWorkbench/WorkbenchView.swift) | 471 / 472 | 99.8% |
