# Swift CI line coverage

**77.3%** — 11,016 / 14,251 executable lines.

Source commit: [`f48ea5ec0544`](https://github.com/mingmingtsao/mini-sandbox/commit/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca).

Scope: all Swift files under `Sources/`, including files with zero hits. Excludes `Tests/`, `Tools/`, Python, Go and generated code.

Executed checks: `ContractChecks`, `AuthorizationChecks`, `ModelTransportChecks --offline`, `HostIntegrationChecks`, `StructuredModelChecks`, `WorkbenchChecks`, `SharedAuthorityChecks`, `WorkspaceChecks`, `WorkspaceTransferChecks`, `VMChecks`, `RuntimeReceiveChecks`, `PresentationChecks (validated)`, `BusinessIngressChecks`, `MCPGatewayChecks (Claude loopback)`, `ExecutionBoundaryChecks (reflection loopback)`, `ExecutionBoundaryChecks`, `ExecutionBoundaryChecks --final-effect-clock`, `ExecutionBoundaryChecks --native-repairs`, `ExecutionBoundaryChecks --native-response`, `MCPGatewayChecks --transport-unit`, `MCPGatewayChecks (loopback)`, `MCPGatewayChecks (independent loopback)`, `ExecutionBoundaryChecks --mcp (loopback)`, `ExecutionBoundaryChecks --mcp-transaction (loopback)`, `WorkbenchChecks --composition-mcp (loopback)`, `MiniSandbox --diagnostics-json (validated)`. Compiling another target does not count as exercising it.

[CI run](https://github.com/mingmingtsao/mini-sandbox/actions/runs/40245489165)

| Source | Covered / executable lines | Coverage |
|---|---:|---:|
| [Sources/MiniSandboxApp/MiniSandboxApp.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/MiniSandboxApp/MiniSandboxApp.swift) | 195 / 331 | 58.9% |
| [Sources/SandboxContracts/Contracts.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxContracts/Contracts.swift) | 154 / 156 | 98.7% |
| [Sources/SandboxHost/AgentRuntimeProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/AgentRuntimeProbe.swift) | 234 / 436 | 53.7% |
| [Sources/SandboxHost/AnthropicNativeRequest.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/AnthropicNativeRequest.swift) | 177 / 179 | 98.9% |
| [Sources/SandboxHost/AnthropicStreamDecoder.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/AnthropicStreamDecoder.swift) | 134 / 137 | 97.8% |
| [Sources/SandboxHost/AuthorizationController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/AuthorizationController.swift) | 470 / 500 | 94.0% |
| [Sources/SandboxHost/BusinessDisplayOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessDisplayOutput.swift) | 93 / 93 | 100.0% |
| [Sources/SandboxHost/BusinessHTTPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessHTTPIngress.swift) | 96 / 105 | 91.4% |
| [Sources/SandboxHost/BusinessModelActivation.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessModelActivation.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/BusinessRuntimeBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessRuntimeBundle.swift) | 70 / 101 | 69.3% |
| [Sources/SandboxHost/BusinessVMConnection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessVMConnection.swift) | 0 / 223 | 0.0% |
| [Sources/SandboxHost/BusinessVMEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessVMEffects.swift) | 0 / 144 | 0.0% |
| [Sources/SandboxHost/BusinessVMSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/BusinessVMSession.swift) | 0 / 462 | 0.0% |
| [Sources/SandboxHost/ClaudeMCPIngress.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ClaudeMCPIngress.swift) | 188 / 193 | 97.4% |
| [Sources/SandboxHost/ClaudeModelAdmission.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ClaudeModelAdmission.swift) | 58 / 60 | 96.7% |
| [Sources/SandboxHost/ClaudeRequestSelectors.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ClaudeRequestSelectors.swift) | 11 / 11 | 100.0% |
| [Sources/SandboxHost/ControlledRunOutput.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ControlledRunOutput.swift) | 196 / 208 | 94.2% |
| [Sources/SandboxHost/EnvironmentInspector.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/EnvironmentInspector.swift) | 32 / 33 | 97.0% |
| [Sources/SandboxHost/HeadlessVMProbe.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/HeadlessVMProbe.swift) | 31 / 409 | 7.6% |
| [Sources/SandboxHost/HostCLIPermissionGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/HostCLIPermissionGateway.swift) | 96 / 253 | 37.9% |
| [Sources/SandboxHost/HostMCPGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/HostMCPGateway.swift) | 524 / 565 | 92.7% |
| [Sources/SandboxHost/HostModelGateway.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/HostModelGateway.swift) | 559 / 608 | 91.9% |
| [Sources/SandboxHost/LocalClaudeFixtureCredential.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/LocalClaudeFixtureCredential.swift) | 0 / 0 | n/a |
| [Sources/SandboxHost/MCPCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/MCPCredentials.swift) | 34 / 34 | 100.0% |
| [Sources/SandboxHost/MCPModelHandoff.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/MCPModelHandoff.swift) | 17 / 17 | 100.0% |
| [Sources/SandboxHost/MCPProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/MCPProtocol.swift) | 92 / 92 | 100.0% |
| [Sources/SandboxHost/MCPRepositoryAdapter.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/MCPRepositoryAdapter.swift) | 17 / 17 | 100.0% |
| [Sources/SandboxHost/MCPTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/MCPTransport.swift) | 227 / 233 | 97.4% |
| [Sources/SandboxHost/ModelCredentialReflection.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelCredentialReflection.swift) | 327 / 335 | 97.6% |
| [Sources/SandboxHost/ModelCredentials.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelCredentials.swift) | 110 / 184 | 59.8% |
| [Sources/SandboxHost/ModelJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelJSON.swift) | 183 / 191 | 95.8% |
| [Sources/SandboxHost/ModelStructured.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelStructured.swift) | 195 / 196 | 99.5% |
| [Sources/SandboxHost/ModelTools.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelTools.swift) | 112 / 123 | 91.1% |
| [Sources/SandboxHost/ModelTransport.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/ModelTransport.swift) | 519 / 565 | 91.9% |
| [Sources/SandboxHost/NativeResponseChannel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/NativeResponseChannel.swift) | 145 / 172 | 84.3% |
| [Sources/SandboxHost/NativeResponseSerializer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/NativeResponseSerializer.swift) | 340 / 354 | 96.0% |
| [Sources/SandboxHost/RunClock.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/RunClock.swift) | 92 / 96 | 95.8% |
| [Sources/SandboxHost/RunLifecycle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/RunLifecycle.swift) | 333 / 400 | 83.2% |
| [Sources/SandboxHost/RuntimeJSON.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/RuntimeJSON.swift) | 214 / 216 | 99.1% |
| [Sources/SandboxHost/SecurityEvent.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/SecurityEvent.swift) | 35 / 37 | 94.6% |
| [Sources/SandboxHost/VMDiagnosticSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/VMDiagnosticSession.swift) | 103 / 109 | 94.5% |
| [Sources/SandboxHost/VMProtocol.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/VMProtocol.swift) | 53 / 53 | 100.0% |
| [Sources/SandboxHost/VMVerifiedBundle.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/VMVerifiedBundle.swift) | 67 / 67 | 100.0% |
| [Sources/SandboxHost/WorkspaceCopy.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/WorkspaceCopy.swift) | 1006 / 1049 | 95.9% |
| [Sources/SandboxHost/WorkspaceEffects.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/WorkspaceEffects.swift) | 116 / 116 | 100.0% |
| [Sources/SandboxHost/WorkspaceGrantQuota.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/WorkspaceGrantQuota.swift) | 213 / 215 | 99.1% |
| [Sources/SandboxHost/WorkspaceRunSession.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/WorkspaceRunSession.swift) | 81 / 122 | 66.4% |
| [Sources/SandboxHost/WorkspaceTransfer.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxHost/WorkspaceTransfer.swift) | 496 / 503 | 98.6% |
| [Sources/SandboxWorkbench/BusinessTaskController.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/BusinessTaskController.swift) | 318 / 862 | 36.9% |
| [Sources/SandboxWorkbench/BusinessTaskView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/BusinessTaskView.swift) | 390 / 728 | 53.6% |
| [Sources/SandboxWorkbench/ConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/ConnectionSettings.swift) | 109 / 118 | 92.4% |
| [Sources/SandboxWorkbench/ConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/ConnectionSettingsView.swift) | 145 / 152 | 95.4% |
| [Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/KeychainCanarySelfCheck.swift) | 47 / 56 | 83.9% |
| [Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/LocalBusinessNoCredentialStore.swift) | 0 / 0 | n/a |
| [Sources/SandboxWorkbench/MCPConnectionSettings.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/MCPConnectionSettings.swift) | 63 / 67 | 94.0% |
| [Sources/SandboxWorkbench/MCPConnectionSettingsView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/MCPConnectionSettingsView.swift) | 95 / 106 | 89.6% |
| [Sources/SandboxWorkbench/RunComposition.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/RunComposition.swift) | 390 / 410 | 95.1% |
| [Sources/SandboxWorkbench/WorkbenchModel.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/WorkbenchModel.swift) | 407 / 441 | 92.3% |
| [Sources/SandboxWorkbench/WorkbenchView.swift](https://github.com/mingmingtsao/mini-sandbox/blob/f48ea5ec05446df3dc73c6c9f3c81b1db53494ca/Sources/SandboxWorkbench/WorkbenchView.swift) | 607 / 608 | 99.8% |
