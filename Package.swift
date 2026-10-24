// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MiniSandbox",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SandboxContracts", targets: ["SandboxContracts"]),
        .library(name: "SandboxHost", targets: ["SandboxHost"]),
        .executable(name: "MiniSandbox", targets: ["MiniSandboxApp"]),
        .executable(name: "ContractChecks", targets: ["ContractChecks"]),
        .executable(name: "AuthorizationChecks", targets: ["AuthorizationChecks"]),
        .executable(name: "ModelTransportChecks", targets: ["ModelTransportChecks"]),
        .executable(name: "HostIntegrationChecks", targets: ["HostIntegrationChecks"]),
        .executable(name: "StructuredModelChecks", targets: ["StructuredModelChecks"]),
        .executable(name: "MCPGatewayChecks", targets: ["MCPGatewayChecks"]),
        .executable(name: "WorkbenchChecks", targets: ["WorkbenchChecks"]),
        .executable(name: "VMChecks", targets: ["VMChecks"]),
        .executable(name: "VMProbe", targets: ["VMProbe"]),
        .executable(name: "WorkspaceChecks", targets: ["WorkspaceChecks"])
    ],
    targets: [
        .target(name: "SandboxContracts"),
        .target(name: "SandboxHost", dependencies: ["SandboxContracts"], linkerSettings: [.linkedFramework("Virtualization")]),
        .executableTarget(name: "MiniSandboxApp", dependencies: ["SandboxHost", "SandboxContracts", "SandboxWorkbench"]),
        .executableTarget(name: "ContractChecks", dependencies: ["SandboxContracts"], path: "Tests/SandboxContractsTests"),
        .executableTarget(name: "AuthorizationChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/AuthorizationChecks"),
        .executableTarget(name: "ModelTransportChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/ModelTransportChecks"),
        .executableTarget(name: "HostIntegrationChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/HostIntegrationChecks"),
        .executableTarget(name: "StructuredModelChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/StructuredModelChecks"),
        .executableTarget(name: "MCPGatewayChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/MCPGatewayChecks"),
        .target(name: "SandboxWorkbench", dependencies: ["SandboxHost", "SandboxContracts"]),
        .executableTarget(name: "WorkbenchChecks", dependencies: ["SandboxWorkbench", "SandboxHost", "SandboxContracts"], path: "Tests/WorkbenchChecks"),
        .executableTarget(name: "VMChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/VMChecks", exclude: ["test_build_vm_probe.py", "live_lifecycle.py"]),
        .executableTarget(name: "VMProbe", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tools/VMProbe"),
        .executableTarget(name: "WorkspaceChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/WorkspaceChecks")
    ]
)
