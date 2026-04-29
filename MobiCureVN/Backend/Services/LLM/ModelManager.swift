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

    /// Default HuggingFace-like archive URL template.
    /// Replace this or provide a hosted zip URL for your model. The template uses the model name as provided.
    private func defaultArchiveURL(for modelName: String) -> URL {
        let name = modelName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? modelName
        return URL(string: "https://huggingface.co/" + name + "/resolve/main/model.zip")!
    }

    private enum ModelManagerError: Error {
        case applicationSupportUnavailable
        case downloadFailed
        case checksumMismatch(expected: String, actual: String)
        case unzipFailed(code: Int32)
        case validationFailed(String)
        case httpError(code: Int)
    }

    private func applicationSupportDirectory() throws -> URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        if let url = urls.first {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return url
        }
        throw ModelManagerError.applicationSupportUnavailable
    }

    /// Ensure the model is downloaded, verified and extracted. Returns local folder URL containing model files.
    /// - Parameters:
    ///   - modelName: logical model name
    ///   - archiveURL: optional archive URL to download; if nil, uses defaultArchiveURL
    ///   - expectedSHA256: optional lowercase hex SHA256 checksum to verify archive
    /// Ensure the model is downloaded, verified and extracted.
    /// - Parameters:
    ///   - modelName: logical model name
    ///   - archiveURL: optional archive URL to download; if nil, uses defaultArchiveURL
    ///   - expectedSHA256: optional lowercase hex SHA256 checksum to verify archive
    ///   - minFreeBytes: optional minimum free bytes required before download (default 500 MB)
    ///   - progress: optional progress callback (0.0 .. 1.0)
    ///   - maxRetries: number of download retries
    ///   - authToken: optional bearer token for authenticated model endpoints
    public func ensureModelReady(modelName: String,
                                 archiveURL: URL? = nil,
                                 expectedSHA256: String? = nil,
                                 minFreeBytes: Int64? = nil,
                                 progress: ((Double) -> Void)? = nil,
                                 maxRetries: Int = 3,
                                 authToken: String? = nil) async throws -> URL {
        print("ModelManager: ensureModelReady(\(modelName)) start")
        progress?(0.0)
        let support = try applicationSupportDirectory()
        print("ModelManager: applicationSupportDirectory=\(support.path)")
        let modelsRoot = support.appendingPathComponent("models", isDirectory: true)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true, attributes: nil)

        let modelDir = modelsRoot.appendingPathComponent(modelName, isDirectory: true)
        if fileManager.fileExists(atPath: modelDir.path) {
            print("ModelManager: model already present at \(modelDir.path)")
            progress?(1.0)
            return modelDir
        }

        // prepare tmp working dir under Application Support so moves stay on same volume
        let tmpRoot = modelsRoot.appendingPathComponent("tmp", isDirectory: true)
        try? fileManager.createDirectory(at: tmpRoot, withIntermediateDirectories: true, attributes: nil)
        let downloadDir = tmpRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: downloadDir, withIntermediateDirectories: true, attributes: nil)

        let archiveSource = archiveURL ?? defaultArchiveURL(for: modelName)
        print("ModelManager: archiveSource=\(archiveSource.absoluteString)")
        let tempArchive = downloadDir.appendingPathComponent("archive.zip")

        // optional disk-space check
        let requiredMin = minFreeBytes ?? 500_000_000 // 500 MB
        if let free = freeDiskSpace(at: support), free < requiredMin {
            print("ModelManager: progress 0% - disk space check failed")
            try? fileManager.removeItem(at: downloadDir)
            throw ModelManagerError.validationFailed("Not enough free disk space: \(free) < \(requiredMin)")
        }

        // download with retries and exponential backoff
        var lastError: Error?
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
                lastError = nil
                break
            } catch {
                lastError = error
                print("ModelManager: download attempt \(attempt) failed: \(error)")
                print("ModelManager: progress 0% - download phase failed")

                if case let ModelManagerError.httpError(code) = error,
                   [400, 401, 403, 404].contains(code) {
                    try? fileManager.removeItem(at: downloadDir)
                    throw error
                }

                if attempt < maxRetries {
                    let backoff = UInt64(2_000_000_000 * UInt64(attempt)) // 2s, 4s, ...
                    try? await Task.sleep(nanoseconds: backoff)
                    continue
                } else {
                    try? fileManager.removeItem(at: downloadDir)
                    print("ModelManager: download failed after \(maxRetries) attempts")
                    throw ModelManagerError.downloadFailed
                }
            }
        }

        // verify checksum if given
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

        // unzip into unpack dir
        let unpackDir = downloadDir.appendingPathComponent("unpack", isDirectory: true)
        try fileManager.createDirectory(at: unpackDir, withIntermediateDirectories: true, attributes: nil)
        try unzipArchive(at: tempArchive, to: unpackDir)
        print("ModelManager: unpacked archive to \(unpackDir.path)")
        progress?(0.8)

        // find extracted root (if single top-level folder)
        let children = try fileManager.contentsOfDirectory(at: unpackDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        let extractedRoot: URL
        if children.count == 1, children.first?.hasDirectoryPath == true {
            extractedRoot = children.first!
        } else {
            extractedRoot = unpackDir
        }

        // validate presence of a manifest or at least one model file
        let manifestURL = extractedRoot.appendingPathComponent("manifest.json")
        if !fileManager.fileExists(atPath: manifestURL.path) {
            // not fatal; but warn if no manifest and no obvious model files
            let found = try fileManager.contentsOfDirectory(at: extractedRoot, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if found.isEmpty {
                print("ModelManager: progress 80% - extracted archive empty")
                try? fileManager.removeItem(at: downloadDir)
                throw ModelManagerError.validationFailed("Archive did not contain any files")
            }
        }

        // atomic move: move extractedRoot -> modelsRoot/<modelName>.pending then rename
        let pending = modelsRoot.appendingPathComponent("\(modelName).pending", isDirectory: true)
        if fileManager.fileExists(atPath: pending.path) {
            try? fileManager.removeItem(at: pending)
        }
        try fileManager.moveItem(at: extractedRoot, to: pending)

        // if modelDir exists from concurrent install, remove pending and return existing
        if fileManager.fileExists(atPath: modelDir.path) {
            try? fileManager.removeItem(at: pending)
            try? fileManager.removeItem(at: downloadDir)
            return modelDir
        }

        try fileManager.moveItem(at: pending, to: modelDir)
        print("ModelManager: installed model to \(modelDir.path)")
        progress?(1.0)

        // cleanup tmp
        try? fileManager.removeItem(at: downloadDir)

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

    private func validateArchiveLooksLikeZip(at archive: URL, source: URL) throws {
        let data = try Data(contentsOf: archive)
        guard data.count >= 4 else {
            throw ModelManagerError.validationFailed("Downloaded file is too small to be a valid zip: \(source.absoluteString)")
        }

        let zipSignatures: [[UInt8]] = [
            [0x50, 0x4B, 0x03, 0x04],
            [0x50, 0x4B, 0x05, 0x06],
            [0x50, 0x4B, 0x07, 0x08]
        ]

        let header = Array(data.prefix(4))
        if zipSignatures.contains(header) {
            return
        }

        let preview = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
        throw ModelManagerError.validationFailed(
            "Downloaded content is not a zip archive for URL: \(source.absoluteString). First bytes preview: \(preview)"
        )
    }
}
