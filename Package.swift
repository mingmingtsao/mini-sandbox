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
        .executable(name: "VMChecks", targets: ["VMChecks"]),
        .executable(name: "VMProbe", targets: ["VMProbe"])
    ],
    targets: [
        .target(name: "SandboxContracts"),
        .target(name: "SandboxHost", dependencies: ["SandboxContracts"], linkerSettings: [.linkedFramework("Virtualization")]),
        .executableTarget(name: "MiniSandboxApp", dependencies: ["SandboxHost", "SandboxContracts"]),
        .executableTarget(name: "ContractChecks", dependencies: ["SandboxContracts"], path: "Tests/SandboxContractsTests"),
        .executableTarget(name: "AuthorizationChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/AuthorizationChecks"),
        .executableTarget(name: "VMChecks", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tests/VMChecks", exclude: ["test_build_vm_probe.py", "live_lifecycle.py"]),
        .executableTarget(name: "VMProbe", dependencies: ["SandboxHost", "SandboxContracts"], path: "Tools/VMProbe")
    ]
)
