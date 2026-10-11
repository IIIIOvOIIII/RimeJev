import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("JevCommittedContextTests failed: \(message)") }
}

private func expectCleared(_ context: JevCommittedContext, reason: String) {
    expect(context.text.isEmpty, "rejection clears text")
    expect(context.expectedEnd == nil, "rejection clears cursor")
    expect(context.clientIdentity == nil, "rejection clears client")
    expect(context.lastCheckReason == reason, "preserve diagnostic: \(reason)")
}

private func committedContext() -> JevCommittedContext {
    var context = JevCommittedContext()
    context.commit("我现在", at: 5, client: "editor", now: 0)
    return context
}

private func testDeferredCommit() {
    var context = committedContext()
    expect(context.verify(client: "editor", base: 5, preceding: "旧内容", now: 0,
                          deferredCommit: true), "same commit refresh tolerates stale host range")
    expect(context.text == "我现在" && context.expectedEnd == 8, "fresh commit retained")
    expect(context.lastCheckReason == "pending_commit", "deferred diagnostic")
    context.noteActivity(now: 1)
    expect(context.verify(client: "editor", base: 8, preceding: "我现在", now: 1),
           "next key validates updated host range")
    expect(context.lastCheckReason == "verified", "later verification is required")


    var quick = committedContext()
    quick.noteActivity(now: 0.05)
    expect(quick.verify(client: "editor", base: 5, preceding: "旧内容", now: 0.05,
                        deferredCommit: true), "fast next key can wait for host acknowledgement")
    quick.noteActivity(now: 0.20)
    expect(!quick.mayDeferHostCheck(now: 0.25), "typing does not extend the host-ack grace period")
    expect(quick.verify(client: "editor", base: 8, preceding: "我现在", now: 0.26),
           "request dispatch validates the acknowledged host state")
    var unacknowledged = committedContext()
    expect(!unacknowledged.verify(client: "editor", base: 5, preceding: "旧内容", now: 0.25,
                                  deferredCommit: true), "stale host cannot bypass validation after 250ms")
    expectCleared(unacknowledged, reason: "cursor_mismatch")

    var stale = committedContext()
    expect(stale.verify(client: "editor", base: nil, preceding: nil, now: 0,
                        deferredCommit: true), "immediate unavailable ranges may be deferred")
    expect(!stale.verify(client: "editor", base: 5, preceding: "旧内容", now: 1),
           "deferral does not persist into a later check")
    expectCleared(stale, reason: "cursor_mismatch")
}

private func testRejections() {
    let cases: [(String?, Int?, String?, String)] = [
        ("editor", 7, "我现在", "cursor_mismatch"),
        ("editor", 8, "我过去", "text_mismatch"),
        ("other", 8, "我现在", "client_mismatch"),
        (nil, 8, "我现在", "client_mismatch"),
        ("editor", nil, "我现在", "missing_cursor"),
        ("editor", 8, nil, "missing_text")
    ]
    for (client, base, preceding, reason) in cases {
        var context = committedContext()
        expect(!context.verify(client: client, base: base, preceding: preceding, now: 1), reason)
        expectCleared(context, reason: reason)
        expect(!context.verify(client: "editor", base: 8, preceding: "我现在", now: 2),
               "cleared context stays empty")
        expect(context.lastCheckReason == reason, "empty checks preserve rejection reason")
    }
    var context = committedContext()
    expect(!context.verify(client: "other", base: nil, preceding: nil, now: 0,
                           deferredCommit: true), "deferral cannot bypass client identity")
    expectCleared(context, reason: "client_mismatch")
}

