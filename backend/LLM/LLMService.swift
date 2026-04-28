import Foundation

public final class LLMService: @unchecked Sendable {
    private let modelPath: String?
    private let pythonPath: String
    private let useMock: Bool

    public init(modelPath: String? = nil, pythonPath: String = "/usr/bin/python3", useMock: Bool = true) {
        self.modelPath = modelPath
        self.pythonPath = pythonPath
        self.useMock = useMock
    }

    public func generate(prompt: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }
                if self.useMock || self.modelPath == nil {
                    let reply = "I can share general information, but I cannot diagnose or prescribe. Consider consulting a clinician."
                    for chunk in Self.chunk(reply, size: 48) {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                    return
                }

                let output = await self.runMLX(prompt: prompt)
                for chunk in Self.chunk(output, size: 64) {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        }
    }

    private func runMLX(prompt: String) async -> String {
        guard let modelPath else {
            return "LLM unavailable."
        }
        do {
            return try await ProcessRunner.run(
                executable: pythonPath,
                arguments: [
                    "-m", "mlx_lm.generate",
                    "--model", modelPath,
                    "--prompt", prompt,
                    "--max-tokens", "512",
                    "--temp", "0.2",
                    "--quiet"
                ]
            )
        } catch {
            return "LLM unavailable."
        }
    }

    private static func chunk(_ text: String, size: Int) -> [String] {
        guard size > 0 else { return [text] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}

private enum ProcessRunner {
    static func run(executable: String, arguments: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            try process.run()
            process.waitUntilExit()

            let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outputData, encoding: .utf8) ?? ""
            return output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }
}
