import AppKit
import SwiftUI

@main @MainActor enum Main {
    static let delegate = AppDelegate()
    static let showSettings = Notification.Name("ca.encodeous.picoTranslator.showSettings")

    static func main() {
        if TextReader.runIfRequested() { return }  // started as the text-reading helper, not the app
        // One copy only: if another is already running, have it show Settings and quit this one.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && !$0.isTerminated }) {
            DistributedNotificationCenter.default().postNotificationName(showSettings, object: nil, deliverImmediately: true)
            return
        }
        DistributedNotificationCenter.default().addObserver(forName: showSettings, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { delegate.openSettings() }
        }
        NSApplication.shared.delegate = delegate
        NSApplication.shared.run()
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let model = Model()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

    // The translator popover, pointing at an invisible 1-pt window placed at the cursor.
    var popover = NSPopover()
    let anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // also over full-screen apps
        return w
    }()
    var clickMonitor: Any?
    var popoverShownAt = Date.distantPast
    var closingSince: Date?  // set while the popover's close animation runs
    var reopenAfterClose = false

    // The popover once dragged out into its own window, and the Settings / Welcome window.
    var translatorWindow: NSWindow?
    var translatorHost: NSViewController?  // keeps the window's SwiftUI view alive
    var formWindow: NSWindow?

    var captureID = 0  // only the newest screenshot may fill the translator

    func applicationDidFinishLaunching(_: Notification) {
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "About picoTranslator", action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit picoTranslator", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu

        resetPopover()
        model.onShortcutsChanged = { [weak self] in self?.registerHotKeys() }
        registerHotKeys()
        installEditMenu()
        installEscapeToClose()
        Task { await model.loadLanguages() }
        Capture.prepare()
        // Setup runs until Done is pressed, and again whenever Screen Recording has been taken away.
        if !UserDefaults.standard.bool(forKey: "setupDone") || !CGPreflightScreenCaptureAccess() { openWelcome() }
    }

    /// Opening the app again while it runs (Finder, Spotlight, Launchpad) shows Settings.
    func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
        openSettings()
        return false
    }

    func registerHotKeys() {
        model.unavailableShortcuts = HotKeys.set([
            (model.shortcuts[0], { [weak self] in self?.captureAndTranslate() }),
            (model.shortcuts[1], { [weak self] in self?.showTranslator() }),
        ])
    }

    // MARK: Translator

    func captureAndTranslate() {
        guard CGPreflightScreenCaptureAccess() else { return openWelcome() }  // permission was removed
        captureID += 1
        let id = captureID
        if popover.isShown { popover.close() }  // keep it out of the screenshot
        Task {
            guard let image = await Capture.screenshot() else { return }  // cancelled
            guard id == captureID else { try? FileManager.default.removeItem(at: image); return }  // superseded
            // Open right away with a spinner: reading can take a while if macOS has to load its model first.
            if translatorWindow == nil { model.clear() }
            model.source = ""  // a screenshot can be in any language: detect it (without saving that choice)
            model.reading = true
            showTranslator()
            let reading = await Capture.text(in: image)
            // Drop the result if a newer screenshot took over, or the translator was closed meanwhile.
            guard id == captureID, model.reading else { return }
            model.reading = false
            switch reading {
            case .text(let text):
                model.input = text
                await model.translateNow()
            case .noText:
                model.showMessage("No text found in the selected area.")
            case .timedOut:
                model.showMessage("Reading the text is taking too long. macOS may still be preparing text recognition, so try again in a moment.")
            }
        }
    }

    /// Shows the dragged-out window if there is one, otherwise the popover at the mouse cursor: below
    /// it, or above when there's more room above. AppKit shifts it sideways near the screen's edges.
    func showTranslator() {
        if let w = translatorWindow { return bringForward(w) }
        if popover.isShown {
            if let w = popover.contentViewController?.view.window, w.isVisible { return bringForward(w) }
            // Shown on paper only (e.g. after being dragged out): close it, keeping the model, and reopen.
            reopenAfterClose = true
            return closePopoverNow()
        }
        // Mid-close: show once the animation ends. Time-limited, in case the end never arrives.
        if let t = closingSince, Date.now.timeIntervalSince(t) < 0.5 { reopenAfterClose = true; return }

        let mouse = NSEvent.mouseLocation
        let visible = Self.screen(containing: mouse).visibleFrame
        let below = mouse.y - visible.minY, above = visible.maxY - mouse.y
        let edge: NSRectEdge = below >= 480 || below >= above ? .minY : .maxY
        model.maxHeight = max(200, min(720, (edge == .minY ? below : above) - 24))  // the view grows up to this

        let host = NSHostingController(rootView: TranslatorView(m: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host  // the SwiftUI view exists only while the popover is open
        anchor.setFrameOrigin(mouse)
        anchor.orderFrontRegardless()
        popover.show(relativeTo: anchor.contentView!.bounds, of: anchor.contentView!, preferredEdge: edge)
        popoverShownAt = .now
        if let w = popover.contentViewController?.view.window {
            // Above other apps and on every Space, even if macOS doesn't let the app activate.
            w.level = .popUpMenu
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            bringForward(w)
        }
        // Close at once on a click anywhere outside the app (another app, display or the desktop).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.close() }
        }
    }

    func applicationDidBecomeActive(_: Notification) {
        if popover.isShown { popover.contentViewController?.view.window?.makeKey() }
    }

    /// Switching apps (e.g. ⌘-Tab) closes the popover. Focus can flicker back to the previous app just
    /// after a screenshot, so the first second after opening doesn't count.
    func applicationDidResignActive(_: Notification) {
        model.stopRecording()  // shortcuts can't be recorded from another app; turn them back on
        if popover.isShown, Date.now.timeIntervalSince(popoverShownAt) > 1 { popover.close() }
    }

    func resetPopover() {
        popover = NSPopover()
        popover.behavior = .applicationDefined  // closing is ours: an outside click, or switching apps
        popover.delegate = self
    }

    func closePopoverNow() {
        popover.animates = false
        popover.close()
        popover.animates = true
    }

    func popoverWillClose(_: Notification) { closingSince = .now }

    func popoverDidClose(_: Notification) {
        closingSince = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        popover.contentViewController = nil
        anchor.orderOut(nil)
        if reopenAfterClose {
            reopenAfterClose = false
            showTranslator()
        } else if translatorWindow == nil {  // unless it was dragged out into a window
            model.clear()
            resetPopover()  // a fresh one next time, so this one's window and views are freed
            releaseMemory()
        }
    }

    func popoverShouldDetach(_: NSPopover) -> Bool { true }

    /// Dragging the popover away turns it into this window: same Liquid Glass and same size, so the
    /// switch is seamless, with no title bar and an ⓧ drawn by the view. Resizable, draggable anywhere.
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        let host = NSHostingController(rootView: TranslatorView(m: model) { [weak self] in self?.translatorWindow?.close() })
        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.contentView = host.view
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: popover.contentSize),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.contentView = glass
        w.isOpaque = false
        w.backgroundColor = .clear
        w.title = "picoTranslator"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.isMovableByWindowBackground = true
        w.collectionBehavior = .moveToActiveSpace  // a shortcut brings it to the current Space
        w.contentMinSize = NSSize(width: min(300, popover.contentSize.width), height: min(150, popover.contentSize.height))
        w.isReleasedWhenClosed = false
        w.delegate = self
        glass.layoutSubtreeIfNeeded()  // draw now, so the window never shows an empty first frame
        w.displayIfNeeded()
        (translatorWindow, translatorHost) = (w, host)
        return w
    }

    // MARK: Windows

    @objc func openSettings() { showForm(SetupForm(m: model), title: "picoTranslator Settings") }

    /// Shown at every launch until Done is pressed, since granting Screen Recording relaunches the app.
    func openWelcome() {
        showForm(WelcomeView(m: model) { [weak self] in
            UserDefaults.standard.set(true, forKey: "setupDone")
            self?.formWindow?.close()
        }, title: "Welcome", fullSize: true)
    }

    /// Settings and Welcome share one window, centred on the display with the cursor.
    func showForm(_ view: some View, title: String, fullSize: Bool = false) {
        formWindow?.close()
        let host = NSHostingController(rootView: view)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = fullSize ? [.titled, .closable, .fullSizeContentView] : [.titled, .closable]
        w.titlebarAppearsTransparent = fullSize
        w.titleVisibility = fullSize ? .hidden : .visible
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.setContentSize(host.view.fittingSize)
        let v = Self.screen(containing: NSEvent.mouseLocation).visibleFrame, f = w.frame
        w.setFrameOrigin(NSPoint(x: v.midX - f.width / 2, y: v.midY - f.height / 2 + v.height / 10))
        formWindow = w
        bringForward(w)
    }

    func windowWillClose(_ n: Notification) {
        if (n.object as? NSWindow) === formWindow {
            formWindow = nil  // the window, and the Settings view inside it, go away with this
            releaseMemory()
        }
        if (n.object as? NSWindow) === translatorWindow {
            (translatorWindow, translatorHost) = (nil, nil)
            // Once dragged out, a popover keeps showing its content in that (now closed) window, so
            // it would "open" invisibly. Use a fresh one.
            (closingSince, reopenAfterClose) = (nil, false)
            resetPopover()
            model.clear()
            releaseMemory()
        }
    }

    /// Once the translator or Settings has closed and torn down, hand the memory the frameworks freed
    /// back to macOS. The allocator would otherwise keep it for reuse.
    func releaseMemory() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { malloc_zone_pressure_relief(nil, 0) }
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    /// The newer NSApp.activate() is only a request that macOS often turns down for a menu bar app
    /// (e.g. right after a screenshot), so this uses the older call and also orders the window front.
    func bringForward(_ w: NSWindow?) {
        NSApp.activate(ignoringOtherApps: true)
        w?.orderFrontRegardless()
        w?.makeKey()
    }

    static func screen(containing point: NSPoint) -> NSScreen {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: Menus

    /// Outline magnifier with 文 in the lens, a template image so the menu bar tints it.
    static func menuBarIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            let c = NSPoint(x: 7.25, y: 7.25), r: CGFloat = 5.9
            NSColor.black.setStroke()
            let lens = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            lens.lineWidth = 1.4
            lens.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: c.x + r * 0.74, y: c.y + r * 0.74))
            handle.line(to: NSPoint(x: 16.4, y: 16.4))
            handle.lineWidth = 2.3
            handle.lineCapStyle = .round
            handle.stroke()
            let glyph = NSAttributedString(string: "文", attributes: [
                .font: NSFont.systemFont(ofSize: 7.4, weight: .semibold),
                .foregroundColor: NSColor.black,
            ])
            let s = glyph.size()
            glyph.draw(at: NSPoint(x: c.x - s.width / 2, y: c.y - s.height / 2))
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "picoTranslator"
        return img
    }

    /// Esc closes the translator, popover or window. Caught before the text box, which would swallow it,
    /// except while an input method (e.g. Pinyin) has unconfirmed text: then Esc cancels that as usual.
    func installEscapeToClose() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard e.keyCode == 53, let self else { return e }
            let handled = MainActor.assumeIsolated {
                guard let w = e.window, !((w.firstResponder as? NSTextView)?.hasMarkedText() ?? false) else { return false }
                if w === translatorWindow { w.performClose(nil); return true }
                if popover.isShown, w === popover.contentViewController?.view.window { popover.close(); return true }
                return false
            }
            return handled ? nil : e
        }
    }

    /// Menu bar apps have no menu, so ⌘C/⌘V/⌘A/⌘Z/⌘W would do nothing without this hidden one.
    func installEditMenu() {
        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let main = NSMenu()
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }
}