private func testInactivity() {
    var menu = committedContext()
    for time in stride(from: 2, through: 8, by: 2) {
        expect(menu.verify(client: "editor", base: 8, preceding: "我现在", now: Double(time)),
               "menu render validates without refreshing inactivity")
    }
    expect(!menu.verify(client: "editor", base: 8, preceding: "我现在", now: 10),
           "repeated menu renders do not extend TTL")
    expectCleared(menu, reason: "idle_timeout")

    var typing = committedContext()
    for time in stride(from: 2, through: 24, by: 2) {
        typing.noteActivity(now: Double(time))
        expect(typing.verify(client: "editor", base: 8, preceding: "我现在", now: Double(time)),
               "keystrokes every two seconds retain context beyond ten seconds total")
    }
    expect(typing.verify(client: "editor", base: 8, preceding: "我现在", now: 33.999),
           "less than ten seconds idle remains valid")
    expect(!typing.verify(client: "editor", base: 8, preceding: "我现在", now: 34),
           "exactly ten seconds idle expires")
    expectCleared(typing, reason: "idle_timeout")

    var resumed = committedContext()
    resumed.noteActivity(now: 10)
    expectCleared(resumed, reason: "idle_timeout")
    var deferred = committedContext()
    expect(!deferred.verify(client: "editor", base: nil, preceding: nil, now: 10,
                            deferredCommit: true), "deferral cannot revive an idle context")
    var custom = JevCommittedContext(idleTimeout: 3)
    custom.commit("字", at: 0, client: "editor", now: 0)
    expect(!custom.verify(client: "editor", base: 1, preceding: "字", now: 3), "custom timeout")
}

private func testChainedCommitsAndReset() {
    var context = committedContext()
    context.commit("想", at: 8, client: "editor", now: 2)
    expect(context.text == "我现在想" && context.expectedEnd == 9, "adjacent commits chain")
    context.commit("去", at: 9, client: "editor", now: 11)
    expect(context.text == "我现在想去", "commit updates activity")
    context.commit("新", at: 10, client: "editor", now: 21)
    expect(context.text == "新", "idle boundary breaks the chain")
    context.commit("位置", at: 30, client: "editor", now: 22)
    expect(context.text == "位置" && context.expectedEnd == 32, "cursor change starts a new chain")
    context.commit("窗口", at: 32, client: "other", now: 23)
    expect(context.text == "窗口" && context.clientIdentity == "other", "client change starts a new chain")
    let copy = context
    context.reset()
    expectCleared(context, reason: "reset")
    expect(!context.verify(client: "other", base: 34, preceding: "窗口", now: 24), "empty returns false")
    expect(copy.text == "窗口" && copy.expectedEnd == 34, "value copies remain independent")
}

private func testUTF16AndSuffix() {
    var context = JevCommittedContext()
    context.commit("我😀", at: 4, client: "editor", now: 0)
    expect(context.expectedEnd == 7, "emoji cursor uses UTF16 units")
    context.commit("好", at: 7, client: "editor", now: 1)
    expect(context.verify(client: "editor", base: 8, preceding: "我😀好", now: 1), "emoji chain verifies")
    let family = "👨‍👩‍👧‍👦"
    let longText = String(repeating: "甲", count: 81) + family
    context.commit(longText, at: 8, client: "editor", now: 2)
    expect(context.text == String(repeating: "甲", count: 79) + family, "suffix keeps eighty whole characters")
    expect(context.text.count == 80, "default character limit")
    expect(context.expectedEnd == 8 + longText.utf16.count, "suffix trimming preserves full insertion end")
    expect(context.verify(client: "editor", base: context.expectedEnd, preceding: context.text, now: 2),
           "trimmed owned suffix verifies")

    var short = JevCommittedContext(characterLimit: 2)
    short.commit("甲😀乙", at: 0, client: "editor", now: 0)
    expect(short.text == "😀乙" && short.expectedEnd == 4, "custom limit counts characters")
    var exact = JevCommittedContext()
    exact.commit("é", at: 0, client: "editor", now: 0)
    expect(!exact.verify(client: "editor", base: 1, preceding: "e\u{301}", now: 1),
           "host text must match exact UTF16 content")
    expectCleared(exact, reason: "text_mismatch")
}

@main
private enum JevCommittedContextTests {
    static func main() {
        testDeferredCommit()
        testRejections()
        testInactivity()
        testChainedCommitsAndReset()
        testUTF16AndSuffix()
        print("JevCommittedContextTests: PASS (deferred commit, continuity, inactivity, chaining, UTF16, suffix)")
    }
}
