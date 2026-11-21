import AppKit
import AVFoundation
import Translation

/// App state shared by the popover, the windows and the shortcuts.
@MainActor @Observable final class Model {
    var input = ""
    var output = ""
    var failed = false      // `output` is a message (an error, "no text found"…), not a translation
    var needsSetup = false  // the language pair still has to be downloaded
    var detected: Locale.Language?    // what "Detect Language" found
    var usedTarget: Locale.Language?  // what the last translation went into (shown for "Automatic")
    /// The target the last translation was asked for, if that was the source language itself, so it
    /// went into the automatic target instead. Kept with the target it belongs to, so picking another
    /// language shows at once, before its translation arrives.
    var fellBackFrom: String?
    var reading = false      // reading text from a screenshot
    var slowReading = false  // reading has taken over 3 s: macOS is most likely still preparing its text model
    var lowStorage = false   // and the disk is too full for macOS to keep that model: see `Capture.lowOnStorage`
    var translating = false
    var maxHeight: CGFloat = 520  // room on screen for the popover, set before it opens
    var split: CGFloat = 0.5  // the source text's share of the text areas; the user can drag the line between
    var languages: [Locale.Language] = []
    @ObservationIgnored var barsHeight: CGFloat = 0  // the translator's two bars, as last measured (see TranslatorView)

    /// "" detects the source language. Changed, and saved, with `choose(source:)`.
    private(set) var source = UserDefaults.standard.string(forKey: "source") ?? ""
    /// "" is automatic: the user's first preferred language that isn't the source (see `Translator`).
    private(set) var target = UserDefaults.standard.string(forKey: "target") ?? ""
    /// A screenshot can be in any language, so it detects without changing the saved choice. Lasts
    /// until the text is cleared, or the user picks a source language.
    var detectOnce = false

    /// The source language in use: "" while detecting.
    var effectiveSource: String { detectOnce ? "" : source }
    /// What the To menu shows: Automatic while the chosen target fell back.
    var shownTarget: String { fellBackFrom == target ? "" : target }
    /// The language that Automatic stands for, for its menu item. Nil while another language is shown.
    var automaticTarget: Locale.Language? { shownTarget.isEmpty ? usedTarget : nil }

