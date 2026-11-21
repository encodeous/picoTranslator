import Foundation
import Testing
@testable import picoTranslator

/// Real translations through the system's translation service, so off by default: needs English and
/// Chinese downloaded. To check the cold-start fix, stop the service first, which macOS restarts on demand:
///
///     killall translationd; PICO_LIVE=1 swift test --filter LiveTranslation
@Suite(.enabled(if: ProcessInfo.processInfo.environment["PICO_LIVE"] != nil), .serialized)
struct LiveTranslation {
    let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans")

    @Test func firstTranslationAfterTheServiceStarts() async {
        let start = Date.now
        let r = await Translator.run("The quick brown fox jumps over the lazy dog.", from: en, to: zh, languages: supported)
        print("first translation: \(r.failed ? "FAILED" : "ok") in \(String(format: "%.2f", Date.now.timeIntervalSince(start))) s: \(r.text)")
        #expect(!r.failed, "\(r.text)")
    }

    @Test func textInAnotherLanguageThanTheSourceIsExplained() async {
        let r = await Translator.run("Please call me back tomorrow morning.", from: zh, to: en, languages: supported)
        print("pinned Chinese source on English text: \(r.text)")
        #expect(r.failed && r.text.contains(Translator.name(en)))
    }
}
