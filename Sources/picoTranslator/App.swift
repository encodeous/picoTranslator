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

    // The translator popover, beside a box in an invisible window that covers the screen: the cursor,
    // or for a screenshot the selection and then the text that was read, so it covers neither. Being a
    // rect in a big view, the box can move while the popover is open (see `movePopover`).
    var popover = NSPopover()
    let anchor: NSWindow = {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: true)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]  // also over full-screen apps
        return w
    }()
    var clickMonitor: Any?
    var popoverShownAt = Date.distantPast
    var closingSince: Date?  // set while the popover's close animation runs
    var reopenAfterClose = false
    var reopenAt: NSRect?  // what to reopen it beside, if not the cursor
    var move: (from: NSRect, to: NSRect, start: CFTimeInterval)?  // the popover gliding to the text
    var moveLink: CADisplayLink?

    // The popover once dragged out into its own window, and the Settings / Welcome window.
    var translatorWindow: NSWindow?
    var translatorHost: NSViewController?  // keeps the window's SwiftUI view alive
    var handOff: NSWindow?  // what AppKit was given instead of it (see `detachableWindow`)
    var formWindow: NSWindow?

    var captureID = 0  // only the newest screenshot may fill the translator

    func applicationDidFinishLaunching(_: Notification) {
        item.button?.image = Self.menuBarIcon()
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: String(localized: "About picoTranslator"), action: #selector(about), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit picoTranslator"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        if let w = translatorWindow { bringForward(w) } else { openSettings() }  // the Dock icon is there for the window
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
        guard !AreaPicker.isActive else { return }  // already selecting
        if popover.isShown { popover.close() }  // keep it out of the screenshot
        model.warmUp()  // the translation model loads while the user selects
        Task {
            let shot = await Capture.screenshot()
            if case .cancelled = shot { return }
            // Counted only once an area is selected, so cancelling one doesn't drop the one before.
            captureID += 1
            let id = captureID
            if translatorWindow == nil { model.clear() }
            model.detectOnce = true  // a screenshot can be in any language: detect it (without saving that choice)
            guard case .image(let image, let area) = shot else {
                showTranslator()
                return model.showMessage(String(localized: "Couldn't take the screenshot. Try again."))
            }
            // Open right away with a spinner, beside the selection: reading can take a while if macOS has
            // to load its model first. Once read, it moves up to the edge of the text itself.
            model.reading = true
            showTranslator(beside: area)
            let slow = Task {  // after 3 s, say that macOS is preparing text recognition
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, id == captureID, model.reading else { return }
                (model.slowReading, model.lowStorage) = (true, Capture.lowOnStorage)
            }
            let reading = await Capture.text(in: image)
            slow.cancel()
            // Drop the result if a newer screenshot took over, or the translator was closed meanwhile.
            guard id == captureID, model.reading else { return }
            (model.reading, model.slowReading, model.lowStorage) = (false, false, false)
            switch reading {
            case .text(let text, let bounds):
                if let bounds { movePopover(to: Capture.rect(of: bounds, in: area)) }
                model.input = text
                await model.translateNow()
            case .noText:
                model.showMessage(String(localized: "No text found in the selected area."))
            case .timedOut:
                model.showMessage(String(localized: "Reading the text is taking too long. macOS may still be preparing text recognition, so try again in a moment."))
            case .failed:
                model.showMessage(String(localized: "Couldn't read the text. Try again."))
            }
        }
    }

    /// Shows the dragged-out window if there is one, otherwise the popover beside `box` (screen
    /// coordinates), or else at the mouse cursor: below it, or above when there's more room above.
    /// AppKit shifts it sideways near the screen's edges.
    func showTranslator(beside box: NSRect? = nil) {
        if let w = translatorWindow { return bringForward(w) }
        if popover.isShown {
            if let w = popover.contentViewController?.view.window, w.isVisible {
                if let box { movePopover(to: box) }
                return bringForward(w)
            }
            // Shown on paper only (e.g. after being dragged out): close it, keeping the model, and reopen.
            (reopenAfterClose, reopenAt) = (true, box)
            return closePopoverNow()
        }
        // Mid-close: show once the animation ends. Time-limited, in case the end never arrives.
        if let t = closingSince, Date.now.timeIntervalSince(t) < 0.5 { (reopenAfterClose, reopenAt) = (true, box); return }

        model.warmUp()
        let mouse = NSEvent.mouseLocation
        let target = box ?? NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let screen = Self.screen(containing: NSPoint(x: target.midX, y: target.midY))
        let visible = screen.visibleFrame
        let below = target.minY - visible.minY, above = visible.maxY - target.maxY
        let edge: NSRectEdge = below >= 480 || below >= above ? .minY : .maxY
        model.maxHeight = max(200, min(720, (edge == .minY ? below : above) - 24))  // the view grows up to this

        let host = NSHostingController(rootView: TranslatorView(m: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host  // the SwiftUI view exists only while the popover is open
        anchor.setFrame(screen.frame, display: false)
        anchor.orderFrontRegardless()
        popover.show(relativeTo: anchorRect(for: target), of: anchor.contentView!, preferredEdge: edge)
        popoverShownAt = .now
        if let w = popover.contentViewController?.view.window {
            // Above other apps and on every Space, even if macOS doesn't let the app activate.
            w.level = .popUpMenu
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            bringForward(w)
        }
        // Close at once on a click anywhere outside the app (another app, display or the desktop).
        removeClickMonitor()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.popover.close() }
        }
    }

    /// Moves the open popover beside another box on the same screen, gliding there (see `stepMove`).
    func movePopover(to box: NSRect) {
        guard translatorWindow == nil,  // dragged out: the user put it where they want it
              popover.isShown, anchor.isVisible, NSMouseInRect(NSPoint(x: box.midX, y: box.midY), anchor.frame, false),
              let view = anchor.contentView else { return }
        let rect = anchorRect(for: box), now = popover.positioningRect
        guard abs(rect.minX - now.minX) + abs(rect.minY - now.minY) + abs(rect.maxX - now.maxX) + abs(rect.maxY - now.maxY) > 4
        else { return }
        stopMove()
        move = (popover.positioningRect, rect, CACurrentMediaTime())
        let link = view.displayLink(target: self, selector: #selector(stepMove))
        link.add(to: .main, forMode: .common)
        moveLink = link
    }

    /// AppKit moves a popover in one jump when its positioning rect changes, so this moves the rect a
    /// little every frame instead, slowing down toward the end. Following the rect, the popover also
    /// keeps the right place if it grows meanwhile (the translation arriving).
    @objc func stepMove(_ link: CADisplayLink) {
        guard translatorWindow == nil, popover.isShown, let move else { return stopMove() }
        let t = min((link.targetTimestamp - move.start) / 0.25, 1)
        let eased = 1 - pow(1 - t, 3)
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * eased }
        popover.positioningRect = NSRect(x: mix(move.from.minX, move.to.minX), y: mix(move.from.minY, move.to.minY),
                                         width: mix(move.from.width, move.to.width), height: mix(move.from.height, move.to.height))
        if t >= 1 { stopMove() }
    }

    func stopMove() {
        moveLink?.invalidate()
        (moveLink, move) = (nil, nil)
    }

    /// A box on screen, in the anchor window's view.
    func anchorRect(for box: NSRect) -> NSRect { box.offsetBy(dx: -anchor.frame.minX, dy: -anchor.frame.minY) }

    func applicationDidBecomeActive(_: Notification) {
        if popover.isShown { popover.contentViewController?.view.window?.makeKey() }
    }

    /// Switching apps (e.g. ⌘-Tab) closes the popover. Focus can flicker back to the previous app just
    /// after a screenshot, so the first second after opening doesn't count.
    func applicationDidResignActive(_: Notification) {
        model.stopRecording()  // shortcuts can't be recorded from another app; turn them back on
        if popover.isShown, Date.now.timeIntervalSince(popoverShownAt) > 1 { popover.close() }
    }

    /// A popover that was dragged out never reports closing, so its monitor is also removed here.
    func resetPopover() {
        removeClickMonitor()
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

    func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    func popoverDidClose(_: Notification) {
        stopMove()
        closingSince = nil
        removeClickMonitor()
        popover.contentViewController = nil
        anchor.orderOut(nil)
        if reopenAfterClose {
            let box = reopenAt
            (reopenAfterClose, reopenAt) = (false, nil)
            showTranslator(beside: box)
        } else if translatorWindow == nil {  // unless it was dragged out into a window
            model.clear()
            resetPopover()  // a fresh one next time, so this one's window and views are freed
            releaseMemory()
        }
    }

    func popoverShouldDetach(_: NSPopover) -> Bool { true }

    /// Dragging the popover away turns it into this window: Liquid Glass, no title bar showing, and an ⓧ
    /// drawn by the view. Resizable, draggable anywhere. AppKit asks for it as the drag starts; it takes
    /// the popover's place and the drag right then (see `TranslatorWindow.takeOver`).
    func detachableWindow(for popover: NSPopover) -> NSWindow? {
        stopMove()  // it's the user's to move now
        guard let popoverWindow = popover.contentViewController?.view.window, let view = popover.contentViewController?.view
        else { return nil }
        let content = popover.contentSize
        // Opened at the popover's height, so its first frame lays out like the popover did.
        let host = NSHostingController(rootView: TranslatorView(m: model, height: content.height) { [weak self] in
            self?.translatorWindow?.close()
        })
        host.sizingOptions = []  // the window sets the size and the view fills it, not the other way round
        let glass = NSGlassEffectView()
        glass.cornerRadius = 16
        glass.contentView = host.view
        // The view fills the whole window, title bar included (hidden), so the window's frame, not just
        // the area below the title bar, is the popover's content size.
        let w = TranslatorWindow(contentRect: NSRect(origin: .zero, size: content),
                                 styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.setFrame(NSRect(origin: .zero, size: content), display: false)
        w.contentView = glass
        w.isOpaque = false
        w.backgroundColor = .clear
        w.title = "picoTranslator"
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        for b in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(b)?.isHidden = true }
        w.isMovableByWindowBackground = true
        w.collectionBehavior = .moveToActiveSpace  // a shortcut brings it to the current Space
        w.contentMinSize = NSSize(width: min(300, content.width), height: min(150, content.height))
        w.isReleasedWhenClosed = false
        w.animationBehavior = .none  // it simply takes the popover's place
        w.delegate = self
        glass.layoutSubtreeIfNeeded()  // draw now, so the window never shows an empty first frame
        w.displayIfNeeded()
        (translatorWindow, translatorHost) = (w, host)

        w.takeOver(at: popoverWindow.convertToScreen(view.convert(view.bounds, to: nil))) { [weak self, weak w] in
            // The drag has ended. While the window is open, the app has a Dock icon (and ⌘-Tab), so the
            // window can be found again.
            NSApp.setActivationPolicy(.regular)
            self?.bringForward(w)
        }
        // The popover disappears right now, with no fade (AppKit fades it out as it detaches unless
        // `animates` is off), and is closed once AppKit is done asking for the window.
        popover.animates = false
        popoverWindow.animationBehavior = .none
        popoverWindow.alphaValue = 0
        popoverWindow.orderOut(nil)
        anchor.orderOut(nil)
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated {
                self?.closePopoverNow()
                self?.anchor.orderOut(nil)
            }
        }
        // AppKit gets a stand-in that's never seen: as its own drag ends, it moves, empties and orders the
        // window it was given, which sometimes put the real one in the wrong place.
        let standIn = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1, height: 1), styleMask: .borderless, backing: .buffered, defer: true)
        standIn.alphaValue = 0
        standIn.ignoresMouseEvents = true
        standIn.isReleasedWhenClosed = false
        handOff = standIn
        return standIn
    }

    // MARK: Windows

    @objc func openSettings() { showForm(SetupForm(m: model), title: String(localized: "picoTranslator Settings")) }

    /// Shown at every launch until Done is pressed, since granting Screen Recording relaunches the app.
    func openWelcome() {
        showForm(WelcomeView(m: model) { [weak self] in
            UserDefaults.standard.set(true, forKey: "setupDone")
            self?.formWindow?.close()
        }, title: String(localized: "Welcome"), fullSize: true)
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
            NSApp.setActivationPolicy(.accessory)  // back to the menu bar only
            handOff?.orderOut(nil)
            handOff = nil
            // Once dragged out, a popover keeps showing its content in that (now closed) window, so
            // it would "open" invisibly. Use a fresh one.
            (closingSince, reopenAfterClose, reopenAt) = (nil, false, nil)
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

    /// Menu bar apps have no menu, so ⌘C/⌘V/⌘A/⌘Z/⌘W would do nothing without this one. It shows only while
    /// the translator window is open (the app has a Dock icon then), after the app's own menu.
    func installEditMenu() {
        let edit = NSMenu()
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let app = NSMenu()
        app.addItem(withTitle: String(localized: "About picoTranslator"), action: #selector(about), keyEquivalent: "").target = self
        app.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: String(localized: "Quit picoTranslator"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let main = NSMenu()
        main.addItem(withTitle: "picoTranslator", action: nil, keyEquivalent: "").submenu = app  // the first menu is the app's
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit
        NSApp.mainMenu = main
    }
}

/// The translator once dragged out of its popover.
final class TranslatorWindow: NSWindow {
    private var drag: (cursor: NSPoint, origin: NSPoint)?  // where the cursor and the window were as it took over
    private var link: CADisplayLink?
    private var done: (() -> Void)?

    /// AppKit asks for a window as the user starts dragging the popover away, then would drag the popover
    /// and only show the window when the drag ends. Instead this shows at once, in the popover's place
    /// (the popover is closed), and follows the cursor until the button is released.
    func takeOver(at content: NSRect, done: @escaping () -> Void) {
        setFrame(content, display: true)
        orderFrontRegardless()
        (drag, self.done) = ((NSEvent.mouseLocation, content.origin), done)
        link = contentView?.displayLink(target: self, selector: #selector(follow))
        link?.add(to: .main, forMode: .common)
    }

    @objc private func follow(_ link: CADisplayLink) {
        guard let drag else { return link.invalidate() }
        let m = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: drag.origin.x + m.x - drag.cursor.x, y: drag.origin.y + m.y - drag.cursor.y))
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
        link.invalidate()
        (self.link, self.drag) = (nil, nil)
        done?()
        done = nil
    }

    /// While the user drags the window onto another display, macOS moves a window with a title bar to a
    /// "safe" place there (`NSWindow(NSScreenLayout)`), away from the cursor, which then stayed offset.
    /// Mid-drag, it stays where the user puts it.
    override func setFrame(_ r: NSRect, display: Bool, animate: Bool) {
        if NSEvent.pressedMouseButtons & 1 != 0, r.size == frame.size, r.origin != frame.origin { return }
        super.setFrame(r, display: display, animate: animate)
    }

    /// Kept below the menu bar of the screen it's on, the window was pushed off the cursor too when dragged
    /// onto a display arranged higher or lower. It goes where it's dragged, as long as some of it stays on
    /// a screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        NSScreen.screens.contains { $0.frame.intersects(frameRect) } ? frameRect : super.constrainFrameRect(frameRect, to: screen)
    }
}