    var shortcuts = (try? JSONDecoder().decode([Shortcut].self, from: UserDefaults.standard.data(forKey: "shortcuts") ?? Data()))
        .flatMap { $0.count == Shortcut.defaults.count ? $0 : nil } ?? Shortcut.defaults {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(shortcuts), forKey: "shortcuts") }
    }
    var unavailableShortcuts: Set<Int> = []  // already taken by another app
    var recording: Int?  // the shortcut that's listening for new keys (see SettingsView.swift)
    @ObservationIgnored var recorder: Any?
    @ObservationIgnored var onShortcutsChanged: (() -> Void)?

    @ObservationIgnored var translatedInput: String? = ""  // nil after a failure, so the same text is tried again
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = 0  // only the newest translation may update the view
    @ObservationIgnored private var lastSource: Locale.Language?  // for warming up while detecting
    @ObservationIgnored private var warmedAt = Date.distantPast

    /// The From menu: saves the choice and ends a screenshot's one-off detection.
    func choose(source id: String) {
        detectOnce = false
        source = id
        UserDefaults.standard.set(id, forKey: "source")
        translate()
    }

    /// The To menu.
    func choose(target id: String) {
        target = id
        UserDefaults.standard.set(id, forKey: "target")
        translate()
    }

    func loadLanguages() async {
        // Empty if the translation service hasn't started yet: try again for a little while.
        for attempt in 0..<4 {
            let list = await Translator.languages()
            if !list.isEmpty { languages = list.sorted { Translator.name($0) < Translator.name($1) }; return }
            try? await Task.sleep(for: .milliseconds(500 << attempt))
        }
    }

    /// Translates in the background (while typing, or after a language change).
    func translate() {
        task?.cancel()
        task = Task { await translateNow() }
    }

    func translateNow() async {
        guard !Task.isCancelled else { return }  // replaced before it started
        generation += 1
        let gen = generation, snapshot = input, wanted = target
        translatedInput = snapshot
        let text = snapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { show(.init(text: ""), for: wanted); translating = false; return }
        translating = true
        if languages.isEmpty { await loadLanguages() }
        let source = effectiveSource
        let r = await Translator.run(text, from: source.isEmpty ? nil : Locale.Language(identifier: source),
                                     to: wanted.isEmpty ? nil : Locale.Language(identifier: wanted), languages: languages)
        guard gen == generation else { return }  // a newer translation, a message or `clear()` took over
        show(r, for: wanted)
        translating = false
        if r.failed { translatedInput = nil } else if let s = r.source { lastSource = s }
    }

    /// Loads the likely language pair's model ahead of the first translation, which otherwise waits
    /// for it, and starts the system's translation service if it isn't running. Called when the
    /// translator opens and when a screenshot starts.
    func warmUp() {
        guard Date.now.timeIntervalSince(warmedAt) > 30 else { return }
        warmedAt = .now
        let source = effectiveSource.isEmpty ? lastSource ?? Translator.preferredLanguages.first : Locale.Language(identifier: effectiveSource)
        guard let source else { return }
        let target = target.isEmpty ? nil : Locale.Language(identifier: target)
        Task.detached(priority: .utility) { await Translator.warmUp(from: source, to: target) }
    }

    func showMessage(_ text: String) {
        task?.cancel()
        generation += 1  // so a translation still running doesn't replace it
        translating = false
        show(.init(text: text, failed: true), for: target)
    }

    private func show(_ r: Translator.Outcome, for wanted: String) {
        (output, failed, needsSetup, detected, usedTarget) = (r.text, r.failed, r.needsSetup, r.source, r.target)
        fellBackFrom = r.fellBack ? wanted : nil
    }

    /// Forget the text and translation, so nothing sensitive shows the next time it opens.
    func clear() {
        task?.cancel()
        generation += 1
        (input, translatedInput, reading, slowReading, lowStorage, translating, detectOnce) = ("", "", false, false, false, false, false)
        show(.init(text: ""), for: target)
    }

    /// Like the Translate app: the languages trade places and the translation becomes the input.
    /// While detecting, detection stays on (it finds the swapped text's language), so a swap never
    /// turns it off for the texts that follow.
    func swapLanguages() {
        let detecting = effectiveSource.isEmpty
        guard let from = detecting ? detected : Locale.Language(identifier: effectiveSource),
              let to = shownTarget.isEmpty ? usedTarget : Locale.Language(identifier: shownTarget) else { return }
        if !output.isEmpty, !failed { input = output }
        if detecting {
            // The old source becomes the target, unless Automatic would pick it anyway.
            let automatic = Translator.automaticTarget(for: to).map { Translator.same($0, from) } ?? false
            target = automatic ? "" : menuID(for: from)
        } else {
            (source, target) = (menuID(for: to), menuID(for: from))
            UserDefaults.standard.set(source, forKey: "source")
        }
        UserDefaults.standard.set(target, forKey: "target")
        translate()
    }

    /// The language menus' tag for a language: Translation lists some only with a region ("ar-AE").
    func menuID(for l: Locale.Language) -> String {
        (languages.first { $0.minimalIdentifier == l.minimalIdentifier } ?? languages.first { Translator.same($0, l) })?
            .minimalIdentifier ?? l.minimalIdentifier
    }
}

/// Translation with no UI of its own, using Apple's Translation framework.
enum Translator {
    struct Outcome {
        var text: String
        var failed = false
        var needsSetup = false
        var fellBack = false          // the requested target was the source language: went to the automatic one
        var source: Locale.Language?  // the detected source language
        var target: Locale.Language?  // the language it was translated into
    }

