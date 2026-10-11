import AppKit

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  precondition(condition(), "JevLanguageIndicatorTests: \(message)")
}

private func testTransitions() {
  expect(JevLanguageIndicatorPolicy.label(asciiBefore: false, asciiAfter: true,
                                         changedModifiers: .shift) == "英文", "Chinese to English")
  expect(JevLanguageIndicatorPolicy.label(asciiBefore: true, asciiAfter: false,
                                         changedModifiers: .shift) == "中文", "English to Chinese")
  for ascii in [false, true] {
    expect(JevLanguageIndicatorPolicy.label(asciiBefore: ascii, asciiAfter: ascii,
                                           changedModifiers: .shift) == nil,
           "Shift down/up and Shift+letter do not announce an unchanged Rime mode")
    for changes: NSEvent.ModifierFlags in [[], .capsLock, .control, .option, .command, [.shift, .capsLock]] {
      expect(JevLanguageIndicatorPolicy.label(asciiBefore: ascii, asciiAfter: !ascii,
                                             changedModifiers: changes) == nil,
             "unrelated modifiers and Caps Lock must not announce Shift feedback")
    }
  }

  // Rime normally toggles on release; only the transition gets feedback.
  let events: [(Bool, Bool)] = [(false, false), (false, true), (true, true), (true, false)]
  let labels = events.compactMap {
    JevLanguageIndicatorPolicy.label(asciiBefore: $0.0, asciiAfter: $0.1, changedModifiers: .shift)
  }
  expect(labels == ["英文", "中文"], "each actual mode change is announced once")
}

private func testPlacement() {
  let visible = NSRect(x: 0, y: 24, width: 1440, height: 852)
  let caret = NSRect(x: 600, y: 400, width: 0, height: 20)
  expect(JevLanguageIndicatorPolicy.validCaret(caret) == caret, "zero-width caret is valid")
  let nearby = JevLanguageIndicatorPolicy.frame(near: caret, in: visible)
  expect(nearby.midX == caret.midX && nearby.minY > caret.maxY,
         "prefer above the caret, away from the usual candidate list")
  let topCaret = NSRect(x: 600, y: visible.maxY - 20, width: 1, height: 20)
  let below = JevLanguageIndicatorPolicy.frame(near: topCaret, in: visible)
  expect(below.maxY < topCaret.minY, "flip below when the caret is at the screen top")

  let fallback = JevLanguageIndicatorPolicy.frame(near: nil, in: visible)
  expect(fallback.midX == visible.midX && fallback.midY < visible.midY,
         "missing caret uses bottom center")
  for invalid in [NSRect.zero, NSRect(x: 10, y: 10, width: 1, height: 0),
                  NSRect(x: CGFloat.nan, y: 10, width: 1, height: 20),
                  NSRect(x: 10, y: CGFloat.infinity, width: 1, height: 20)] {
    expect(JevLanguageIndicatorPolicy.validCaret(invalid) == nil, "reject unavailable caret")
    expect(JevLanguageIndicatorPolicy.frame(near: invalid, in: visible) == fallback,
           "invalid caret uses the same safe fallback")
  }

  for screen in [visible, NSRect(x: -1920, y: -300, width: 1920, height: 1080),
                 NSRect(x: 1440, y: 900, width: 1280, height: 720),
                 NSRect(x: 0, y: 0, width: 50, height: 30)] {
    let corners = [NSPoint(x: screen.minX, y: screen.minY), NSPoint(x: screen.maxX, y: screen.minY),
                   NSPoint(x: screen.minX, y: screen.maxY), NSPoint(x: screen.maxX, y: screen.maxY)]
    for point in corners {
      let frame = JevLanguageIndicatorPolicy.frame(near: NSRect(origin: point, size: NSSize(width: 0, height: 20)),
                                                   in: screen)
      expect(screen.contains(frame), "clamp to visible frame, including external displays and small frames")
    }
    expect(screen.contains(JevLanguageIndicatorPolicy.frame(near: nil, in: screen)), "fallback is also clamped")
  }
}

@main
private enum JevLanguageIndicatorTests {
  static func main() {
    testTransitions()
    testPlacement()
    print("JevLanguageIndicatorTests PASS: actual Shift transitions, suppressed non-toggles/Caps Lock, caret/fallback placement, visible-frame clamping")
  }
}
