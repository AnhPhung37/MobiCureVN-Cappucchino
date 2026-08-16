import Foundation

/// Stamps a data-protection class onto the SwiftData store, so the chat history, wound log,
/// and patient profile it holds are encrypted by the OS while the device is locked.
///
/// SwiftData has no equivalent of Core Data's `NSPersistentStoreFileProtectionKey` —
/// `ModelConfiguration` exposes no protection option at all — so the class is applied to the
/// store's files directly, immediately after the container opens.
///
/// `.completeUnlessOpen` is the right class for a database the app holds open across the
/// lifetime of the process: a handle already open when the device locks keeps working (so a
/// chat turn writing mid-lock isn't killed), while a locked device cannot open the file fresh.
enum StoreFileProtection {

    /// Applies `level` to the store at `storeURL` and everything that holds its data alongside it.
    ///
    /// Best-effort by design: failing to raise the protection class is worth a warning, but it
    /// must not stop the app from opening its own store — the alternative is a patient locked
    /// out of their care history.
    static func apply(_ level: FileProtectionType = .completeUnlessOpen, toStoreAt storeURL: URL?) {
#if canImport(UIKit)
        guard let storeURL else {
            print("StoreFileProtection: container reported no store URL — protection NOT applied")
            return
        }

        let fileManager = FileManager.default
        for url in targets(for: storeURL) where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.setAttributes([.protectionKey: level], ofItemAtPath: url.path)
            } catch {
                print("StoreFileProtection: could not protect \(url.lastPathComponent) — \(error)")
            }
        }
#endif
    }

    /// The store file plus every sibling that holds the same patient data:
    ///
    /// - `-wal` / `-shm`: SQLite runs in WAL mode, so recent writes live in the write-ahead log
    ///   until a checkpoint folds them into the store. An unprotected WAL leaks exactly the most
    ///   recent conversation.
    /// - `.<store>_SUPPORT`: where Core Data spills `.externalStorage` blobs — for this schema,
    ///   the patient's profile photo. Stamping the directory also means blobs written later
    ///   inherit the class, since a new file takes the protection class of its parent directory.
    private static func targets(for storeURL: URL) -> [URL] {
        let directory = storeURL.deletingLastPathComponent()
        let name = storeURL.lastPathComponent
        let supportDirectory = directory.appendingPathComponent(".\(name)_SUPPORT", isDirectory: true)

        return [
            storeURL,
            directory.appendingPathComponent("\(name)-wal"),
            directory.appendingPathComponent("\(name)-shm"),
            supportDirectory
        ] + existingBlobs(in: supportDirectory)
    }

    /// External-storage blobs already on disk. Directory inheritance only covers files created
    /// *after* the directory is stamped, so anything written before this shipped needs stamping
    /// individually — otherwise an existing profile photo stays at the old class forever.
    private static func existingBlobs(in supportDirectory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: supportDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
    }
}
