import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// A screenshot of an area the user selects (our own overlay, then ScreenCaptureKit), followed by
/// text recognition in a helper process. Two steps, so the popover can open with a spinner as soon
/// as the area is selected.
@MainActor enum Capture {
    private static let prefix = "picotranslator-"

    enum Reading { case text(String), noText, timedOut }

    /// Lets the user select an area and saves it as an image. Returns nil if they cancelled.
    static func screenshot() async -> URL? {
        guard let area = await AreaPicker.pick() else { return nil }
        try? await Task.sleep(for: .milliseconds(50))  // let the overlay leave the screen
        // ScreenCaptureKit uses display space: points down from the top-left of the main display.
        let main = NSScreen.screens[0].frame
        let rect = CGRect(x: area.minX, y: main.maxY - area.maxY, width: area.width, height: area.height)
        let image: CGImage? = await withCheckedContinuation { c in
            SCScreenshotManager.captureImage(in: rect) { image, _ in c.resume(returning: image) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString + ".png")
        guard let image, let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(file, image, nil)
        return CGImageDestinationFinalize(file) ? url : nil
    }

    /// Reads the text in the image with `TextReader`, which also deletes the image. Stops waiting after
    /// 10 s but lets the helper go on for a while: if macOS was still compiling its text model, the
    /// finished compile is then saved for the next screenshot.
    static func text(in url: URL) async -> Reading {
        let p = process([TextReader.readFlag, url.path])
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else {
            try? FileManager.default.removeItem(at: url)
            return .noText
        }
        let output = out.fileHandleForReading
        let reading = await withCheckedContinuation { (c: CheckedContinuation<Reading, Never>) in
            let once = Once(c)
            // Read while the helper runs: a full pipe would otherwise block it from exiting.
            DispatchQueue.global(qos: .userInitiated).async {
                let text = String(decoding: output.readDataToEndOfFile(), as: UTF8.self)
                once.resume(text.isEmpty ? .noText : .text(text))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { once.resume(.timedOut) }
        }
        if case .timedOut = reading {
            Task {  // give a stuck helper up to two minutes to finish compiling, then stop it
                try? await Task.sleep(for: .seconds(120))
                if p.isRunning { p.terminate() }
            }
        }
        return reading
    }

    /// At launch: delete screenshots a crashed helper left behind, and read a tiny image so the text
    /// model is compiled and cached before the first real screenshot.
    static func prepare() {
        let tmp = FileManager.default.temporaryDirectory
        for f in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? [] where f.hasPrefix(prefix) {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(f))
        }
        try? process([TextReader.warmUpFlag]).run()
    }

    /// This app's own binary, started as the text-reading helper.
    private static func process(_ arguments: [String]) -> Process {
        let p = Process()
        p.executableURL = Bundle.main.executableURL
        p.arguments = arguments
        return p
    }

    /// Resumes a continuation once, from whichever of two threads gets there first.
    private final class Once<T>: @unchecked Sendable {
        private var continuation: CheckedContinuation<T, Never>?
        private let lock = NSLock()
        init(_ c: CheckedContinuation<T, Never>) { continuation = c }
        func resume(_ value: sending T) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: value)
        }
    }
}

/// The area selection: a dimmed overlay on every display. Drag to select; Esc, a right-click or a
/// click without dragging cancels.
@MainActor final class AreaPicker {
    private var windows: [NSWindow] = []
    private var continuation: CheckedContinuation<CGRect?, Never>?

    /// The selected area in screen points (AppKit coordinates), or nil if cancelled.
    static func pick() async -> CGRect? {
        let picker = AreaPicker()
        return await withCheckedContinuation { picker.begin($0) }
    }

