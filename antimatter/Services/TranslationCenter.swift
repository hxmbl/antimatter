import Foundation
import NaturalLanguage
import Translation

/// On-device translation for the inline `.translate` command.
///
/// The system's `Translation` framework owns the language packs, so the app
/// does not ship or download its own models. Source language is detected with
/// `NaturalLanguage`; the target is the user's first preferred system
/// language, which is what "translate into my language" means in the pane.
@MainActor
final class TranslationCenter {
    static let shared = TranslationCenter()

    enum Failure: LocalizedError {
        case noText
        case undeterminedSource
        case alreadyInSystemLanguage(String)
        case unsupported(source: String, target: String)
        case emptyResult

        var errorDescription: String? {
            switch self {
            case .noText:
                "There's no text to translate."
            case .undeterminedSource:
                "Couldn't tell what language that text is in."
            case .alreadyInSystemLanguage(let language):
                "This text is already in \(language)."
            case .unsupported(let source, let target):
                "Translation from \(source) to \(target) isn't available."
            case .emptyResult:
                "Translation came back empty."
            }
        }
    }

    /// The language new translations land in: the first system-preferred
    /// language, not the region-formatted `Locale.current` identifier.
    nonisolated static var systemLanguage: Locale.Language {
        Locale.Language(identifier: Locale.preferredLanguages.first ?? Locale.current.identifier)
    }

    /// Human-readable name for the system language, used by the return-key
    /// preview and notices. Falls back to the identifier if the system has no
    /// localized name for it.
    nonisolated static var systemLanguageName: String {
        let identifier = Locale.preferredLanguages.first ?? Locale.current.identifier
        return Locale.current.localizedString(forIdentifier: identifier) ?? identifier
    }

    func translate(_ text: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noText }

        guard let language = NLLanguageRecognizer.dominantLanguage(for: trimmed),
              language != .undetermined
        else {
            throw Failure.undeterminedSource
        }
        let identifier = language.rawValue
        let source = Locale.Language(identifier: identifier)
        let target = Self.systemLanguage

        if source.languageCode == target.languageCode {
            throw Failure.alreadyInSystemLanguage(Self.systemLanguageName)
        }

        let availability = LanguageAvailability()
        let status = await availability.status(from: source, to: target)
        guard status != .unsupported else {
            let sourceName = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
            throw Failure.unsupported(source: sourceName, target: Self.systemLanguageName)
        }

        let session = TranslationSession(installedSource: source, target: target)
        // `.supported` means the pair can be translated but the pack is not on
        // disk yet. Preparing lets the system offer the download before the
        // first string is sent through.
        if status == .supported {
            try await session.prepareTranslation()
        }
        let response = try await session.translate(trimmed)
        let result = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { throw Failure.emptyResult }
        return result
    }
}