    /// A nil `from` detects the source language. A nil `to` picks the target automatically, as does a
    /// target that's the same language as the source. `languages` is the supported list, if known.
    static func run(_ text: String, from: Locale.Language?, to requested: Locale.Language?, languages known: [Locale.Language]) async -> Outcome {
        let list = known.isEmpty ? await languages() : known
        var detected: Locale.Language?
        if from == nil {
            switch detect(text, among: list) {
            case .language(let l): detected = l
            case .unsupported(let l):
                return Outcome(text: String(localized: "Translating \(name(l)) isn't supported."), failed: true)
            case .unknown:
                return Outcome(text: String(localized: "Couldn't detect the language."), failed: true)
            }
        }
        guard let source = from ?? detected else { return Outcome(text: String(localized: "Couldn't detect the language."), failed: true) }
        let (target, fellBack) = resolve(requested, for: source)
        guard let target else {
            return Outcome(text: String(localized: "Choose a language to translate into."), failed: true, source: detected)
        }
        func failure(_ message: String, needsSetup: Bool = false) -> Outcome {
            Outcome(text: message, failed: true, needsSetup: needsSetup, fellBack: fellBack, source: detected, target: target)
        }
        let (fromName, toName) = (name(source), name(target))
        let notSetUp = String(localized: "\(fromName) to \(toName) isn't set up on this Mac yet.")
        switch await availability().status(from: source, to: target) {
        case .installed:
            // The translation service starts on demand. For a moment after it starts, it reports the
            // languages as installed while a session still finds them "in progress" and throws
            // notInstalled, so the first translation after it starts would fail. Wait and try again.
            for delay in [0, 250, 500, 1000, 2000] {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                if Task.isCancelled { return failure("") }  // replaced: nobody sees this
                do {
                    var out = try await session(source, target).translate(text).targetText
                    // Keep the original's line breaks: the translator can turn single newlines into blank lines.
                    if !text.replacingOccurrences(of: "\r\n", with: "\n").contains("\n\n") { out = out.replacing(/\n{2,}/, with: "\n") }
                    // Text in another language than the chosen source comes back unchanged, which looks
                    // like the translation failed. Say what it seems to be instead.
                    if from != nil, out == text, case .language(let other) = detect(text, among: list), !same(other, source) {
                        return failure(String(localized: "This text looks like \(name(other)), not \(fromName)."))
                    }
                    return Outcome(text: out, fellBack: fellBack, source: detected, target: target)
                } catch TranslationError.notInstalled {
                    continue
                } catch TranslationError.unsupportedLanguagePairing, TranslationError.unsupportedSourceLanguage,
                        TranslationError.unsupportedTargetLanguage {
                    return failure(String(localized: "Translating \(fromName) to \(toName) isn't supported."))
                } catch {
                    return failure(String(localized: "Couldn't translate the text. Try again."))
                }
            }
            return failure(notSetUp, needsSetup: true)
        case .unsupported:
            return failure(String(localized: "Translating \(fromName) to \(toName) isn't supported."))
        default:
            return failure(notSetUp, needsSetup: true)
        }
    }

    /// Translates a single letter, which makes the system load the pair's model. (`prepareTranslation()`
    /// doesn't: it only asks for downloads.) Errors don't matter here.
    static func warmUp(from source: Locale.Language, to requested: Locale.Language?) async {
        guard let target = resolve(requested, for: source).target,
              case .installed = await availability().status(from: source, to: target) else { return }
        _ = try? await session(source, target).translate("a")
    }

    /// The target to use, and whether the requested one was the source language itself.
    static func resolve(_ requested: Locale.Language?, for source: Locale.Language) -> (target: Locale.Language?, fellBack: Bool) {
        if let requested, !same(requested, source) { return (requested, false) }
        return (automaticTarget(for: source), requested != nil)
    }

    /// The user's first preferred language (System Settings › Language & Region, in their order) that
    /// isn't the source: English text goes to Chinese and Chinese to English for someone who uses both.
    static func automaticTarget(for source: Locale.Language) -> Locale.Language? {
        (preferredLanguages + [Locale.Language(identifier: "en")]).first { !same($0, source) }
    }

    /// The user's preferred languages, by language and script only ("en-CA" → "en"), since a region
    /// can name a variant that isn't downloaded.
    static var preferredLanguages: [Locale.Language] {
        Locale.preferredLanguages.map { id in
            let l = Locale.Language(identifier: id)
            return Locale.Language(languageCode: l.languageCode, script: l.script, region: nil)
        }
    }

    /// Same language and script (so Simplified and Traditional Chinese still translate to each other).
    static func same(_ a: Locale.Language, _ b: Locale.Language) -> Bool {
        let (x, y) = (Locale.Language(identifier: a.maximalIdentifier), Locale.Language(identifier: b.maximalIdentifier))
        return x.languageCode == y.languageCode && x.script == y.script
    }

    /// Always the fast, traditional models. The framework's default depends on the SDK version recorded
    /// in the binary: from 26.4 on it's the Apple Intelligence models, which are slower and list regional
    /// variants (English (Canada)…) that report "not installed" even with the language downloaded.
    static func availability() -> LanguageAvailability {
        if #available(macOS 26.4, *) { LanguageAvailability(preferredStrategy: .lowLatency) } else { LanguageAvailability() }
    }

    private static func session(_ source: Locale.Language, _ target: Locale.Language) -> TranslationSession {
        if #available(macOS 26.4, *) {
            TranslationSession(installedSource: source, target: target, preferredStrategy: .lowLatency)
        } else {
            TranslationSession(installedSource: source, target: target)
        }
    }

    /// Opens Language & Region; the Translation Languages… button is at the bottom of that pane.
    @MainActor static func openStorageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!)
    }

    @MainActor static func openLanguageSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!)
    }

    static func languages() async -> [Locale.Language] { await availability().supportedLanguages }

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
