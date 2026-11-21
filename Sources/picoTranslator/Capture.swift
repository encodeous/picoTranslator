import AppKit
import ScreenCaptureKit
import UniformTypeIdentifiers
import Vision

/// A screenshot of an area the user selects (our own overlay, then ScreenCaptureKit), followed by
/// text recognition in a helper process. Two steps, so the popover can open with a spinner as soon
/// as the area is selected.
@MainActor enum Capture {
    private static let prefix = "picotranslator-"
    private static var warmUp: Process?

    /// `area` is the selected area in screen points (AppKit coordinates).
    enum Shot { case image(URL, area: CGRect), cancelled, failed }
    /// `bounds` is where the text is in the image, as fractions of its size from the bottom left (as
    /// Vision has it): see `rect(of:in:)`.
    enum Reading { case text(String, bounds: CGRect?), noText, timedOut, failed }

    /// The box around the text on screen, from its `bounds` in the image of `area`. A little bigger
    /// than Vision's, which hugs the letters, so the popover's arrow doesn't touch them.
    nonisolated static func rect(of bounds: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: area.minX + bounds.minX * area.width, y: area.minY + bounds.minY * area.height,
               width: bounds.width * area.width, height: bounds.height * area.height).insetBy(dx: -2, dy: -4)
    }

    /// Lets the user select an area and saves it as an image.
    static func screenshot() async -> Shot {
        guard let area = await AreaPicker.pick() else { return .cancelled }
        try? await Task.sleep(for: .milliseconds(50))  // let the overlay leave the screen
        // ScreenCaptureKit uses display space: points down from the top-left of the main display.
        let main = NSScreen.screens[0].frame
        let rect = CGRect(x: area.minX, y: main.maxY - area.maxY, width: area.width, height: area.height)
        let image: CGImage? = await withCheckedContinuation { c in
            SCScreenshotManager.captureImage(in: rect) { image, _ in c.resume(returning: image) }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString + ".png")
        guard let image, let file = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return .failed }
        CGImageDestinationAddImage(file, image, nil)
        return CGImageDestinationFinalize(file) ? .image(url, area: area) : .failed
    }

    /// Reads the text in the image with `TextReader`, then deletes the image.
    ///
    /// With nothing cached (a fresh install, a macOS update), macOS first spends about 30 s compiling
    /// its text model, and longer for a script it hasn't compiled yet, such as Arabic. A second helper
    /// would compile it again on its own, making both slower, so this waits for the launch warm-up
    /// first. The caller says what's going on after 3 s.
    static func text(in url: URL) async -> Reading {
        let start = Date.now
        while warmUp?.isRunning == true, Date.now.timeIntervalSince(start) < 60 {
            try? await Task.sleep(for: .milliseconds(100))
        }
        warmUp = nil
        let deadline = start.addingTimeInterval(90)
        var reading = await read(url, until: deadline)
        // Vision's model can fail to load for the rest of a process (E5RT error 13): a fresh helper usually works.
        if case .failed = reading, deadline.timeIntervalSinceNow > 5 { reading = await read(url, until: deadline) }
        if case .timedOut = reading {} else { try? FileManager.default.removeItem(at: url) }
        return reading
    }

    /// macOS keeps its compiled text model as a cache, and doesn't save caches when the disk is nearly
    /// full, so it compiles the model again for every screenshot. This is the space macOS allows for
    /// such files: 0 on a disk with 3.8 GB free, when the model wasn't being saved. Apple publishes no
    /// cutoff, hence a generous 1 GB.
    nonisolated static var lowOnStorage: Bool {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForOpportunisticUsageKey])
        return values?.volumeAvailableCapacityForOpportunisticUsage.map { $0 < 1_000_000_000 } ?? false
    }

    /// One helper run. A helper still going at the deadline is given another minute, so a compile in
    /// progress is saved for the next screenshot, then stopped, and the image deleted.
    private static func read(_ url: URL, until deadline: Date) async -> Reading {
        let p = process([TextReader.readFlag, url.path])
        let out = Pipe()
        p.standardOutput = out
        guard (try? p.run()) != nil else { return .failed }
        let output = out.fileHandleForReading, helper = Unchecked(p)
        let reading = await withCheckedContinuation { (c: CheckedContinuation<Reading, Never>) in
            let once = Once(c)
            // Read while the helper runs: a full pipe would otherwise block it from exiting.
            DispatchQueue.global(qos: .userInitiated).async {
                let data = output.readDataToEndOfFile()
                helper.value.waitUntilExit()
                guard helper.value.terminationStatus == 0 else { return once.resume(.failed) }  // crashed, or Vision failed
                guard let result = try? JSONDecoder().decode(TextReader.Result.self, from: data) else { return once.resume(.failed) }
                once.resume(result.text.isEmpty ? .noText : .text(result.text, bounds: result.bounds))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + max(deadline.timeIntervalSinceNow, 1)) { once.resume(.timedOut) }
        }
        if case .timedOut = reading {
            Task {
                try? await Task.sleep(for: .seconds(60))
                if p.isRunning { p.terminate(); try? await Task.sleep(for: .seconds(1)) }
                try? FileManager.default.removeItem(at: url)
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
        let p = process([TextReader.warmUpFlag])
        if (try? p.run()) != nil { warmUp = p }
    }

    private final class Unchecked<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
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
    /// The overlay is up. The capture shortcut is ignored meanwhile, or a second overlay would stack on top.
    private(set) static var isActive = false

    /// The selected area in screen points (AppKit coordinates), or nil if cancelled.
    static func pick() async -> CGRect? {
        isActive = true
        defer { isActive = false }
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
            // On failure, exit with an error and keep the image, so the app can try again with a fresh helper.
            guard let image = CGImageSourceCreateWithURL(url as CFURL, nil).flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }),
                  let result = recognize(enlarged(image)), let json = try? JSONEncoder().encode(result) else { exit(1) }
            try? FileManager.default.removeItem(at: url)
            FileHandle.standardOutput.write(json)
            return true
        }
        if args.count == 2, args[1] == warmUpFlag {
            if let image = sampleImage() { _ = recognize(image) }
            return true
        }
        return false
    }

    /// What the helper reports to the app.
    struct Result: Codable {
        var text: String
        var bounds: CGRect?  // all the text together, in Vision's normalized coordinates
    }

    /// The text as paragraphs (see `Paragraphs`), and where it is, or nil if Vision failed.
    static func recognize(_ image: CGImage) -> Result? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        // Detection judges a line by how it starts, so "picoTranslator真的非常轻" read as English and the
        // Chinese was lost. Listing Chinese, Japanese and Korean first fixes that when they're most of
        // the line, and Latin text still reads the same.
        request.recognitionLanguages = ["zh-Hans", "zh-Hant", "ja-JP", "ko-KR", "en-US"]
        do { try VNImageRequestHandler(cgImage: image).perform([request]) } catch {
            FileHandle.standardError.write(Data("Text recognition failed: \(error)\n".utf8))
            return nil
        }
        let (w, h) = (image.width, image.height)
        let found = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { (o.boundingBox, $0.string) } }
        let text = Paragraphs.join(found.map { Paragraphs.Line(text: $0.1, box: VNImageRectForNormalizedRect($0.0, w, h)) })
        let bounds = found.map(\.0).reduce(nil as CGRect?) { $0?.union($1) ?? $1 }
        return Result(text: text, bounds: bounds)
    }

    /// Vision misreads small areas more often: in tests on a sticky note, it dropped characters like 的
    /// in about a quarter of selections, or lost the Chinese entirely. Doubling a small image first
    /// fixed most of those. Large areas are left as they are, to keep memory down.
    private static func enlarged(_ image: CGImage) -> CGImage {
        let (w, h) = (image.width * 2, image.height * 2)
        guard w * h <= 4096 * 4096,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
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
