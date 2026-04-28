// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalChatEngine",
    platforms: [
        .macOS(.v14) // MLX requires macOS 14+ natively
    ],
    products: [
        .library(name: "ChatEngineCore", targets: ["ChatEngineCore"]),
        .executable(name: "ChatEngineCLI", targets: ["ChatEngineCLI"])
    ],
    dependencies: [
        // Apple's official MLX Swift package
        // We use both of these because MLX provides the core model loading and tokenization, 
        // while MLXLMCommon provides a simple interface for generation that we can use in our LLMService. Niche huh
        .package(url: "https://github.com/ml-explore/mlx-swift.git", from: "0.31.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples.git", branch: "main")
    ],
    targets: [
        .target(
            name: "ChatEngineCore",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples")
            ],
            path: ".",
            sources: [
                "Chat",
                "LLM/LLMService.swift",
                "Memory/ConversationMemory.swift",
                "Tools/ToolExecutor.swift",
                "Models/ChatMessage.swift"
            ]
        ),
        .executableTarget(
            name: "ChatEngineCLI",
            dependencies: ["ChatEngineCore"],
            path: ".",
            sources: [
                "main.swift"
            ]
        )
    ]
)
