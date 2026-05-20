import Translation
import Foundation
import Combine

// MARK: - Error

enum TranslationError: LocalizedError {
    case sessionNotAvailable
    case languagePairNotSupported
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .sessionNotAvailable:
            return "Dịch vụ dịch thuật chưa sẵn sàng. Vui lòng thử lại. / " +
                   "Translation service not ready. Please try again."
        case .languagePairNotSupported:
            return "Thiết bị này chưa hỗ trợ dịch Việt↔Anh. Vui lòng cài đặt gói ngôn ngữ. / " +
                   "This device does not support Vietnamese↔English translation. Please install the language pack."
        case .translationFailed(let detail):
            return "Lỗi dịch thuật: \(detail) / Translation error: \(detail)"
        }
    }
}

// MARK: - TranslationService

// Wraps Apple's Translation framework (iOS 17.4+) for on-device vi↔en translation.
// Sessions are injected by the SwiftUI view via .translationTask() modifiers.
// All methods are @MainActor because TranslationSession is @MainActor.
@MainActor
final class TranslationService: ObservableObject {

    // nil = not yet checked; true/false = result of LanguageAvailability check
    @Published private(set) var languagePairSupported: Bool? = nil
    @Published private(set) var isReady = false
    // true while packs are queued for download but sessions haven't been injected yet
    @Published private(set) var isPreparingLanguagePacks = false

    private var viToEnSession: TranslationSession?
    private var enToViSession: TranslationSession?

    // MARK: - Static Configurations (used as .translationTask() arguments in the view)

    static let viToEnConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "vi"),
        target: Locale.Language(identifier: "en")
    )

    static let enToViConfiguration = TranslationSession.Configuration(
        source: Locale.Language(identifier: "en"),
        target: Locale.Language(identifier: "vi")
    )

    // MARK: - Session Injection (called from .translationTask action closures)

    func configure(viToEn session: TranslationSession) {
        viToEnSession = session
        updateReadiness()
        Task { try? await session.prepareTranslation() }
    }

    func configure(enToVi session: TranslationSession) {
        enToViSession = session
        updateReadiness()
        Task { try? await session.prepareTranslation() }
    }

    // MARK: - Language Availability (uses LanguageAvailability, not the session)

    func checkLanguageAvailability() async {
        let availability = LanguageAvailability()
        async let fwd = availability.status(
            from: Locale.Language(identifier: "vi"),
            to: Locale.Language(identifier: "en")
        )
        async let bwd = availability.status(
            from: Locale.Language(identifier: "en"),
            to: Locale.Language(identifier: "vi")
        )
        let (f, b) = await (fwd, bwd)
        languagePairSupported = (f == .installed || f == .supported) &&
                                (b == .installed || b == .supported)
        // Flag a download in progress if either pack still needs to be fetched
        if (f == .supported || b == .supported) && !isReady {
            isPreparingLanguagePacks = true
        }
    }

    // MARK: - Model Pre-warming

    func prepareModels() async {
        try? await viToEnSession?.prepareTranslation()
        try? await enToViSession?.prepareTranslation()
    }

    // MARK: - Translation

    func translateToEnglish(_ text: String) async throws -> String {
        guard let session = viToEnSession else {
            throw TranslationError.sessionNotAvailable
        }
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw TranslationError.translationFailed(error.localizedDescription)
        }
    }

    func translateToVietnamese(_ text: String) async throws -> String {
        guard let session = enToViSession else {
            throw TranslationError.sessionNotAvailable
        }
        do {
            let response = try await session.translate(text)
            return response.targetText
        } catch {
            throw TranslationError.translationFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func updateReadiness() {
        isReady = viToEnSession != nil && enToViSession != nil
        if isReady { isPreparingLanguagePacks = false }
    }
}
