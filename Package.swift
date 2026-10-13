// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Spillcheck",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SpillcheckCore", targets: ["SpillcheckCore"]),
        .executable(name: "spillcheck-hook", targets: ["SpillcheckHook"]),
        .executable(name: "spillcheck-storage-acceptance", targets: ["SpillcheckAcceptance"]),
        .executable(name: "spillcheck-resource-acceptance", targets: ["SpillcheckResourceAcceptance"]),
        .executable(name: "spillcheck-codex-hook-delivery-probe", targets: ["CodexHookDeliveryProbe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "SpillcheckCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .executableTarget(name: "SpillcheckHook"),
        .executableTarget(name: "SpillcheckAcceptance", dependencies: ["SpillcheckCore"]),
        .executableTarget(name: "SpillcheckResourceAcceptance", dependencies: ["SpillcheckCore"]),
        .executableTarget(name: "CodexHookDeliveryProbe", dependencies: ["SpillcheckCore"],
                          path: "Tests/CodexHookDeliveryProbe", exclude: ["run.py", "README.md"]),
        .testTarget(
            name: "SpillcheckCoreTests",
            dependencies: ["SpillcheckCore"],
            path: "Tests",
            exclude: [
                "README.md", "HookHelper", "ProtectionSignedProbe", "ClaudeLive", "CodexLive", "AgentSetupProbe",
                "NativeWorkflowProbe", "ResourceAcceptance", "AppAcceptance", "Tooling", "Support",
                "CodexHookDeliveryProbe", "CodexPlanProbe", "CodexReviewProbe",
                "CodexReviewRecoveryProbe", "CodexMCPSourceProbe", "CodexMCPPipelineProbe",
                "CodexHookPromptProbe", "CodexLocalMediaProbe", "BetaTrial",
            ],
            sources: ["SpillcheckCoreTests"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
