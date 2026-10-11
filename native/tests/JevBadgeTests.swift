import AppKit

@main
struct JevBadgeTests {
  static func main() {
    precondition(JevBadge.render(nil) == nil)
    precondition(JevBadge.render("") == nil)
    precondition(JevBadge.label(provider:"off",matchesFirst:true) == nil)
    for (provider, first, second) in [("jev", "✦ Jev", "✦ Jev"), ("local", "✦ TT", "✦ TT"),
                                      ("tev-0.8b", "✦ Tev", "✦ Tev"), ("tev-4b", "✦ Tev", "✦ Tev")] {
      precondition(JevBadge.label(provider:provider,matchesFirst:true) == first)
      precondition(JevBadge.label(provider:provider,matchesFirst:false) == second)
      for label in [first,second] {
        let badge=JevBadge.render(label)!
        precondition(badge.string == " " + label)
        precondition(badge.size().width > 0)
      }
    }
    let actual=JevBadge.render(JevBadge.label(provider:"jev",matchesFirst:true))!
    precondition(actual.string == " ✦ Jev")
    precondition(actual.size().width > 0 && actual.size().width < 54)
    let words=["油箱","邮箱","又想","幽香","有想","优享","又像","油香"]
    let base=words.map { ("\($0)  " as NSString).size(withAttributes:[.font:NSFont.systemFont(ofSize:17)]).width }.reduce(0,+)
    let withoutResult=base + words.map { _ in JevBadge.render(nil)?.size().width ?? 0 }.reduce(0,+)
    precondition(withoutResult == base)
    print("JevBadgeTests PASS: no placeholder width; first/second source labels; one real badge width \(actual.size().width)")
  }
}
