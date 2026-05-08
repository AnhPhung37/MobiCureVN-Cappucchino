import Foundation
import CryptoKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Robust download-on-first-run ModelManager.
/// - Downloads a zip from a configured URL, verifies SHA256 (if provided), and extracts into Application Support.
/// - Uses an atomic install pattern: download -> verify -> unpack into temp -> move into models folder.
public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    private let fileManager = FileManager.default

    private let defaultCommunityRepoID = "mlx-community/Qwen2.5-3B-Instruct-4bit"

    private func defaultCommunityRepoID(for modelName: String) -> String {
        if modelName.hasPrefix("mlx-community/") {
            return modelName
        }
        return defaultCommunityRepoID
    }

    private enum ModelManagerError: Error {
        case applicationSupportUnavailable
        case downloadFailed
        case checksumMismatch(expected: String, actual: String)
        case unzipFailed(code: Int32)
        case validationFailed(String)
        case httpError(code: Int)
        case repositoryLookupFailed
    }

    private struct HFModelInfo: Decodable {
        struct Sibling: Decodable {
            let rfilename: String
            let size: Int?
        }

        let siblings: [Sibling]?
    }

    private func applicationSupportDirectory() throws -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let url = urls.first {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        }
        throw ModelManagerError.applicationSupportUnavailable
    }

    private func localModelDirectory(modelName: String, repoID: String?) throws -> URL {
        let support = try applicationSupportDirectory()
        let modelsRoot = support.appendingPathComponent("models", isDirectory: true)
        let resolvedRepoID = defaultCommunityRepoID(for: repoID ?? modelName)
        return modelsRoot.appendingPathComponent(resolvedRepoID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    /// Return the local model directory URL if a valid model exists, otherwise `nil`.
    public func getLocalModelPath(modelName: String, repoID: String?) -> URL? {
        do {
            let dir = try localModelDirectory(modelName: modelName, repoID: repoID)
            if isValidLocalModelDirectory(dir) {
                return dir
            }
        } catch {
            return nil
        }
        return nil
    }

    private func containsFile(in directory: URL, named fileName: String) -> Bool {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if fileURL.lastPathComponent.lowercased() == fileName.lowercased() {
                return true
            }
        }
        return false
    }

    private func containsAnyFile(withExtensions extensions: Set<String>, in directory: URL) -> Bool {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return false
        }

        for case let fileURL as URL in enumerator {
            if extensions.contains(fileURL.pathExtension.lowercased()) {
                return true
            }
        }
        return false
    }

    private func isValidLocalModelDirectory(_ directory: URL) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        let hasConfig = containsFile(in: directory, named: "config.json")
        let hasTokenizer = containsFile(in: directory, named: "tokenizer.json") || containsFile(in: directory, named: "tokenizer.model")
        let hasWeights = containsAnyFile(withExtensions: ["safetensors", "bin", "gguf"], in: directory)

        return hasConfig && hasTokenizer && hasWeights
    }

    /// Ensure the model is downloaded, verified and extracted. Returns local folder URL containing model files.
    /// - Parameters:
    ///   - modelName: logical model name
    ///   - archiveURL: optional archive URL to download a zip/tar archive; if nil, repoID is used when provided
    ///   - expectedSHA256: optional lowercase hex SHA256 checksum to verify archive
    /// Ensure the model is downloaded, verified and extracted.
    /// - Parameters:
    ///   - modelName: logical model name
    ///   - archiveURL: optional archive URL to download a zip/tar archive; if nil, repoID is used when provided
    ///   - expectedSHA256: optional lowercase hex SHA256 checksum to verify archive
    ///   - minFreeBytes: optional minimum free bytes required before download (default 500 MB)
    ///   - progress: optional progress callback (0.0 .. 1.0)
    ///   - maxRetries: number of download retries
    ///   - authToken: optional bearer token for authenticated model endpoints
    ///   - repoID: optional Hugging Face repo identifier used for community MLX repos
    public func ensureModelReady(modelName: String,
                                 archiveURL: URL? = nil,
                                 expectedSHA256: String? = nil,
                                 minFreeBytes: Int64? = nil,
                                 progress: ((Double) -> Void)? = nil,
                                 maxRetries: Int = 3,
                                 authToken: String? = nil,
                                 repoID: String? = nil) async throws -> URL {
        print("ModelManager: ensureModelReady(\(modelName)) start")
        progress?(0.0)
        let support = try applicationSupportDirectory()
        print("ModelManager: applicationSupportDirectory=\(support.path)")
        let modelsRoot = support.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true, attributes: nil)

        let resolvedRepoID = defaultCommunityRepoID(for: repoID ?? modelName)
        let modelDir = try localModelDirectory(modelName: modelName, repoID: repoID)
        if fileManager.fileExists(atPath: modelDir.path) {
            if isValidLocalModelDirectory(modelDir) {
                print("ModelManager: model already present at \(modelDir.path)")
                progress?(1.0)
                return modelDir
            }

            print("ModelManager: existing model at \(modelDir.path) is incomplete or invalid, removing it")
            try? fileManager.removeItem(at: modelDir)
        }

        // prepare tmp working dir under Application Support so moves stay on same volume
        let tmpRoot = modelsRoot.appendingPathComponent("tmp", isDirectory: true)
        try? fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true, attributes: nil)
        let downloadDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true, attributes: nil)

        if let archiveSource = archiveURL {
            print("ModelManager: archiveSource=\(archiveSource.absoluteString)")
            let tempArchive = downloadDir.appendingPathComponent("archive.zip")

            // optional disk-space check
            let requiredMin = minFreeBytes ?? 500_000_000 // 500 MB
            if let free = freeDiskSpace(at: support), free < requiredMin {
                print("ModelManager: progress 0% - disk space check failed")
                try? fileManager.removeItem(at: downloadDir)
                throw ModelManagerError.validationFailed("Not enough free disk space: \(free) < \(requiredMin)")
            }

            try await downloadAndInstallArchive(at: archiveSource,
                                                tempArchive: tempArchive,
                                                modelDir: modelDir,
                                                downloadDir: downloadDir,
                                                expectedSHA256: expectedSHA256,
                                                progress: progress,
                                                maxRetries: maxRetries,
                                                authToken: authToken)

            return modelDir
        }

        // Community MLX repo flow: download repo files directly instead of a fake zip.
        try await downloadCommunityRepository(repoID: resolvedRepoID,
                                             modelDir: modelDir,
                                             downloadDir: downloadDir,
                                             progress: progress,
                                             authToken: authToken)

        return modelDir
    }

    private func downloadAndInstallArchive(at archiveSource: URL,
                                           tempArchive: URL,
                                           modelDir: URL,
                                           downloadDir: URL,
                                           expectedSHA256: String?,
                                           progress: ((Double) -> Void)?,
                                           maxRetries: Int,
                                           authToken: String?) async throws {
        print("ModelManager: archiveSource=\(archiveSource.absoluteString)")

        // download with retries and exponential backoff
        for attempt in 1...maxRetries {
            if Task.isCancelled { throw CancellationError() }
            do {
                var request = URLRequest(url: archiveSource)
                if let token = authToken, !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }

                let (localURL, response) = try await URLSession.shared.download(for: request)
                if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                    throw ModelManagerError.httpError(code: http.statusCode)
                }
                if fileManager.fileExists(atPath: tempArchive.path) {
                    try? fileManager.removeItem(at: tempArchive)
                }
                try fileManager.moveItem(at: localURL, to: tempArchive)
                try validateArchiveLooksLikeZip(at: tempArchive, source: archiveSource)
                print("ModelManager: downloaded archive to \(tempArchive.path) (attempt \(attempt))")
                progress?(0.5)
                break
            } catch {
                print("ModelManager: download attempt \(attempt) failed: \(error)")
                print("ModelManager: progress 0% - download phase failed")

                if case let ModelManagerError.httpError(code) = error,
                   [400, 401, 403, 404].contains(code) {
                    try? fileManager.removeItem(at: downloadDir)
                    throw error
                }

                if attempt < maxRetries {
                    let backoff = UInt64(2_000_000_000 * UInt64(attempt))
                    try? await Task.sleep(nanoseconds: backoff)
                    continue
                } else {
                    try? fileManager.removeItem(at: downloadDir)
                    print("ModelManager: download failed after \(maxRetries) attempts")
                    throw ModelManagerError.downloadFailed
                }
            }
        }

        if let expected = expectedSHA256?.lowercased() {
            let data = try Data(contentsOf: tempArchive)
            let digest = SHA256.hash(data: data)
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            if actual != expected {
                print("ModelManager: checksum mismatch expected=\(expected) actual=\(actual)")
                print("ModelManager: progress 50% - checksum phase failed")
                try? fileManager.removeItem(at: downloadDir)
                throw ModelManagerError.checksumMismatch(expected: expected, actual: actual)
            }
        }

        let unpackDir = downloadDir.appendingPathComponent("unpack", isDirectory: true)
        try fileManager.createDirectory(at: unpackDir, withIntermediateDirectories: true, attributes: nil)
        try unzipArchive(at: tempArchive, to: unpackDir)
        print("ModelManager: unpacked archive to \(unpackDir.path)")
        progress?(0.8)

        let children = try fileManager.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        let extractedRoot: URL
        if children.count == 1, children.first?.hasDirectoryPath == true {
            extractedRoot = children.first!
        } else {
            extractedRoot = unpackDir
        }

        let manifestURL = extractedRoot.appendingPathComponent("manifest.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            let found = try fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if found.isEmpty {
                print("ModelManager: progress 80% - extracted archive empty")
                try? fileManager.removeItem(at: downloadDir)
                throw ModelManagerError.validationFailed("Archive did not contain any files")
            }
        }

        let pending = modelDir.deletingLastPathComponent().appendingPathComponent(modelDir.lastPathComponent + ".pending", isDirectory: true)
        if fileManager.fileExists(atPath: pending.path) {
            try? fileManager.removeItem(at: pending)
        }
        try fileManager.moveItem(at: extractedRoot, to: pending)

        if fileManager.fileExists(atPath: modelDir.path) {
            try? fileManager.removeItem(at: pending)
            try? fileManager.removeItem(at: downloadDir)
            return
        }

        try fileManager.moveItem(at: pending, to: modelDir)
        print("ModelManager: installed model to \(modelDir.path)")
        progress?(1.0)
        try? fileManager.removeItem(at: downloadDir)
    }

    private func downloadCommunityRepository(repoID: String,
                                             modelDir: URL,
                                             downloadDir: URL,
                                             progress: ((Double) -> Void)?,
                                             authToken: String?) async throws {
        print("ModelManager: using community repo flow for \(repoID)")

        let apiURL = URL(string: "https://huggingface.co/api/models/\(repoID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repoID)")!
        var request = URLRequest(url: apiURL)
        if let token = authToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelManagerError.httpError(code: http.statusCode)
        }

        let modelInfo = try JSONDecoder().decode(HFModelInfo.self, from: data)
        let files = (modelInfo.siblings ?? []).map { $0.rfilename }
        let allowedExtensions = ["json", "safetensors", "model", "txt", "md", "tiktoken"]
        let downloadableFiles = files.filter { filename in
            let lower = filename.lowercased()
            return allowedExtensions.contains(where: { lower.hasSuffix(".\($0)") })
        }

        guard !downloadableFiles.isEmpty else {
            try? fileManager.removeItem(at: downloadDir)
            throw ModelManagerError.repositoryLookupFailed
        }

        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true, attributes: nil)

        let total = Double(downloadableFiles.count)
        for (index, filename) in downloadableFiles.enumerated() {
            if Task.isCancelled { throw CancellationError() }
            let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)")!
            var fileRequest = URLRequest(url: fileURL)
            if let token = authToken, !token.isEmpty {
                fileRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }

            let (downloadedURL, response2) = try await URLSession.shared.download(for: fileRequest)
            if let http = response2 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw ModelManagerError.httpError(code: http.statusCode)
            }

            let destination = modelDir.appendingPathComponent(filename)
            let destinationDir = destination.deletingLastPathComponent()
            try fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: downloadedURL, to: destination)

            let percent = Double(index + 1) / total
            print("ModelManager: downloaded \(filename) [\(index + 1)/\(downloadableFiles.count)]")
            progress?(percent)
        }

        print("ModelManager: installed community repo files at \(modelDir.path)")
        progress?(1.0)
        try? fileManager.removeItem(at: downloadDir)
    }

    private func unzipArchive(at archive: URL, to destination: URL) throws {
        #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-o", archive.path, "-d", destination.path]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ModelManagerError.unzipFailed(code: process.terminationStatus)
        }
        #else
        #if canImport(ZIPFoundation)
        try fileManager.unzipItem(at: archive, to: destination)
        #else
        throw NSError(
            domain: "ModelManager",
            code: -1,
            userInfo: [
                NSLocalizedDescriptionKey: "ZIPFoundation is not available in this target. Add package https://github.com/weichsel/ZIPFoundation and link it to the app target to unzip on iOS/simulator."
            ]
        )
        #endif
        #endif
    }

    private func validateArchiveLooksLikeZip(at archive: URL, source: URL) throws {
        let fh = try FileHandle(forReadingFrom: archive)
        defer { try? fh.close() }

        let header = fh.readData(ofLength: 4)
        guard header.count >= 2 else {
            throw ModelManagerError.validationFailed("Archive too small: \(source.absoluteString)")
        }

        let bytes = [UInt8](header)
        // ZIP: PK\x03\x04 (50 4B 03 04), also allow central directory signatures variants
        if bytes.count >= 4,
           bytes[0] == 0x50, bytes[1] == 0x4B {
            return
        }

        // GZIP: 1F 8B
        if bytes[0] == 0x1F, bytes[1] == 0x8B {
            return
        }

        throw ModelManagerError.validationFailed("Archive at \(source.absoluteString) does not appear to be ZIP or GZIP")
    }

    private func freeDiskSpace(at url: URL) -> Int? {
        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let capacity = values.volumeAvailableCapacityForImportantUsage {
                return Int(capacity)
            }
        } catch {
            // fallback
        }

        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityKey])
            if let capacity = values.volumeAvailableCapacity {
                return capacity
            }
        } catch {
            return nil
        }

        return nil
    }
}
