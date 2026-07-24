import Foundation
import CryptoKit
#if canImport(ZIPFoundation)
import ZIPFoundation
#endif

/// Robust download-on-first-run ModelManager.
/// - Downloads a zip from a configured URL, verifies SHA256 (if provided), and extracts into Application Support.
/// - Uses an atomic install pattern: download -> verify -> unpack into temp -> move into models folder.
// Networking + file I/O only — nothing here touches UI state, so it must not inherit the
// project's default main-actor isolation. Staying nonisolated lets the concurrent download
// task group run its file moves off the main thread (and silences the Swift 6 isolation
// warnings that main-actor inheritance would otherwise raise for those off-actor closures).
nonisolated public final class ModelManager {
    public static let shared = ModelManager()
    private init() {}

    private let fileManager = FileManager.default

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
        let resolvedRepoID = repoID ?? modelName
        return modelsRoot.appendingPathComponent(resolvedRepoID.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }

    private func directoryContains(_ directory: URL, where predicate: (URL) -> Bool) -> Bool {
        guard let enumerator = fileManager.enumerator(at: directory,
                                                      includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else {
            return false
        }

        for case let fileURL as URL in enumerator where predicate(fileURL) {
            return true
        }
        return false
    }

    private func containsFile(in directory: URL, named fileName: String) -> Bool {
        directoryContains(directory) { $0.lastPathComponent.lowercased() == fileName.lowercased() }
    }

    private func containsAnyFile(withExtensions extensions: Set<String>, in directory: URL) -> Bool {
        directoryContains(directory) { extensions.contains($0.pathExtension.lowercased()) }
    }

    private func applyAuth(_ token: String?, to request: inout URLRequest) {
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Whether a complete, valid copy of the model already exists locally. The model
    /// picker uses this to tell the user if selecting a model loads from disk or
    /// triggers a multi-GB download.
    public func isModelDownloaded(repoID: String) -> Bool {
        guard let directory = try? localModelDirectory(modelName: repoID, repoID: repoID) else {
            return false
        }
        return isValidLocalModelDirectory(directory)
    }

    /// On-disk location of a model's files. Callers use this to load a model that
    /// `isModelDownloaded(repoID:)` has already confirmed is present, without re-running the
    /// download path. The URL is returned regardless of whether the directory exists yet.
    public func localModelURL(repoID: String) throws -> URL {
        try localModelDirectory(modelName: repoID, repoID: repoID)
    }

    private func isValidLocalModelDirectory(_ directory: URL) -> Bool {
        guard fileManager.fileExists(atPath: directory.path) else { return false }

        let hasConfig = containsFile(in: directory, named: "config.json")
        let hasTokenizer = containsFile(in: directory, named: "tokenizer.json") || containsFile(in: directory, named: "tokenizer.model")
        let hasWeights = containsAnyFile(withExtensions: ["safetensors", "bin", "gguf"], in: directory)

        return hasConfig && hasTokenizer && hasWeights && hasChatTemplate(in: directory)
    }

    /// Whether a chat template is present, in either of the two forms a repo can ship it:
    ///   • a standalone `chat_template.jinja` file (Qwen 3.5, Qwen 2.5-VL, newer exports), or
    ///   • a `chat_template` key inside `tokenizer_config.json` (Qwen 2.5, Llama 3.2, Phi, …).
    /// Without one, container.prepare throws "This tokenizer does not have a chat template."
    /// at generation time — so a directory missing it is incomplete and must be re-downloaded.
    /// This retroactively invalidates copies fetched before `.jinja` was an allowed download
    /// extension, forcing a clean re-fetch that now includes the template file.
    private func hasChatTemplate(in directory: URL) -> Bool {
        if containsFile(in: directory, named: "chat_template.jinja") { return true }

        let tokenizerConfig = directory.appendingPathComponent("tokenizer_config.json")
        guard let data = try? Data(contentsOf: tokenizerConfig),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        return json["chat_template"] != nil
    }

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

        let resolvedRepoID = repoID ?? modelName
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
            if let free = insufficientDiskSpace(at: support, requiredBytes: requiredMin) {
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
                applyAuth(authToken, to: &request)

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
            let actual = try sha256Hex(of: tempArchive)
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
        applyAuth(authToken, to: &request)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ModelManagerError.httpError(code: http.statusCode)
        }

        let modelInfo = try JSONDecoder().decode(HFModelInfo.self, from: data)
        let files = (modelInfo.siblings ?? []).map { $0.rfilename }
        // `jinja` is essential: newer models (Qwen 3.5, Qwen 2.5-VL) ship their chat template
        // as a standalone `chat_template.jinja` file rather than embedding `chat_template`
        // inside tokenizer_config.json. Omitting it downloads a model whose tokenizer has no
        // chat template, so container.prepare throws "This tokenizer does not have a chat
        // template." at generation time — every reply becomes an [MLX error].
        let allowedExtensions = ["json", "safetensors", "model", "txt", "md", "tiktoken", "jinja"]
        let downloadableFiles = files.filter { filename in
            let lower = filename.lowercased()
            return allowedExtensions.contains(where: { lower.hasSuffix(".\($0)") })
        }

        guard !downloadableFiles.isEmpty else {
            try? fileManager.removeItem(at: downloadDir)
            throw ModelManagerError.repositoryLookupFailed
        }

        // Disk-space guard (the archive path had one; this path did not). Estimate from the
        // HF sibling sizes when available, with headroom; otherwise fall back to a floor.
        let estimatedBytes = (modelInfo.siblings ?? [])
            .filter { downloadableFiles.contains($0.rfilename) }
            .reduce(Int64(0)) { $0 + Int64($1.size ?? 0) }
        let requiredBytes = max(Int64(Double(estimatedBytes) * 1.3), 800_000_000)
        if let free = insufficientDiskSpace(at: downloadDir, requiredBytes: requiredBytes) {
            try? fileManager.removeItem(at: downloadDir)
            throw ModelManagerError.validationFailed("Not enough free disk space: \(free) < \(requiredBytes)")
        }

        try fileManager.createDirectory(at: modelDir, withIntermediateDirectories: true, attributes: nil)

        // Weight each file's progress contribution by its byte size (falling back to an equal
        // split when HF omits sizes) so the reported fraction tracks real bytes, not file count.
        // Otherwise the multi-GB weights file is just "1 of N" and the UI sits frozen for minutes.
        let sizeByFilename: [String: Int64] = (modelInfo.siblings ?? []).reduce(into: [:]) { acc, sibling in
            if let size = sibling.size { acc[sibling.rfilename] = Int64(size) }
        }
        let knownTotalBytes = downloadableFiles.reduce(Int64(0)) { $0 + (sizeByFilename[$1] ?? 0) }
        let useByteWeighting = knownTotalBytes > 0
        let totalUnits: Double = useByteWeighting ? Double(knownTotalBytes) : Double(downloadableFiles.count)

        // Download files concurrently rather than one-at-a-time. An MLX repo is a few large
        // weight shards plus many tiny JSON/tokenizer files; serializing them means each
        // request's round-trip latency stacks. A bounded group overlaps them without opening
        // an unbounded number of sockets (which would thrash memory and starve each transfer
        // of bandwidth). Progress from all in-flight files is summed through a shared,
        // lock-guarded tracker so the reported fraction still moves smoothly and monotonically.
        let progressTracker = DownloadProgressTracker(totalUnits: totalUnits, onProgress: progress)
        let maxConcurrent = 4

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = downloadableFiles.enumerated().makeIterator()
            var running = 0

            func addTask(index: Int, filename: String) {
                let fileUnits: Double = useByteWeighting ? Double(sizeByFilename[filename] ?? 0) : 1
                group.addTask {
                    try Task.checkCancellation()
                    let fileURL = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? filename)")!
                    var fileRequest = URLRequest(url: fileURL)
                    self.applyAuth(authToken, to: &fileRequest)

                    let (downloadedURL, response2) = try await self.downloadWithProgress(request: fileRequest) { fileFraction in
                        progressTracker.report(filename: filename, fileUnits: fileUnits, fileFraction: fileFraction)
                    }
                    if let http = response2 as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                        throw ModelManagerError.httpError(code: http.statusCode)
                    }

                    let destination = modelDir.appendingPathComponent(filename)
                    let destinationDir = destination.deletingLastPathComponent()
                    try self.fileManager.createDirectory(at: destinationDir, withIntermediateDirectories: true, attributes: nil)
                    if self.fileManager.fileExists(atPath: destination.path) {
                        try? self.fileManager.removeItem(at: destination)
                    }
                    try self.fileManager.moveItem(at: downloadedURL, to: destination)

                    progressTracker.complete(filename: filename, fileUnits: fileUnits)
                    print("ModelManager: downloaded \(filename) [\(index + 1)/\(downloadableFiles.count)]")
                }
            }

            // Prime the group up to the concurrency cap, then refill one task each time one
            // finishes — so at most `maxConcurrent` transfers are ever in flight.
            while running < maxConcurrent, let (index, filename) = iterator.next() {
                addTask(index: index, filename: filename)
                running += 1
            }
            while running > 0 {
                try await group.next()
                running -= 1
                if let (index, filename) = iterator.next() {
                    addTask(index: index, filename: filename)
                    running += 1
                }
            }
        }

        print("ModelManager: installed community repo files at \(modelDir.path)")
        progress?(1.0)
        try? fileManager.removeItem(at: downloadDir)
    }

    /// Thread-safe aggregator for concurrent per-file download progress. Each in-flight file
    /// reports its own 0...1 fraction; this sums the byte-weighted contributions across all
    /// files into a single overall fraction. Guarded by a lock because the download tasks run
    /// on different threads and report simultaneously. Reports are clamped to be monotonic so
    /// the bar never jumps backward when one file's callback lands after another's.
    private final class DownloadProgressTracker: @unchecked Sendable {
        private let totalUnits: Double
        private let onProgress: ((Double) -> Void)?
        private let lock = NSLock()
        private var completedUnits: Double = 0
        private var inFlight: [String: Double] = [:]  // filename -> byte-units done so far
        private var lastReported: Double = -1

        init(totalUnits: Double, onProgress: ((Double) -> Void)?) {
            self.totalUnits = totalUnits
            self.onProgress = onProgress
        }

        func report(filename: String, fileUnits: Double, fileFraction: Double) {
            emit { self.inFlight[filename] = fileUnits * min(max(fileFraction, 0), 1) }
        }

        func complete(filename: String, fileUnits: Double) {
            emit {
                self.inFlight[filename] = nil
                self.completedUnits += fileUnits
            }
        }

        private func emit(_ mutate: () -> Void) {
            guard let onProgress, totalUnits > 0 else { return }
            let overall: Double = {
                lock.lock(); defer { lock.unlock() }
                mutate()
                let raw = (completedUnits + inFlight.values.reduce(0, +)) / totalUnits
                let clamped = min(max(raw, 0), 1)
                guard clamped > lastReported else { return -1 }
                lastReported = clamped
                return clamped
            }()
            if overall >= 0 { onProgress(overall) }
        }
    }

    /// Downloads a request while reporting real byte-level progress (0.0...1.0 of this file).
    /// Mirrors `URLSession.download(for:)`'s return shape: (temp file URL, response). A
    /// `URLSessionDownloadTask` streams the body to disk in the networking layer — no bytes
    /// are held in memory — and its delegate reports progress as data arrives, so the caller
    /// sees movement within a multi-GB weights file instead of a single jump at completion.
    /// Progress stays silent when the server omits Content-Length; the file still completes.
    private func downloadWithProgress(request: URLRequest,
                                      onProgress: @escaping (Double) -> Void) async throws -> (URL, URLResponse) {
        let delegate = ProgressDownloadDelegate(onProgress: onProgress)
        // Bridge the delegate callback (temp file is deleted the moment the delegate returns)
        // into async/await by copying the file out synchronously inside the delegate.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: request)
                delegate.task = task
                task.resume()
            }
        } onCancel: {
            delegate.task?.cancel()
        }
    }

    /// Delegate that forwards download progress and hands the finished temp file back through a
    /// continuation. It moves the file to its own temp URL inside `didFinishDownloadingTo`
    /// because the URL provided there is deleted as soon as the delegate method returns.
    // @unchecked Sendable: URLSession serializes all delegate callbacks for a given task onto
    // its delegate queue, so the mutable members (lastReported/continuation/didResume) are
    // never touched concurrently despite not being lock-guarded.
    private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: (Double) -> Void
        private var lastReported: Double = -1
        var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        weak var task: URLSessionDownloadTask?
        private var didResume = false

        init(onProgress: @escaping (Double) -> Void) {
            self.onProgress = onProgress
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            guard totalBytesExpectedToWrite > 0 else { return }
            let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            // Throttle to ~1% steps so the callback doesn't flood.
            if fraction - lastReported >= 0.01 {
                lastReported = fraction
                onProgress(min(fraction, 1))
            }
        }

        func urlSession(_ session: URLSession,
                        downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let response = downloadTask.response ?? URLResponse()
            let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            do {
                try FileManager.default.moveItem(at: location, to: destination)
                resume(returning: (destination, response))
            } catch {
                resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            // Only surfaces failures; success is delivered from didFinishDownloadingTo.
            if let error { resume(throwing: error) }
            session.invalidateAndCancel()
        }

        private func resume(returning value: (URL, URLResponse)) {
            guard !didResume else { return }
            didResume = true
            continuation?.resume(returning: value)
            continuation = nil
        }

        private func resume(throwing error: Error) {
            guard !didResume else { return }
            didResume = true
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }

    /// Whether there is enough free space at `url` for an estimated download of `requiredBytes`.
    /// Returns the available byte count when under budget so callers can report it.
    private func insufficientDiskSpace(at url: URL, requiredBytes: Int64) -> Int? {
        guard let free = freeDiskSpace(at: url) else { return nil }
        return Int64(free) < requiredBytes ? free : nil
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
        // Read only the first 200 bytes — never load a multi-GB archive into memory just to
        // sniff its 4-byte magic number.
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 200)) ?? Data()

        guard head.count >= 4 else {
            throw ModelManagerError.validationFailed("Downloaded file is too small to be a valid zip: \(source.absoluteString)")
        }

        let zipSignatures: [[UInt8]] = [
            [0x50, 0x4B, 0x03, 0x04],
            [0x50, 0x4B, 0x05, 0x06],
            [0x50, 0x4B, 0x07, 0x08]
        ]

        let header = Array(head.prefix(4))
        if zipSignatures.contains(header) {
            return
        }

        let preview = String(data: head, encoding: .utf8) ?? "<binary>"
        throw ModelManagerError.validationFailed(
            "Downloaded content is not a zip archive for URL: \(source.absoluteString). First bytes preview: \(preview)"
        )
    }

    /// Streaming SHA-256 so a large archive is hashed in 1 MB chunks instead of being read
    /// fully into RAM.
    private func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
