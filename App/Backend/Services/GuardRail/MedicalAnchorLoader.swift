import Foundation
import ZIPFoundation

/// Downloads the Kaggle "medical-text" dataset to the device's temp directory on first run,
/// extracts representative medical anchor phrases, and caches them as JSON for subsequent
/// launches. Falls back to a built-in phrase set when credentials are missing or the network
/// is unavailable.
///
/// Prerequisites
/// ─────────────
/// 1. ZipFoundation SPM package (https://github.com/weichsel/ZIPFoundation, tag ≥ 0.9.19)
///    Add via Xcode → File → Add Package Dependencies.
/// 2. Kaggle API credentials stored in AppConfig:
///      AppConfig.kaggleUsername = "<your-kaggle-username>"
///      AppConfig.kaggleApiKey   = "<your-kaggle-api-key>"
///    Obtain a key at kaggle.com → Account → API → Create New Token.
actor MedicalAnchorLoader {

    static let shared = MedicalAnchorLoader()

    private let datasetOwner  = "chaitanyakck"
    private let datasetSlug   = "medical-text"
    private let targetFile    = "train.dat"
    private let cacheFilename = "medical_anchors.json"

    // InputGuardRail only ever consults the first ~50 anchors (and only on a keyword miss),
    // so parsing/caching hundreds is wasted work — keep a small buffer above that.
    private let maxAnchors   = 60
    private let maxWordCount = 12
    private let minWordCount = 4

    // MARK: - Temp-directory URLs

    private var zipURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(datasetSlug).zip")
    }

    private var cacheURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(cacheFilename)
    }

    // MARK: - Public API

    /// Returns medical anchor phrases, loading from disk-cache, Kaggle, or built-in fallback
    /// in that priority order.
    func load(username: String, apiKey: String) async -> [String] {
        if let cached = loadFromCache() {
            print("MedicalAnchorLoader: \(cached.count) anchors loaded from cache")
            return cached
        }

        guard !username.isEmpty, !apiKey.isEmpty else {
            print("MedicalAnchorLoader: Kaggle credentials not set — using built-in anchors")
            return Self.builtInAnchors
        }

        do {
            let anchors = try await downloadAndParse(username: username, apiKey: apiKey)
            saveToCache(anchors)
            print("MedicalAnchorLoader: \(anchors.count) anchors downloaded and cached ✓")
            return anchors
        } catch {
            print("MedicalAnchorLoader: \(error.localizedDescription) — using built-in anchors")
            return Self.builtInAnchors
        }
    }

    // MARK: - Disk Cache

    private func loadFromCache() -> [String]? {
        guard FileManager.default.fileExists(atPath: cacheURL.path),
              let data    = try? Data(contentsOf: cacheURL),
              let anchors = try? JSONDecoder().decode([String].self, from: data),
              !anchors.isEmpty else { return nil }
        return anchors
    }

    private func saveToCache(_ anchors: [String]) {
        guard let data = try? JSONEncoder().encode(anchors) else { return }
        try? data.write(to: cacheURL, options: .atomic)
    }

    // MARK: - Download Pipeline

    private func downloadAndParse(username: String, apiKey: String) async throws -> [String] {
        if !FileManager.default.fileExists(atPath: zipURL.path) {
            try await downloadZip(username: username, apiKey: apiKey)
        }
        let text    = try extractDatFile(from: zipURL)
        let anchors = parseAnchors(from: text)
        guard !anchors.isEmpty else { throw LoaderError.emptyDataset }
        return anchors
    }

    private func downloadZip(username: String, apiKey: String) async throws {
        guard let url = URL(string:
            "https://www.kaggle.com/api/v1/datasets/download/\(datasetOwner)/\(datasetSlug)")
        else { throw LoaderError.invalidURL }

        var request = URLRequest(url: url, timeoutInterval: 120)
        let token = Data("\(username):\(apiKey)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")

        print("MedicalAnchorLoader: downloading dataset from Kaggle (this may take a moment)…")
        let (tmpURL, response) = try await URLSession.shared.download(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LoaderError.httpError(code)
        }

        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try FileManager.default.moveItem(at: tmpURL, to: zipURL)
        print("MedicalAnchorLoader: ZIP saved to \(zipURL.lastPathComponent)")
    }

    // MARK: - ZIP Extraction

    private func extractDatFile(from zipURL: URL) throws -> String {
        guard let archive = Archive(url: zipURL, accessMode: .read) else {
            throw LoaderError.zipOpenFailed
        }
        guard let entry = archive.first(where: {
            $0.path == targetFile || $0.path.hasSuffix("/\(targetFile)")
        }) else {
            throw LoaderError.fileNotFound(targetFile)
        }

        var buffer = Data()
        _ = try archive.extract(entry) { buffer.append($0) }

        guard let text = String(data: buffer, encoding: .utf8) else {
            throw LoaderError.encodingError
        }
        return text
    }

    // MARK: - Anchor Parsing

    /// Extracts short medical phrases from the dataset.
    /// Format per line: optional integer label followed by the medical text.
    private func parseAnchors(from text: String) -> [String] {
        var seen   = Set<String>()
        var result = [String]()

        for line in text.components(separatedBy: .newlines) {
            guard result.count < maxAnchors else { break }

            var words = line
                .trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ")
                .filter { !$0.isEmpty }

            if let first = words.first, Int(first) != nil { words.removeFirst() }
            guard words.count >= minWordCount else { continue }

            let phrase = words
                .prefix(maxWordCount)
                .joined(separator: " ")
                .lowercased()
                .trimmingCharacters(in: .punctuationCharacters)

            guard !phrase.isEmpty, seen.insert(phrase).inserted else { continue }
            result.append(phrase)
        }
        return result
    }

    // MARK: - Errors

    enum LoaderError: Error, LocalizedError {
        case invalidURL
        case httpError(Int)
        case zipOpenFailed
        case fileNotFound(String)
        case encodingError
        case emptyDataset

        var errorDescription: String? {
            switch self {
            case .invalidURL:          return "Invalid Kaggle API URL"
            case .httpError(let code): return "HTTP \(code) from Kaggle — verify credentials and dataset access"
            case .zipOpenFailed:       return "Could not open ZIP archive — ensure ZipFoundation is linked"
            case .fileNotFound(let f): return "'\(f)' not found inside the downloaded ZIP"
            case .encodingError:       return "Dataset file is not valid UTF-8 text"
            case .emptyDataset:        return "No anchor phrases could be extracted from the dataset"
            }
        }
    }

    // MARK: - Built-in Fallback Anchors

    static let builtInAnchors: [String] = [
        "patient presents with fever and chills",
        "postoperative wound care and infection prevention",
        "symptoms of bacterial and viral infection",
        "medication dosage and administration guidelines",
        "surgical site infection signs and treatment",
        "blood pressure monitoring and hypertension management",
        "pain management after surgical procedure",
        "nausea and vomiting treatment options",
        "diabetes mellitus management and care",
        "heart disease symptoms and risk factors",
        "respiratory difficulty and breathing treatment",
        "kidney function tests and renal disease",
        "liver disease diagnosis and management",
        "cancer screening and early detection",
        "antibiotic therapy for bacterial infections",
        "wound healing recovery and rehabilitation",
        "physical therapy exercises after surgery",
        "nutrition and dietary guidance for recovery",
        "emergency symptoms requiring immediate care",
        "chronic disease long-term management plan",
        "gastrointestinal symptoms diagnosis and treatment",
        "neurological symptoms nervous system disorders",
        "cardiovascular disease prevention and treatment",
        "immune system response to infection",
        "inflammatory conditions symptoms and management",
        "drug interactions and contraindications safety",
        "laboratory test results and interpretation",
        "patient discharge instructions and follow-up care",
        "fever reduction methods and when to seek care",
        "post-operative complications and warning signs"
    ]
}
