import CoreGraphics

/// Vision reads a screenshot one line at a time. A sentence that wraps over two lines, translated as
/// two lines, comes out wrong ("moved to / because Thursday is a holiday"), so lines that continue a
/// paragraph are joined back together first.
enum Paragraphs {
    /// A recognized line, with its box in image pixels (origin at the bottom left, as Vision has it).
    struct Line {
        var text: String
        var box: CGRect
    }

    /// The lines, in Vision's reading order, as paragraphs separated by newlines.
    static func join(_ lines: [Line]) -> String {
        var paragraphs: [String] = []
        var current = "", previous: Line?
        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let previous, continues(previous, line, text: text) {
                current = joined(current, text)
            } else {
                if !current.isEmpty { paragraphs.append(current) }
                current = text
            }
            previous = line
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs.joined(separator: "\n")
    }

    /// Whether `b` is the next line of `a`'s paragraph: just below it, starting in the same place, in
    /// the same size of text, and not a new list item. And `a` runs on to about the paragraph's width:
    /// a line that stops well short is a paragraph's last.
    static func continues(_ a: Line, _ b: Line, text: String) -> Bool {
        let h = max(a.box.height, b.box.height)
        guard h > 0 else { return false }
        let gap = a.box.minY - b.box.maxY
        return gap > -0.3 * h && gap < 0.8 * h
            && abs(a.box.minX - b.box.minX) < h
            && min(a.box.height, b.box.height) / h > 0.75
            && a.box.maxX > b.box.maxX - 5 * h
            && !startsListItem(text)
    }

    private static func startsListItem(_ text: String) -> Bool {
        if let first = text.first, "•‣◦▪●○■□–—-*·".contains(first) { return true }
        return text.prefix(4).contains { $0 == "." || $0 == ")" } && text.first?.isNumber == true  // "1." "2)"
    }

    /// Chinese and Japanese have no spaces between words, Korean and Latin scripts do. A word
    /// hyphenated across the line break loses its hyphen.
    static func joined(_ a: String, _ b: String) -> String {
        if a.hasSuffix("-"), a.dropLast().last?.isLetter == true, b.first?.isLowercase == true { return a.dropLast() + b }
        if let x = a.unicodeScalars.last, let y = b.unicodeScalars.first, noSpace(x) || noSpace(y) { return a + b }
        return a + " " + b
    }

    /// Chinese characters, kana and full-width punctuation such as 。，「」.
    private static func noSpace(_ s: Unicode.Scalar) -> Bool {
        s.properties.isIdeographic || (0x3000...0x30FF).contains(s.value) || (0xFF00...0xFFEF).contains(s.value)
    }
}
