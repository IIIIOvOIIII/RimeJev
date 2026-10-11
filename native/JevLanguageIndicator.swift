import AppKit

enum JevLanguageIndicatorPolicy {
  static func label(asciiBefore: Bool, asciiAfter: Bool,
                    changedModifiers: NSEvent.ModifierFlags) -> String? {
    guard changedModifiers.contains(.shift), !changedModifiers.contains(.capsLock),
          asciiBefore != asciiAfter else { return nil }
    return asciiAfter ? "英文" : "中文"
  }

  static func validCaret(_ rect: NSRect?) -> NSRect? {
    guard let rect, rect.origin.x.isFinite, rect.origin.y.isFinite,
          rect.width.isFinite, rect.height.isFinite,
          rect.width >= 0, rect.height > 0 else { return nil }
    return rect
  }

  static func frame(near caretRect: NSRect?, in visibleFrame: NSRect) -> NSRect {
    let margin = min(8, max(0, min(visibleFrame.width, visibleFrame.height) / 4))
    let bounds = visibleFrame.insetBy(dx: margin, dy: margin)
    let size = NSSize(width: min(76, bounds.width), height: min(38, bounds.height))
    var origin = NSPoint(x: bounds.midX - size.width / 2, y: bounds.minY + 80)
    if let caret = validCaret(caretRect) {
      origin = NSPoint(x: caret.midX - size.width / 2, y: caret.maxY + 8)
      if origin.y + size.height > bounds.maxY {
        origin.y = caret.minY - size.height - 8
      }
    }
    origin.x = min(max(origin.x, bounds.minX), bounds.maxX - size.width)
    origin.y = min(max(origin.y, bounds.minY), bounds.maxY - size.height)
    return NSRect(origin: origin, size: size)
  }
}

private final class JevLanguagePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

@MainActor
final class JevLanguageIndicator: NSObject {
  static let shared = JevLanguageIndicator()
  private let panel: JevLanguagePanel
  private let label = NSTextField(labelWithString: "")
  private var dismissal: Timer?

  private override init() {
    panel = JevLanguagePanel(contentRect: NSRect(x: 0, y: 0, width: 76, height: 38),
                             styleMask: [.borderless, .nonactivatingPanel],
                             backing: .buffered, defer: true)
    super.init()
    panel.level = .popUpMenu
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    if #available(macOS 13.0, *) {
      panel.collectionBehavior.insert(.canJoinAllApplications)
    }
    panel.animationBehavior = .none
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true

    let background = NSVisualEffectView(frame: panel.contentView?.bounds ?? .zero)
    background.material = .hudWindow
    background.blendingMode = .behindWindow
    background.state = .active
    background.wantsLayer = true
    background.layer?.cornerRadius = 10
    background.layer?.masksToBounds = true
    label.font = .systemFont(ofSize: 17, weight: .medium)
    label.textColor = .labelColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    background.addSubview(label)
    NSLayoutConstraint.activate([
      label.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      label.centerYAnchor.constraint(equalTo: background.centerYAnchor)
    ])
    panel.contentView = background
  }

  func show(label text: String, caretRect: NSRect? = nil) {
    let caret = JevLanguageIndicatorPolicy.validCaret(caretRect)
    let caretScreen = caret.flatMap { rect in
      NSScreen.screens.first { $0.frame.contains(NSPoint(x: rect.midX, y: rect.midY)) }
    }
    guard let screen = caretScreen ?? NSScreen.main ?? NSScreen.screens.first else { return }
    label.stringValue = text
    panel.setFrame(JevLanguageIndicatorPolicy.frame(near: caretScreen == nil ? nil : caret,
                                                   in: screen.visibleFrame), display: true)
    panel.orderFrontRegardless()
    dismissal?.invalidate()
    let timer = Timer(timeInterval: 1, target: self, selector: #selector(hide), userInfo: nil, repeats: false)
    dismissal = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  @objc private func hide() {
    dismissal = nil
    panel.orderOut(nil)
  }
}
