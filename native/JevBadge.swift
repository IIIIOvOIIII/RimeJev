import AppKit

struct JevBadge {
  static func label(provider: String, matchesFirst: Bool) -> String? {
    switch provider {
    case "jev": return matchesFirst ? "✦ Jev" : "✦ Jev 推荐"
    case "local": return matchesFirst ? "✦ 本地" : "✦ 本地模型推荐"
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
