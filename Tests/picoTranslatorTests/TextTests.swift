import CoreGraphics
import Foundation
import Testing
@testable import picoTranslator

/// What Translation's fast models support (`LanguageAvailability().supportedLanguages`).
let supported = ["ar-AE", "de", "en", "en-GB", "es", "fr", "hi", "id", "it", "ja", "ko", "nl", "pl", "pt", "ru", "th", "tr",
                 "uk", "vi", "zh", "zh-TW"].map { Locale.Language(identifier: $0) }

func detected(_ text: String) -> String? {
    switch Translator.detect(text, among: supported, preferred: ["en-CA", "zh-Hans-CA"]) {
    case .language(let l): Translator.nlLanguage(l).rawValue
    case .unsupported(let l): "unsupported:" + (l.languageCode?.identifier ?? "?")
    case .unknown: nil
    }
}

@Suite struct Detection {
    @Test(arguments: [
        ("picoTranslator真的非常轻", "zh-Hans"), ("用picoTranslator翻译这段文字", "zh-Hans"), ("iPhone 16 Pro的电池续航怎么样", "zh-Hans"),
        ("请把这个PR merge到main分支", "zh-Hans"), ("今日はiPhoneを買いました", "ja"), ("東京駅", "ja"),
        ("Apple Watch 사용법을 알려주세요", "ko"),
    ])
    func cjkWithLatinNames(text: String, language: String) { #expect(detected(text) == language) }

    @Test(arguments: [
        "I visited 東京 last summer and the food was amazing, highly recommend it to everyone.",
        "English | 简体中文 | 日本語\nWelcome to our documentation. Read the getting started guide below.",
        "Order #4471 shipped. Questions? Contact support. 客服",
        "Download the app today.\n下载",
        "Meeting with 王伟 tomorrow",
    ])
    func latinWithSomeCJK(text: String) { #expect(detected(text) == "en") }

    @Test(arguments: [("Hola, ¿cómo estás?", "es"), ("Привет, как дела?", "ru"), ("Obrigado pela ajuda", "pt"),
                      ("Danke schön", "de"), ("ok", "en"), ("hi", "en")])
    func otherLanguages(text: String, language: String) { #expect(detected(text) == language) }

    /// Short words that unlimited detection reads as other languages must still not be refused.
    @Test(arguments: ["Gift", "API", "iPhone", "merci", "Bonjour", "Salut", "OK!", "Thanks", "no", "fin", "Hello world",
                      "Ciao", "Hej", "Tak", "Ich bin müde", "Sale", "Information", "Taxi", "Hotel"])
    func shortWordsAreNotRefused(text: String) { #expect(detected(text)?.hasPrefix("unsupported:") != true) }

    @Test(arguments: ["Tack så mycket för hjälpen, vi ses i morgon", "Γεια σου, τι κάνεις σήμερα;", "Kiitos", "Jeg er træt"])
    func unsupportedLanguagesAreNamed(text: String) { #expect(detected(text)?.hasPrefix("unsupported:") == true) }
}

@Suite struct Targets {
    let en = Locale.Language(identifier: "en"), zh = Locale.Language(identifier: "zh-Hans"), fr = Locale.Language(identifier: "fr")

    @Test func requestedTargetIsUsed() {
        let r = Translator.resolve(fr, for: en)
        #expect(r.target == fr && !r.fellBack)
    }

    @Test func sameLanguageFallsBack() {
        let r = Translator.resolve(Locale.Language(identifier: "en-GB"), for: en)
        #expect(r.fellBack && r.target.map { !Translator.same($0, en) } == true)
    }

    @Test func simplifiedAndTraditionalDiffer() {
        #expect(!Translator.same(zh, Locale.Language(identifier: "zh-Hant")))
        #expect(Translator.same(zh, Locale.Language(identifier: "zh")))
    }
}

@Suite struct ParagraphJoining {
    /// Lines of 20-px text with a 6-px gap, top to bottom, starting at the same x unless given.
    func lines(_ texts: [(String, CGFloat)], x: CGFloat = 10, gap: CGFloat = 6) -> [Paragraphs.Line] {
        texts.enumerated().map { i, t in
            Paragraphs.Line(text: t.0, box: CGRect(x: x, y: 1000 - CGFloat(i) * (20 + gap), width: t.1, height: 20))
        }
    }

    @Test func wrappedSentenceBecomesOneLine() {
        let text = Paragraphs.join(lines([("The meeting has been moved to", 400), ("Thursday because of the holiday,", 410),
                                          ("so please update your calendar.", 300)]))
        #expect(text == "The meeting has been moved to Thursday because of the holiday, so please update your calendar.")
    }

    @Test func shortLastLineEndsTheParagraph() {
        let text = Paragraphs.join(lines([("A paragraph that wraps onto", 400), ("a short last line.", 150),
                                          ("Then the next paragraph starts", 400)]))
        #expect(text == "A paragraph that wraps onto a short last line.\nThen the next paragraph starts")
    }

    @Test func bigGapEndsTheParagraph() {
        #expect(Paragraphs.join(lines([("Title of the article here", 400), ("First line of the body text", 400)], gap: 30))
            == "Title of the article here\nFirst line of the body text")
    }

    @Test func listItemsStaySeparate() {
        #expect(Paragraphs.join(lines([("• First item in the list", 400), ("• Second item in the list", 400)]))
            == "• First item in the list\n• Second item in the list")
    }

    @Test func chineseJoinsWithoutSpaces() {
        #expect(Paragraphs.join(lines([("会议已经改到星期四，因为", 400), ("假期的缘故。", 200)])) == "会议已经改到星期四，因为假期的缘故。")
    }

    @Test func hyphenatedWordIsRejoined() {
        #expect(Paragraphs.join(lines([("This is an extraordi-", 400), ("narily long word.", 200)])) == "This is an extraordinarily long word.")
    }

    @Test func differentColumnsStaySeparate() {
        let a = Paragraphs.Line(text: "Left column", box: CGRect(x: 10, y: 1000, width: 200, height: 20))
        let b = Paragraphs.Line(text: "Right column", box: CGRect(x: 500, y: 974, width: 200, height: 20))
        #expect(Paragraphs.join([a, b]) == "Left column\nRight column")
    }
}

@Suite struct Shortcuts {
    func shortcut(_ key: Int, _ mods: Int) -> Shortcut { Shortcut(key: UInt32(key), mods: UInt32(mods), label: "") }

    @Test func menuShortcutsAreRefused() {
        #expect(shortcut(13, 0x100).clashesWithMenus)          // ⌘W  (kVK_ANSI_W = 13, cmdKey = 0x100)
        #expect(shortcut(1, 0x100 | 0x200).clashesWithMenus)   // ⌘⇧S (shiftKey = 0x200)
        #expect(!shortcut(1, 0x100 | 0x800).clashesWithMenus)  // ⌘⌥S (optionKey = 0x800)
        #expect(!shortcut(96, 0x100).clashesWithMenus)         // ⌘F5 (kVK_F5 = 96)
        #expect(!Shortcut.defaults[0].clashesWithMenus)
    }
}

@Suite struct PopoverPlacement {
    /// The text's bounds come from Vision (fractions of the image, from the bottom left), the area is in
    /// AppKit screen points (also from the bottom left), so they map straight across, plus a small margin.
    @Test func boxAroundTheText() {
        let area = CGRect(x: 100, y: 200, width: 400, height: 100)
        #expect(Capture.rect(of: CGRect(x: 0, y: 0, width: 1, height: 1), in: area) == CGRect(x: 98, y: 196, width: 404, height: 108))
        // Text in the top-left quarter of the selection.
        #expect(Capture.rect(of: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5), in: area) == CGRect(x: 98, y: 246, width: 204, height: 58))
    }
}
