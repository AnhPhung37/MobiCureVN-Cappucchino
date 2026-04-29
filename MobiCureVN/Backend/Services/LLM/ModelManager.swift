import Foundation

/// Simple download-on-first-run ModelManager.
/// - Downloads a zip from a configured URL and extracts into Application Support.
/// - Exposes `ensureModelReady(modelName:)` which returns a local directory URL.
public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    private let fileManager = FileManager.default

    /// Default HuggingFace-like archive URL template.
    /// Replace this or provide a hosted zip URL for your model. The template uses the model name as provided.
    private func defaultArchiveURL(for modelName: String) -> URL {
        // NOTE: This is a placeholder. Replace with a valid URL for the model archive.
        let name = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        return URL(string: "https://huggingface.co/" + name + "/resolve/main/model.zip")!
    }

    /// Returns Application Support folder for the app.
    private func applicationSupportDirectory() throws -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let url = urls.first {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        }
        throw NSError(domain: "ModelManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not locate Application Support directory."])
    }

    /// Ensure the model is downloaded and extracted. Returns local folder URL containing model files.
    public func ensureModelReady(modelName: String) async throws -> URL {
        let support = try applicationSupportDirectory()
        let modelDir = support.appendingPathComponent(modelName, isDirectory: true)

        if fileManager.fileExists(atPath: modelDir.path) {
            return modelDir
        }

        // Create temp directory for download
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: tmpDir, withIntermediateDirectories: true, attributes: nil)

        let archiveURL = defaultArchiveURL(for: modelName)
        let downloadLocation = tmpDir.appendingPathComponent("model.zip")

        let (localURL, _) = try await URLSession.shared.download(from: archiveURL)
        try fileManager.moveItem(at: localURL, to: downloadLocation)

        // unzip using system `unzip` for reliability across macOS versions
        try unzipArchive(at: downloadLocation, to: tmpDir)

        // The archive should extract files directly (config.json, tokenizer.json, model.*) into tmpDir
        // If the archive created a single top-level folder, find it and use that as extracted
        let extractedDir: URL
        let children = try fileManager.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        if children.count == 1, children.first?.hasDirectoryPath == true {
            extractedDir = children.first!
        } else {
            extractedDir = tmpDir
        }

        // Move extracted directory to Application Support
        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true, attributes: nil)
        let items = try fileManager.contentsOfDirectory(at: extractedDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        for item in items {
            let dest = modelDir.appendingPathComponent(item.lastPathComponent)
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.moveItem(at: item, to: dest)
        }

        // Cleanup temp dir
        try? fileManager.removeItem(at: tmpDir)

        return modelDir
    }

    private func unzipArchive(at archive: URL, to destination: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archive.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw NSError(domain: "ModelManager", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "Unzip failed with status \(process.terminationStatus)"])
        }
        #else
        throw NSError(domain: "ModelManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unzip is only supported on macOS in this build."])
        #endif
    }
}
