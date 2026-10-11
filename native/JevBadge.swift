import AppKit

struct JevBadge {
  static func label(provider: String, matchesFirst: Bool) -> String? {
    switch provider {
    case "jev": return "✦ Jev"
    case "local": return "✦ TT"
    case "tev-0.8b", "tev-4b": return "✦ Tev"
    default: return nil
    }
  }

  static func render(_ label: String?) -> NSAttributedString? {
    guard let label, !label.isEmpty else { return nil }
    return NSAttributedString(string: " " + label, attributes: [
      .font: NSFont.systemFont(ofSize: 12),
      .foregroundColor: NSColor(srgbRed:0.725, green:0.804, blue:0.863, alpha:1)
    ])
  }
}
