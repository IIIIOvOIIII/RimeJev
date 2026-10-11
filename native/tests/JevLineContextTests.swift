import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("JevLineContextTests: \(message)") }
}

private func position(_ base: Int, selected: NSRange? = nil, marked: NSRange? = nil,
                      client: String = "editor") -> JevTextPosition {
    JevTextPosition(client: client, selected: selected ?? NSRange(location: base, length: 0),
                    marked: marked ?? NSRange(location: NSNotFound, length: 0))
}

private func resolve(_ text: String, base: Int? = nil, marked: NSRange? = nil,
                     prefix: String = "", committed: String? = nil) -> JevLineSnapshot {
    let host = text as NSString
    return JevLineContext.resolve(position: position(base ?? host.length, marked: marked),
                                 confirmedPrefix: prefix, read: { range in
        let actual = host.rangeOfComposedCharacterSequences(for: range)
        return JevTextSlice(text: host.substring(with: actual), range: actual)
    }, verifiedCommitted: { committed })
}

@main
private enum JevLineContextTests {
    static func main() {
        // Existing text is usable without any IME-owned commit history or activity clock.
        let pasted = resolve("我现在又想")
        expect(pasted.context == "我现在又想" && pasted.source == "current_line", "pasted prefix")
        expect(resolve("汽车", committed: "错误旧缓存").context == "汽车", "host overrides history")
        expect(resolve("我现在又想继续", base: 5).context == "我现在又想", "exclude text after caret")
        expect(resolve("我现在又想s j后文", base: 8, marked: NSRange(location: 5, length: 3)).context == "我现在又想", "exclude composing pinyin")
        expect(resolve("以前我现在you xiang", base: 15, marked: NSRange(location: 2, length: 13), prefix: "我现在").context == "以前我现在", "confirmed prefix once")
        for separator in ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"] {
            expect(resolve("上一行" + separator + "汽车").context == "汽车", "logical line boundary")
            expect(resolve("上一行" + separator).context.isEmpty, "trailing newline is empty")
        }
        expect(resolve("我现在又想", base: 0, committed: "旧内容").context.isEmpty, "empty line never revives history")
        expect(resolve("我现在又想", base: 2).context == "我现", "replacement starts at selection start")
        expect(resolve("我😀e\u{301}👨‍👩‍👧‍👦想").context == "我😀e\u{301}👨‍👩‍👧‍👦想", "whole graphemes")
        let long = String(repeating: "😀", count: 1000) + "我现在又想"
        expect(resolve(long).context == String(long.suffix(80)), "bounded suffix from long document")
        expect(resolve("文\n", prefix: "已确认").context == "已确认", "composition after newline")

        var readCount = 0, fallbackCount = 0
        let unavailable = JevLineContext.resolve(position: position(5), confirmedPrefix: "", read: { _ in
            readCount += 1; return nil
        }, verifiedCommitted: { fallbackCount += 1; return "上一行\n又想" })
        expect(unavailable.context == "又想" && unavailable.source == "verified_commits", "verified fallback is line bounded")
        expect(readCount == 1 && fallbackCount == 1, "bounded host calls")
        let noText = JevLineContext.resolve(position: position(5), confirmedPrefix: "", read: { _ in nil }, verifiedCommitted: { nil })
        expect(noText.context.isEmpty && noText.source == "no_context", "empty model input allowed")
        let noPosition = JevLineContext.resolve(position: position(NSNotFound), confirmedPrefix: "我现在", read: { _ in
            fatalError("must not query unknown position")
        }, verifiedCommitted: { nil })
        expect(noPosition.context == "我现在", "confirmed prefix without host access")
        let start = JevLineContext.resolve(position: position(0), confirmedPrefix: "", read: { _ in
            fatalError("must not query before document start")
        }, verifiedCommitted: { fatalError("known empty overrides fallback") })
        expect(start.context.isEmpty && start.source == "current_line", "successful empty distinguished")

        for bad in [NSRange(location: -1, length: 0), NSRange(location: 1, length: -1),
                    NSRange(location: Int.max - 1, length: 5), NSRange(location: 0, length: NSNotFound)] {
            expect(position(0, selected: bad).base == nil, "invalid selected range rejected")
        }
        let marked = position(0, selected: NSRange(location: NSNotFound, length: NSNotFound), marked: NSRange(location: 5, length: 2))
        expect(marked.base == 5, "marked range usable without a selected range")

        let slices = [
            JevTextSlice(text: "错误", range: NSRange(location: 0, length: 5)),
            JevTextSlice(text: "旧文", range: NSRange(location: 0, length: 2)),
            JevTextSlice(text: "", range: NSRange(location: 5, length: 0)),
            JevTextSlice(text: "😀", range: NSRange(location: 4, length: 2)),
            JevTextSlice(text: "前", range: NSRange(location: NSNotFound, length: 1))
        ]
        for slice in slices {
            let result = JevLineContext.resolve(position: position(5), confirmedPrefix: "", read: { _ in slice }, verifiedCommitted: { nil })
            expect(result.context.isEmpty && result.readReason == "invalid_text_range", "invalid/missing/split host range rejected")
        }
        let adjusted = JevLineContext.resolve(position: position(6), confirmedPrefix: "", read: { _ in
            JevTextSlice(text: "前😀汽车后", range: NSRange(location: 1, length: 6))
        }, verifiedCommitted: { nil })
        expect(adjusted.context == "前😀汽车", "adjusted range cropped before caret")

        let same = resolve("我现在又想")
        expect(pasted == same, "same stable snapshot")
        expect(pasted != resolve("你现在又想"), "changed text rejects response")
        let another = JevLineSnapshot(position: position(5, client: "other"), context: pasted.context, source: pasted.source, readReason: pasted.readReason)
        expect(pasted != another, "different input client rejects response")
        let moved = JevLineSnapshot(position: position(6), context: pasted.context, source: pasted.source, readReason: pasted.readReason)
        expect(pasted != moved, "same text at different position rejects response")
        let selected = JevLineSnapshot(position: position(5, selected: NSRange(location: 5, length: 2)), context: pasted.context, source: pasted.source, readReason: pasted.readReason)
        expect(pasted != selected, "selection change rejects response")
        let first = JevLineSnapshot(position: position(1), context: "é", source: "current_line", readReason: "read")
        let second = JevLineSnapshot(position: position(1), context: "e\u{301}", source: "current_line", readReason: "read")
        expect(first != second, "compare exact host UTF16, not normalized text")
        print("JevLineContextTests: PASS (existing/pasted text, logical lines, ranges, Unicode, fallback, stale snapshots)")
    }
}
