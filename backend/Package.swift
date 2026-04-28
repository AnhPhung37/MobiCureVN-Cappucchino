// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LocalChatEngine",
    products: [
        .library(name: "ChatEngineCore", targets: ["ChatEngineCore"]),
        .executable(name: "ChatEngineCLI", targets: ["ChatEngineCLI"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "ChatEngineCore",
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
