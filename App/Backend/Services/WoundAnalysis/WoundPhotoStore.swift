import Foundation

/// Persists analyzed wound photos to disk and returns a stable file URL for a `WoundLogEntry`
/// to reference. Chat attachments are stored as inline blobs, but the wound log is meant to be a
/// long-lived clinical history browsed over time, so its images live as files in Application
/// Support (excluded from the chat's SwiftData store) referenced by `WoundLogEntry.imageReference`.
enum WoundPhotoStore {

    enum StoreError: Error {
        case couldNotLocateDirectory
    }

    /// `Application Support/WoundPhotos`. Created on demand. Application Support (not Caches) so
    /// the OS won't evict a patient's wound history under storage pressure.
    private static func directory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StoreError.couldNotLocateDirectory
        }
        let dir = base.appendingPathComponent("WoundPhotos", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Writes `jpegData` to a new file named after `id` and returns its URL. Naming the file
    /// after the entry id keeps photo and log entry in lockstep, so `delete` can find the file
    /// from the entry alone.
    static func save(jpegData: Data, id: UUID) throws -> URL {
        let url = try directory().appendingPathComponent("\(id.uuidString).jpg", isDirectory: false)
        try jpegData.write(to: url, options: .atomic)
        return url
    }

    /// Removes the photo file backing an entry, if present. Missing files are ignored — deletion
    /// should be idempotent and must not fail just because the file was already gone.
    static func delete(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
