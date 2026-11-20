import SwiftUI

/// The translator, in the popover or (once dragged out) its own window: the source text, a bar with
/// its language, the translation, and a bar with the target language. The two text areas start the
/// same height and the line between them can be dragged. In the popover they grow with the text,
/// up to the room on screen, then scroll. Translates as you type.
struct TranslatorView: View {
    @Bindable var m: Model
    var close: (() -> Void)?  // set in the window, for its ⓧ button
    @State private var speaker = Speaker()
    @State private var inputHeight: CGFloat = 20  // the texts' own heights
    @State private var outputHeight: CGFloat = 20
    @State private var windowHeight: CGFloat = 0  // for sharing out the window
    @State private var barsHeight: CGFloat = 0
    @State private var dragStart: (split: CGFloat, total: CGFloat)?
    @FocusState private var focused: Bool
    @State private var selection: TextSelection?

    private var detached: Bool { close != nil }

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                if m.reading {
                    status("Reading text…")
                } else {
                    TextEditor(text: $m.input, selection: $selection)
                        .textEditorStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .padding(.horizontal, -5)  // the editor's own text margin, so it lines up with the translation
                        .scrollIndicators(.never)  // scrolls with the trackpad; cut-off text shows there's more
                        .scrollBounceBehavior(.basedOnSize)  // no rubber-banding when the text fits (or is empty)
                        .focused($focused)
                    if m.input.isEmpty { Text("Enter text").foregroundStyle(.tertiary).allowsHitTesting(false) }
                }
            }
            .font(.body)
            .background(alignment: .topLeading) {  // the text's own height, for sizing the areas
                Text(m.input.isEmpty ? " " : m.input).fixedSize(horizontal: false, vertical: true).hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { inputHeight = $0 }
            }
            .padding([.horizontal, .top], 12)  // little below: the bar under it has its own spacing
            .padding(.bottom, 4)
            .padding(.trailing, 22)  // room for the window's ⓧ; also in the popover, so text doesn't reflow on detach
            .frame(minHeight: detached ? 0 : areas.top, maxHeight: areas.top, alignment: .topLeading)  // see `areas`
            bar(dividerBelow: true) {
                Picker("From", selection: languageBinding(\.source)) {
                    Text(m.detected.map { String(localized: "\(Translator.name($0)) (Detected)") } ?? String(localized: "Detect Language")).tag("")
                    Divider()
                    languageItems
                }
                Spacer(minLength: 4)
                speakButton("source", m.input, m.source.isEmpty ? m.detected : Locale.Language(identifier: m.source))
                Button("Swap Languages", systemImage: "arrow.up.arrow.down") { m.swapLanguages() }
                    .help("Swap Languages")
                    .disabled((m.source.isEmpty && m.detected == nil) || (m.target.isEmpty && m.usedTarget == nil))
                copyButton("Copy Text", m.input)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if m.translating && m.output.isEmpty {
                        status("Translating…")
                    } else {
                        Text(m.output.isEmpty ? String(localized: "Translation") : m.output)
                            .foregroundStyle(m.output.isEmpty || m.failed ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                    if m.needsSetup {
                        Button("Download in Language & Region › Translation Languages…") { Translator.openLanguageSettings() }
                            .buttonStyle(.link)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { outputHeight = $0 }
                .padding([.horizontal, .top], 12)
                .padding(.bottom, 4)
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: detached ? 0 : areas.bottom, maxHeight: areas.bottom)
            bar(dividerBelow: false) {
                Picker("To", selection: languageBinding(\.target)) {
                    Text(m.usedTarget.map { String(localized: "\(Translator.name($0)) (Automatic)") } ?? String(localized: "Automatic")).tag("")
                    Divider()
                    languageItems
                }
                Spacer(minLength: 4)
                if m.translating && !m.output.isEmpty { ProgressView().controlSize(.mini) }  // updating as you type
                let translation = m.failed ? "" : m.output
                speakButton("translation", translation, m.usedTarget ?? Locale.Language(identifier: m.target))
                copyButton("Copy Translation", translation)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let close {
                Button("Close", systemImage: "xmark.circle.fill", action: close)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .help("Close")
                    .padding(10)
            }
        }
        .frame(width: detached ? nil : width)
        .frame(maxWidth: detached ? .infinity : nil, maxHeight: detached ? .infinity : nil)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
        // Outermost, so the height above includes the hidden title bar's space, which the view uses too.
        .ignoresSafeArea(edges: detached ? .top : [])
        .onDisappear { speaker.stop() }
        .onAppear(perform: focusAtEnd)
        .onChange(of: m.reading) { _, reading in if !reading { focusAtEnd() } }  // screenshot text arrived
        .task { if m.languages.isEmpty { await m.loadLanguages() } }
        .task(id: m.input) {  // debounce typing; skip text that's already translated
            try? await Task.sleep(for: .milliseconds(400))
            if !Task.isCancelled, m.input != m.translatedInput { m.translate() }
        }
    }

    /// Heights of the two text areas. Popover: each as tall as the longer text, up to the room on screen.
    /// Window: whatever's left after the bars. The user's `split` then shares that out. In the window
    /// they're only maximums, so the window can still be made smaller (and these follow).
    private var areas: (top: CGFloat, bottom: CGFloat) {
        let total: CGFloat
        if detached {
            total = max(windowHeight - barsHeight, 80)
        } else {
            // Plus the padding, and a little for the editor's own spacing, so text that fits doesn't scroll.
            let each = max(inputHeight + 6, outputHeight) + 16
            total = 2 * min(max(each, 64), max((m.maxHeight - 90) / 2, 64))
        }
        let top = (total * m.split).rounded()
        return (top, total - top)
    }

    /// The line between the two halves: drag it to resize them, double-click to make them equal again.
    private var splitHandle: some View {
        Divider().overlay {
            Color.clear
                .frame(height: 9)
                .contentShape(Rectangle())
                .pointerStyle(.rowResize)
                // Measured on screen, not on the handle: the handle moves as you drag, which would
                // make the distance jump around. The split and total are fixed when the drag starts.
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let start = dragStart ?? (m.split, areas.top + areas.bottom)
                        dragStart = start
                        m.split = min(max(start.split + drag.translation.height / start.total, 0.15), 0.85)
                    }
                    .onEnded { _ in dragStart = nil })
                .onTapGesture(count: 2) { m.split = 0.5 }
        }
    }

    /// Focusing a text field selects all of it; put the cursor at the end instead.
    private func focusAtEnd() {
        focused = true
        DispatchQueue.main.async { selection = TextSelection(insertionPoint: m.input.endIndex) }
    }

    /// The menus save the user's choice; a screenshot switching to detection doesn't.
    private func languageBinding(_ key: ReferenceWritableKeyPath<Model, String>) -> Binding<String> {
        Binding(get: { m[keyPath: key] }, set: { m[keyPath: key] = $0; m.saveLanguages() })
    }

    /// A thin bar with a language menu and icon buttons. The middle one has its hairline below, so it
    /// clearly belongs to the source text above.
    private func bar(dividerBelow: Bool, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { content() }
                .labelsHidden()
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            if dividerBelow { splitHandle }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [dividerBelow] h in
            // Both bars are the same height apart from the 1-pt line, so one measurement covers both.
            if dividerBelow { barsHeight = 2 * h - 1 }
        }
    }

    private func status(_ text: LocalizedStringKey) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func speakButton(_ id: String, _ text: String, _ language: Locale.Language?) -> some View {
        let on = speaker.speaking == id
        let title = on ? String(localized: "Stop Speaking") : String(localized: "Read Aloud")
        return Button(title, systemImage: on ? "stop.fill" : "speaker.wave.2") {
            speaker.toggle(id, text, language)
        }
        .help(title)
        .disabled(text.isEmpty)
    }

    private func copyButton(_ title: LocalizedStringKey, _ text: String) -> some View {
        Button(title, systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        .help(Text(title))
        .disabled(text.isEmpty)
    }

    private var languageItems: some View {
        ForEach(m.languages, id: \.minimalIdentifier) { Text(Translator.name($0)).tag($0.minimalIdentifier) }
    }

    /// Wider for longer text, so big screenshots need fewer lines.
    private var width: CGFloat {
        switch max(m.input.count, m.output.count) {
        case ..<160: 380
        case ..<500: 460
        default: 560
        }
    }
}
