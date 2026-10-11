import Foundation

struct JevTextPosition: Equatable {
    let client: String
    let selected: NSRange
    let marked: NSRange

    static func valid(_ range: NSRange) -> Bool {
        range.location != NSNotFound && range.length != NSNotFound &&
        range.location >= 0 && range.length >= 0 && range.length <= Int.max - range.location
    }

    var base: Int? {
        if Self.valid(marked), marked.length > 0 { return marked.location }
        return Self.valid(selected) ? selected.location : nil
    }
}

struct JevTextSlice {
    let text: String
    let range: NSRange
}

struct JevLineSnapshot: Equatable {
    let position: JevTextPosition
    let context: String
    let source: String
    let readReason: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.position == rhs.position && lhs.source == rhs.source &&
        lhs.context.utf16.elementsEqual(rhs.context.utf16)
    }
}

enum JevLineContext {
    static let readLimit = 512
    static let characterLimit = 80

    static func currentLine(_ text: String) -> String {
        let start = text.lastIndex(where: \.isNewline).map { text.index(after: $0) } ?? text.startIndex
        return String(text[start...].suffix(characterLimit))
    }

    static func resolve(position: JevTextPosition, confirmedPrefix: String,
                        read: (NSRange) -> JevTextSlice?,
                        verifiedCommitted: () -> String?) -> JevLineSnapshot {
        var reason = "missing_cursor"
        var preceding: String?
        if let base = position.base {
            if base == 0 {
                preceding = ""
                reason = "line_start"
            } else {
                let requested = NSRange(location: max(0, base - readLimit), length: min(base, readLimit))
                if let slice = read(requested) {
                    preceding = prefix(slice, endingAt: base, requested: requested)
                    reason = preceding == nil ? "invalid_text_range" : "read"
                } else { reason = "text_unavailable" }
            }
        }
        let source: String
        if preceding != nil {
            source = "current_line"
        } else if let committed = verifiedCommitted(), !committed.isEmpty {
            preceding = committed
            source = "verified_commits"
        } else {
            source = "no_context"
        }
        let context = currentLine((preceding.map(currentLine) ?? "") + confirmedPrefix)
        return JevLineSnapshot(position: position, context: context,
                               source: source, readReason: reason)
    }

    private static func prefix(_ slice: JevTextSlice, endingAt base: Int, requested: NSRange) -> String? {
        guard JevTextPosition.valid(slice.range), slice.range.length == slice.text.utf16.count,
              slice.range.length <= readLimit * 2, slice.range.location < base,
              NSMaxRange(slice.range) >= base else { return nil }
        let offset = base - slice.range.location
        guard offset <= slice.text.utf16.count else { return nil }
        let utf16End = slice.text.utf16.index(slice.text.utf16.startIndex, offsetBy: offset)
        guard let end = String.Index(utf16End, within: slice.text),
              end == slice.text.endIndex || slice.text.indices.contains(end) else { return nil }
        var text = String(slice.text[..<end])
        // A capped read may begin within a combining sequence. Discard that edge,
        // rather than treating an incomplete grapheme as a preceding character.
        if slice.range.location == requested.location, requested.location > 0, !text.isEmpty { text.removeFirst() }
        return currentLine(text)
    }
}
