import AppKit
import AVFoundation
import NaturalLanguage
import Translation

/// App state shared by the popover, the windows and the shortcuts.
@MainActor @Observable final class Model {
    var input = ""
    var output = ""
    var failed = false      // `output` is a message (an error, "no text found"…), not a translation
    var needsSetup = false  // the language pair still has to be downloaded
    var detected: Locale.Language?    // what "Detect Language" found
    var usedTarget: Locale.Language?  // what the last translation went into (shown for "Automatic")
    var reading = false  // reading text from a screenshot
    var translating = false
    var maxHeight: CGFloat = 520  // room on screen for the popover, set before it opens
    var split: CGFloat = 0.5  // the source text's share of the text areas; the user can drag the line between
    var languages: [Locale.Language] = []

    /// "" detects the source language. Saved only when the user picks it (`saveLanguages`), so a
    /// screenshot switching to detection doesn't overwrite their choice.
    var source = UserDefaults.standard.string(forKey: "source") ?? "" { didSet { translate() } }
    /// "" is automatic: the user's first preferred language that isn't the source (see `Translator`).
    var target = UserDefaults.standard.string(forKey: "target") ?? "" { didSet { translate() } }

    var shortcuts = (try? JSONDecoder().decode([Shortcut].self, from: UserDefaults.standard.data(forKey: "shortcuts") ?? Data()))
        ?? Shortcut.defaults {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts") }
    }
    var unavailableShortcuts: Set<Int> = []  // already taken by another app
    var recording: Int?  // the shortcut that's listening for new keys (see SettingsView.swift)
    @ObservationIgnored var recorder: Any?
    @ObservationIgnored var onShortcutsChanged: (() -> Void)?

    @ObservationIgnored var translatedInput = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0  // only the newest translation may update the view

    func saveLanguages() {
        UserDefaults.standard.set(source, forKey: "source")
        UserDefaults.standard.set(target, forKey: "target")
    }

    func loadLanguages() async {
        languages = await Translator.languages().sorted { Translator.name($0) < Translator.name($1) }
    }

    /// Translates in the background (while typing, or after a language change).
    func translate() {
        task?.cancel()
        task = Task { await translateNow() }
    }

    func translateNow() async {
        generation += 1
        let gen = generation, snapshot = input
        translatedInput = snapshot
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { show(.init(text: "")); translating = false; return }
        translating = true
        let r = await Translator.run(text, from: source.isEmpty ? nil : Locale.Language(identifier: source),
                                     to: target.isEmpty ? nil : Locale.Language(identifier: target))
        guard gen == generation else { return }  // a newer translation, or `clear()`, took over
        show(r)
        translating = false
    }

    func showMessage(_ text: String) { show(.init(text: text, failed: true)) }

    private func show(_ r: Translator.Outcome) {
        (output, failed, needsSetup, detected, usedTarget) = (r.text, r.failed, r.needsSetup, r.source, r.target)
    }

    /// Forget the text and translation, so nothing sensitive shows the next time it opens.
    func clear() {
        task?.cancel()
        generation += 1
        (input, translatedInput, reading, translating) = ("", "", false, false)
        show(.init(text: ""))
    }

    /// Like the Translate app: the languages trade places and the translation becomes the input.
    func swapLanguages() {
        guard let from = source.isEmpty ? detected?.minimalIdentifier : source,
              let to = target.isEmpty ? usedTarget?.minimalIdentifier : target else { return }
        if !output.isEmpty, !failed { input = output }
        (source, target) = (to, from)
        saveLanguages()
    }
}

/// Translation with no UI of its own, using Apple's Translation framework.
enum Translator {
    struct Outcome {
        var text: String
        var failed = false
        var needsSetup = false
        var source: Locale.Language?  // the detected source language
        var target: Locale.Language?  // the language it was translated into
    }

