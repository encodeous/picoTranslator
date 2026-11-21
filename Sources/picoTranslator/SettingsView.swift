import Carbon.HIToolbox
import ServiceManagement
import SwiftUI

/// The setup sections, used by both the welcome window and Settings. Styled like System Settings.
struct SetupForm: View {
    let m: Model
    @State private var launchAtLogin = Self.loginItemOn

    /// On, or waiting for the user's approval in System Settings › Login Items.
    private static var loginItemOn: Bool { [.enabled, .requiresApproval].contains(SMAppService.mainApp.status) }

    var body: some View {
        Form {
            Section("Permissions") {
                ScreenRecordingRow()
            }
            Section("Languages") {
                LabeledContent {
                    Button("Open…") { Translator.openLanguageSettings() }
                } label: {
                    RowLabel("Translation languages", "In Language & Region, click Translation Languages… and download the ones you use.",
                             symbol: "globe", color: .teal)
                }
            }
            Section("Shortcuts") {
                LabeledContent {
                    KeyRecorder(m: m, index: 0)
                } label: {
                    RowLabel("Translate screenshot", "Select an area to read and translate.", symbol: "text.viewfinder", color: .blue)
                }
                LabeledContent {
                    KeyRecorder(m: m, index: 1)
                } label: {
                    RowLabel("Open translator", "Type or paste text to translate.", symbol: "character.bubble", color: .indigo)
                }
            }
            Section {
                // Set from the toggle only: writing `launchAtLogin` back from an onChange would fire it
                // again, which unregistered the app right after sending the user to approve it.
                Toggle(isOn: Binding(get: { launchAtLogin }, set: { on in
                    let service = SMAppService.mainApp
                    try? on ? service.register() : service.unregister()
                    if on, service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
                    launchAtLogin = Self.loginItemOn  // show what actually happened
                })) {
                    RowLabel("Launch at login", nil, symbol: "power", color: .gray)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 460, height: 470)
        .onDisappear { m.stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            launchAtLogin = Self.loginItemOn  // e.g. back from approving it in System Settings
        }
    }
}

/// Shown at launch until the user presses Done.
struct WelcomeView: View {
    let m: Model
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)  // the icon's canvas has margins, hence the negative padding
                    .resizable()
                    .frame(width: 96, height: 96)
                    .padding(-6)
                Text("Welcome to picoTranslator").font(.title.bold())
                Text("Translate text on screen, or type it in.").foregroundStyle(.secondary)
            }
            .padding(.top, 44)
            SetupForm(m: m)
            Button(action: done) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 460)
    }
}

/// A System Settings style row label: a coloured icon tile, a title and an optional caption.
struct RowLabel: View {
    let title: LocalizedStringKey, caption: LocalizedStringKey?, symbol: String, color: Color
    init(_ title: LocalizedStringKey, _ caption: LocalizedStringKey?, symbol: String, color: Color) {
        (self.title, self.caption, self.symbol, self.color) = (title, caption, symbol, color)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(color.gradient, in: .rect(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let caption { Text(caption).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
        }
    }
}

/// Screen Recording status, with a button that asks for it.
struct ScreenRecordingRow: View {
    @State private var granted = CGPreflightScreenCaptureAccess()
    @State private var asked = false

    var body: some View {
        LabeledContent {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill").foregroundStyle(.green).fontWeight(.medium)
            } else {
                Button(asked ? String(localized: "Open Settings…") : String(localized: "Allow")) {
                    if asked {  // still off after asking (switched off before): open the list to switch it on
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                    } else {  // prompts if macOS has no record of the app, and puts it back in the list either way
                        CGRequestScreenCaptureAccess()
                        asked = true
                    }
                }
            }
        } label: {
            RowLabel("Screen Recording", "Needed to read text from screenshots.", symbol: "rectangle.dashed.badge.record", color: .red)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            granted = CGPreflightScreenCaptureAccess()
        }
    }
}

/// Click, then press a key combination. Esc cancels. Shows the shortcut as keycaps, like the
/// Keyboard Shortcuts pane in System Settings, in red when another app already uses it.
struct KeyRecorder: View {
    let m: Model
    let index: Int

    var body: some View {
        let taken = m.unavailableShortcuts.contains(index)
        Button {
            m.recording == index ? m.stopRecording() : m.record(index)
        } label: {
            if m.recording == index {
                Text("Listening…").foregroundStyle(.tint)
            } else {
                HStack(spacing: 3) {
                    ForEach(Array(keycaps.enumerated()), id: \.offset) { _, key in
                        Text(key)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .padding(.horizontal, key.count > 1 ? 4 : 0)
                            .frame(minWidth: 18, minHeight: 18)
                            .background(.fill.tertiary, in: .rect(cornerRadius: 4))
                    }
                }
                .foregroundStyle(taken ? .red : .primary)
            }
        }
        .help(taken ? String(localized: "Another app already uses this shortcut. Click to choose a different one.")
                    : String(localized: "Click, then press the new shortcut. Esc cancels."))
    }

    /// One cap per modifier symbol, then one for the key (which may be a word like "Space" or "F5").
    private var keycaps: [String] {
        let label = m.shortcuts[index].label
        let mods = label.prefix { "⌃⌥⇧⌘".contains($0) }
        let key = String(label.dropFirst(mods.count))
        return mods.map(String.init) + [key == "Space" ? String(localized: "Space") : key]
    }
}

/// Recording a shortcut. Only one recorder listens at a time, and the app's own shortcuts are off
/// meanwhile, so pressing one of them records it instead of running it.
extension Model {
    func record(_ index: Int) {
        stopRecording()
        recording = index
        HotKeys.pause()
        recorder = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                if e.keyCode == kVK_Escape {
                    self.stopRecording()
                } else if let s = Shortcut(e), !s.clashesWithMenus,
                          !self.shortcuts.indices.contains(where: { $0 != index && self.shortcuts[$0].sameKeys(as: s) }) {
                    self.shortcuts[index] = s
                    self.stopRecording()
                } else {
                    NSSound.beep()  // no ⌃ or ⌥, an app menu shortcut like ⌘W, or the other shortcut: keep listening
                }
            }
            return nil
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        NSEvent.removeMonitor(recorder)
        self.recorder = nil
        recording = nil
        onShortcutsChanged?()  // registers the shortcuts again
    }
}