    private func begin(_ c: CheckedContinuation<CGRect?, Never>) {
        continuation = c
        for screen in NSScreen.screens {
            let w = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.level = .screenSaver
            w.isOpaque = false
            w.backgroundColor = .clear
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            w.acceptsMouseMovedEvents = true
            let view = SelectionView()
            view.finish = { [weak self] area in self?.finish(area) }
            w.contentView = view
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
        // macOS may not let the app activate right away. The overlay is a non-activating panel, so it
        // still gets Esc, and its views set the cursor themselves (see `SelectionView`).
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        (windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows.first)?.makeKey()
        NSCursor.crosshair.set()
    }

    private func finish(_ area: CGRect?) {
        guard let c = continuation else { return }
        continuation = nil
        NSCursor.arrow.set()
        windows.forEach { $0.orderOut(nil) }
        windows = []
        c.resume(returning: area)
    }

    private final class OverlayWindow: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var finish: ((CGRect?) -> Void)?
        private var start: NSPoint?, current: NSPoint?

        private var selection: NSRect? {
            guard let start, let current else { return nil }
            return NSRect(x: min(start.x, current.x), y: min(start.y, current.y),
                          width: abs(current.x - start.x), height: abs(current.y - start.y))
        }

        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }  // works even before the app activates

        // Normally only the active app sets the cursor; an "active always" tracking area lets the
        // overlay show the crosshair even while another app is still in front.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self))
        }
        override func cursorUpdate(with _: NSEvent) { NSCursor.crosshair.set() }
        override func mouseMoved(with _: NSEvent) { NSCursor.crosshair.set() }

        override func mouseDown(with e: NSEvent) {
            start = convert(e.locationInWindow, from: nil)
            current = start
            needsDisplay = true
        }

        override func mouseDragged(with e: NSEvent) {
            NSCursor.crosshair.set()
            current = convert(e.locationInWindow, from: nil)
            needsDisplay = true
        }

        override func mouseUp(with _: NSEvent) {
            guard let area = selection, area.width >= 4, area.height >= 4, let window else { finish?(nil); return }
            finish?(window.convertToScreen(convert(area, to: nil)))
        }

        override func rightMouseDown(with _: NSEvent) { finish?(nil) }
        override func cancelOperation(_: Any?) { finish?(nil) }  // Esc

        override func draw(_: NSRect) {
            NSColor.black.withAlphaComponent(0.15).setFill()
            bounds.fill()
            guard let area = selection else { return }
            NSColor.clear.setFill()
            area.fill(using: .copy)  // the selected area shows undimmed
            NSColor.white.setStroke()
            NSBezierPath(rect: area.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}

/// The helper: this same binary, started with a flag, reads the text and exits. A fresh process per
/// screenshot avoids a recent macOS problem where Vision's accurate model can stay broken for the rest
/// of a process (E5RT error 13), and gives its memory back afterwards. It shares the app's bundle and
/// sandbox container, so it also shares the compiled-model cache.
enum TextReader {
    static let readFlag = "--read-text", warmUpFlag = "--warm-up"

    /// Handles the helper flags. Returns false for a normal launch of the app.
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.count == 3, args[1] == readFlag {
            let url = URL(fileURLWithPath: args[2])
            let text = recognize(VNImageRequestHandler(url: url))
            try? FileManager.default.removeItem(at: url)
            FileHandle.standardOutput.write(Data(text.utf8))
            return true
        }
        if args.count == 2, args[1] == warmUpFlag {
            if let image = sampleImage() { _ = recognize(VNImageRequestHandler(cgImage: image)) }
            return true
        }
        return false
    }

    private static func recognize(_ handler: VNImageRequestHandler) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        // Detection judges a line by how it starts, so "picoTranslator真的非常轻" read as English and the
        // Chinese was lost. Listing Chinese, Japanese and Korean first fixes that, and Latin text still reads the same.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
        try? handler.perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    /// A small image with some English, Chinese and French text, for the warm-up.
    private static func sampleImage() -> CGImage? {
        let (w, h) = (240, 40)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let text = NSAttributedString(string: "Hello 你好 Bonjour", attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 20, nil)])
        ctx.textPosition = CGPoint(x: 8, y: 12)
        CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
        return ctx.makeImage()
    }
}
