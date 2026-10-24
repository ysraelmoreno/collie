import Foundation
import NaturalLanguage

/// A sentence vector for memory search, on-device only. nil: a language with no model (search is bm25 only).
protocol MemoryEmbedder: Sendable {
    func embed(_ text: String) -> (lang: String, vector: [Float])?
}

/// `NLEmbedding.sentenceEmbedding` for Portuguese and English (the language guessed by `NLLanguageRecognizer`, constrained
/// to those two); each model is loaded once, on first use. A model missing on this Mac → nil, never an error.
struct NLMemoryEmbedder: MemoryEmbedder {
    private final class Models: @unchecked Sendable {   // `lock` guards `loaded` and every NLEmbedding call
        let lock = NSLock()
        var loaded: [NLLanguage: NLEmbedding?] = [:]
    }
    private let models = Models()

    init() {}

    func embed(_ text: String) -> (lang: String, vector: [Float])? {
        let r = NLLanguageRecognizer()
        r.languageConstraints = [.portuguese, .english]
        r.processString(text)
        guard let lang = r.dominantLanguage else { return nil }
        return models.lock.withLock {
            if models.loaded[lang] == nil { models.loaded[lang] = .some(NLEmbedding.sentenceEmbedding(for: lang)) }
            guard let model = models.loaded[lang] ?? nil, let v = model.vector(for: text) else { return nil }
            return (lang.rawValue, v.map(Float.init))
        }
    }
}
