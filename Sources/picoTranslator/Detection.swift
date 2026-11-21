import Foundation
import NaturalLanguage

extension Translator {
    enum Detection: Equatable {
        case language(Locale.Language)
        case unsupported(Locale.Language)  // clearly a language that Translation can't translate
        case unknown
    }

    /// Limited to the languages Translation supports (`supported`), and leaning toward the user's
    /// preferred languages, so short text like "hi" or "ok" isn't read as Catalan or Polish.
    static func detect(_ text: String, among supported: [Locale.Language],
                       preferred: [String] = Locale.preferredLanguages) -> Detection {
        let sample = detectionSample(text)
        let allowed = Set(supported.map(nlLanguage))
        // Limited to `allowed`, a language outside it would be read as the closest one inside, such as
        // Swedish as English, and then come back untranslated. So first look without limits.
        let open = NLLanguageRecognizer()
        open.processString(sample)
        if !allowed.isEmpty, let (language, p) = open.languageHypotheses(withMaximum: 1).first,
           p >= 0.9, !allowed.contains(language) {
            return .unsupported(Locale.Language(identifier: language.rawValue))
        }
        let r = NLLanguageRecognizer()
        let preferredSet = Set(preferred.map { nlLanguage(Locale.Language(identifier: $0)) })
        r.languageConstraints = Array(allowed)
        // Relative weights: every allowed language needs one, or it's as good as ruled out.
        r.languageHints = Dictionary(uniqueKeysWithValues: allowed.map { ($0, preferredSet.contains($0) ? 10 : 1) })
        r.processString(sample)
        guard let language = r.dominantLanguage, language != .undetermined else { return .unknown }
        return .language(Locale.Language(identifier: language.rawValue))
    }

    /// The text to judge the language by. Latin words outweigh Chinese, Japanese and Korean characters,
    /// so "picoTranslator真的非常轻" came out as Dutch: mixed in like that, Latin words are usually names,
    /// so judge by the other characters. But only when those are most of the text: in "I visited 東京
    /// last summer", or an English page with a "简体中文" link, it's the CJK that's mixed in. One CJK
    /// character counts about as much as one word of another script.
    static func detectionSample(_ text: String) -> String {
        let cjk = String(String.UnicodeScalarView(text.unicodeScalars.filter(isCJK)))
        let otherWords = text.split { !$0.isLetter }.filter { !$0.unicodeScalars.contains(where: isCJK) }.count
        return cjk.count >= 2 && cjk.count >= otherWords ? cjk : text
    }

    /// Chinese characters, Japanese kana and Korean Hangul syllables.
    static func isCJK(_ s: Unicode.Scalar) -> Bool {
        s.properties.isIdeographic || (0x3040...0x30FF).contains(s.value) || (0xAC00...0xD7AF).contains(s.value)
    }

    /// NaturalLanguage names Chinese by script (zh-Hans / zh-Hant); everything else by language code.
    static func nlLanguage(_ l: Locale.Language) -> NLLanguage {
        let code = l.languageCode?.identifier ?? ""
        guard code == "zh" else { return NLLanguage(code) }
        let traditional = l.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(l.region?.identifier ?? "")
        return NLLanguage(traditional ? "zh-Hant" : "zh-Hans")
    }
}