    /// A nil `from` detects the source language. A nil `to` picks the target automatically, as does a
    /// target that's the same language as the source.
    static func run(_ text: String, from: Locale.Language?, to requested: Locale.Language?) async -> Outcome {
        let detected = from == nil ? await detect(text) : nil
        guard let source = from ?? detected else { return Outcome(text: "Couldn't detect the language.", failed: true) }
        guard let target = requested.flatMap({ same($0, source) ? nil : $0 }) ?? automaticTarget(for: source) else {
            return Outcome(text: "Choose a language to translate into.", failed: true, source: detected)
        }
        func failure(_ message: String, needsSetup: Bool = false) -> Outcome {
            Outcome(text: message, failed: true, needsSetup: needsSetup, source: detected, target: target)
        }
        let pair = "\(name(source)) to \(name(target))"
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed:
            do {
                var out = try await TranslationSession(installedSource: source, target: target).translate(text).targetText
                // Keep the original's line breaks: the translator can turn single newlines into blank lines.
                if !text.replacingOccurrences(of: "\r\n", with: "\n").contains("\n\n") { out = out.replacing(/\n{2,}/, with: "\n") }
                return Outcome(text: out, source: detected, target: target)
            } catch {
                return failure(error.localizedDescription)
            }
        case .unsupported:
            return failure("Translating \(pair) isn't supported.")
        default:
            return failure("\(pair) isn't set up on this Mac yet.", needsSetup: true)
        }
    }

    /// The user's first preferred language (System Settings › Language & Region, in their order) that
    /// isn't the source: English text goes to Chinese and Chinese to English for someone who uses
    /// both. Language and script only ("en-CA" → "en"), since regional variants often aren't downloaded.
    private static func automaticTarget(for source: Locale.Language) -> Locale.Language? {
        (Locale.preferredLanguages + ["en"])
            .map { id in
                let l = Locale.Language(identifier: id)
                return Locale.Language(languageCode: l.languageCode, script: l.script, region: nil)
            }
            .first { !same($0, source) }
    }

    /// Same language and script (so Simplified and Traditional Chinese still translate to each other).
    private static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let (x, y) = (Locale.Language(identifier: a.maximalIdentifier), Locale.Language(identifier: b.maximalIdentifier))
        return x.languageCode == y.languageCode && x.script == y.script
    }

    /// Limited to languages Translation supports and leaning toward the user's preferred languages,
    /// so short text like "hi" or "ok" isn't read as Catalan or Polish.
    private static func detect(_ text: String) async -> Locale.Language? {
        let r = NLLanguageRecognizer()
        let supported = Set(await languages().map(nlLanguage))
        let preferred = Set(Locale.preferredLanguages.map { nlLanguage(Locale.Language(identifier: $0)) })
        r.languageConstraints = Array(supported)
        r.languageHints = Dictionary(uniqueKeysWithValues: supported.map { ($0, preferred.contains($0) ? 10 : 1) })
        r.processString(text)
        guard let language = r.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    /// NaturalLanguage names Chinese by script (zh-Hans / zh-Hant); everything else by language code.
    private static func nlLanguage(_ l: Locale.Language) -> NLLanguage {
        let code = l.languageCode?.identifier ?? ""
        guard code == "zh" else { return NLLanguage(code) }
        let traditional = l.script?.identifier == "Hant" || ["TW", "HK", "MO"].contains(l.region?.identifier ?? "")
        return NLLanguage(traditional ? "zh-Hant" : "zh-Hans")
    }

    /// Opens Language & Region; the Translation Languages… button is at the bottom of that pane.
    @MainActor static func openLanguageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
    }

    static func languages() async -> [Locale.Language] { await LanguageAvailability().supportedLanguages }

    static func name(_ l: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: l.minimalIdentifier) ?? l.minimalIdentifier
    }
}

/// Reads text aloud with the system voice for its language. Clicking again stops.
@MainActor @Observable final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    var speaking: String?  // which side is being read
    @ObservationIgnored private let synth = AVSpeechSynthesizer()
    @ObservationIgnored private var current: ObjectIdentifier?  // the utterance `speaking` belongs to

    override init() {
        super.init()
        synth.delegate = self
    }

    func toggle(_ id: String, _ text: String, _ language: Locale.Language?) {
        let wasSpeaking = speaking
        stop()
        guard wasSpeaking != id else { return }
        let u = AVSpeechUtterance(string: text)
        if let language {  // voices are named like "fr-FR" and "zh-CN"
            let full = Locale.Language(identifier: language.maximalIdentifier)
            let code = [full.languageCode?.identifier, full.region?.identifier].compactMap { $0 }.joined(separator: "-")
            u.voice = AVSpeechSynthesisVoice(language: code) ?? AVSpeechSynthesisVoice(language: language.minimalIdentifier)
        }
        (speaking, current) = (id, ObjectIdentifier(u))
        synth.speak(u)
    }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        (speaking, current) = (nil, nil)
    }

    nonisolated func speechSynthesizer(_: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        let finished = ObjectIdentifier(u)
        Task { @MainActor in if current == finished { (speaking, current) = (nil, nil) } }
    }
}
