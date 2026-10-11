import Foundation

private let baseline = [
    JevCandidate(id: "a", text: "邮箱", key: "key-a"),
    JevCandidate(id: "b", text: "油箱", key: "key-b"),
    JevCandidate(id: "c", text: "幽香", key: "key-c")
]
private var scenario = ""
private var cases = 0

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL [\(scenario)]: \(message)\n", stderr)
        exit(1)
    }
}

private func waitUntil(_ message: String, timeout: TimeInterval = 2,
                       _ condition: () -> Bool) {
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while !condition() && ProcessInfo.processInfo.systemUptime < deadline {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
    }
    expect(condition(), "timed out: \(message)")
}

private func pass() { cases += 1; print("PASS \(scenario)") }

private final class Fixture {
    let client: AdapterTextClient
    let controller = SquirrelInputController()
    let adapter: JevInputAdapter
    let runtime = JevRuntimeManager.shared

    init(text: String = "汽车的", providers: [String] = ["local"]) {
        JevSettings.current = JevSettings(selectedProviders: providers)
        runtime.reset()
        client = AdapterTextClient(text)
        controller.client = client
        adapter = JevInputAdapter(controller: controller)
        adapter.beforeMenu(schema: "test-pinyin")
    }
    func stop() { adapter.invalidate(clearContext: true); runtime.reset() }
    func count(_ key: String) -> Int { adapter.diagnostics[key] as? Int ?? -1 }
    func reason() -> String { adapter.diagnostics["reason"] as? String ?? "" }
    func render(_ raw: String = "youxiang") {
        controller.rimeAPI.setInput(raw)
        let snapshot: [String: Any] = [
            "input": raw, "pinyin": raw, "protected": false,
            "candidates": baseline.map { ["id": $0.id, "text": $0.text, "key": $0.key] }
        ]
        let data = try! JSONSerialization.data(withJSONObject: snapshot)
        controller.rimeAPI.properties["_jev_snapshot"] = String(data: data, encoding: .utf8)!
        adapter.afterRender(candidates: baseline.map(\.text), page: 0, prefix: "", displayCode: raw)
    }
    func awaitRequests(_ count: Int = 1) {
        waitUntil("\(count) actual runtime requests; last reason \(reason())") { runtime.pending.count >= count }
        expect(runtime.pending.count == count, "unexpected duplicate requests")
    }
    func awaitInstalls(_ count: Int = 1) {
        waitUntil("\(count) applied wires") { controller.rimeAPI.installations.count >= count }
        expect(controller.rimeAPI.installations.count == count, "unexpected duplicate applies")
        expect(controller.updates == count, "apply must refresh the controller")
    }
    func checkBaseline() {
        expect(count("commits") == 0, "must not depend on adapter-owned commits")
        for call in runtime.pending {
            expect(call.request.candidates.map(\.id) == baseline.map(\.id), "original candidate IDs/order preserved")
            expect(call.request.candidates.map(\.text) == baseline.map(\.text), "original first and alternatives preserved")
        }
    }
    func wire() -> [String] {
        guard let wire = controller.rimeAPI.installations.last else {
            expect(false, "no installed placement wire"); return []
        }
        let fields = wire.components(separatedBy: "|")
        expect(fields.count == 7 && fields[0] == "v2", "valid v2 placement contract")
        expect(fields[4] == String(baseline.count), "placement retains full baseline count")
        let signature = baseline.map(\.key).joined(separator: "\n").utf8.map { String(format: "%02x", $0) }.joined()
        expect(fields[5] == signature, "placement signs original first and unchanged baseline order")
        expect(controller.rimeAPI.properties["_jev_applied"] == wire, "Rime acknowledgement observed")
        return fields
    }
}

private func testPastedLine(_ provider: String) {
    scenario = "fresh pasted current line -> dispatch + apply [\(provider)]"
    let f = Fixture(text: "上一行不能泄入当前行\n汽车的", providers: [provider])
    defer { f.stop() }
    f.render()
    expect(f.client.reads == 0 && f.runtime.pending.isEmpty, "afterRender must defer text reads and transport")
    f.awaitRequests()
    expect(f.runtime.pending[0].request.state.context == "汽车的", "request must use current pasted line")
    expect(f.adapter.diagnostics["context_source"] as? String == "current_line", "host text is the source")
    f.checkBaseline()
    f.runtime.respond(provider: provider, choice: "b")
    f.awaitInstalls()
    let wire = f.wire()
    expect(wire[3] == "key-b" && wire[6] == provider, "selected candidate/provider reach real apply")
    expect(f.client.reads >= 3, "capture, dispatch and apply each recheck host text")
    pass()
}

private func testEmptyContext(_ provider: String, unreadable: Bool) {
    scenario = "empty context \(unreadable ? "unreadable known caret" : "known base zero") [\(provider)]"
    let f = Fixture(text: unreadable ? "不可读取" : "", providers: [provider])
    defer { f.stop() }
    f.client.readable = !unreadable
    f.render()
    f.awaitRequests()
    expect(f.runtime.pending[0].request.state.context.isEmpty, "empty context must actually dispatch")
    expect(f.adapter.diagnostics["context_source"] as? String == (unreadable ? "no_context" : "current_line"), "expected empty context source")
    f.checkBaseline()
    f.runtime.respond(provider: provider, choice: "a")
    f.awaitInstalls()
    expect(f.wire()[3] == "key-a", "original first can receive a decision even with empty context")
    pass()
}

private func testUnknownCaret() {
    scenario = "unknown caret rejects requests for both providers"
    let f = Fixture(providers: ["local", "jev"])
    defer { f.stop() }
    f.client.selected = NSRange(location: NSNotFound, length: 0)
    f.render()
    waitUntil("unknown caret rejection") { f.reason() == "unbound_cursor" }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    expect(f.runtime.pending.isEmpty && f.controller.rimeAPI.installations.isEmpty, "no anchor must not dispatch/apply")
    pass()
}

private func change(_ f: Fixture, caret: Bool) {
    if caret { f.client.selected.location -= 1 }
    else { f.client.text = "邮箱的" } // Same UTF-16 length and unchanged caret.
}

private func testChangedBeforeDispatch(caret: Bool) {
    scenario = "\(caret ? "caret" : "text") changed before dispatch rejects both providers"
    let f = Fixture(providers: ["local", "jev"])
    defer { f.stop() }
    f.client.beforeRead = { count in
        if count == 2 { change(f, caret: caret) }
    }
    defer { f.client.beforeRead = nil }
    f.render()
    waitUntil("dispatch-time freshness rejection") { f.reason() == "context_changed_before_request" }
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))
    expect(f.client.reads >= 2, "must reach pre-dispatch read")
    expect(f.runtime.pending.isEmpty, "stale context must not reach either runtime")
    expect(f.controller.rimeAPI.installations.isEmpty, "no stale placement")
    pass()
}

private func testChangedBeforeApply(caret: Bool) {
    scenario = "\(caret ? "caret" : "text") changed before apply rejects both providers"
    let f = Fixture(providers: ["local", "jev"])
    defer { f.stop() }
    f.render()
    f.awaitRequests(2)
    // Queue valid replies, then change the host before the real scheduler applies them.
    f.runtime.respond(provider: "local", choice: "b")
    f.runtime.respond(provider: "jev", choice: "c")
    expect(f.count("decisions") == 0, "response must hop through the real scheduler")
    change(f, caret: caret)
    waitUntil("both actual decisions reach freshness guard") { f.count("decisions") == 2 }
    expect(f.reason() == "context_changed_before_apply", "adapter must reject changed host snapshot")
    expect(f.controller.rimeAPI.installations.isEmpty && f.controller.updates == 0, "no stale apply or refresh")
    pass()
}

private func testCoalescing() {
    scenario = "rapid renders coalesce to latest text/input"
    let f = Fixture()
    defer { f.stop() }
    for raw in ["you", "youx", "youxi", "youxiang", "youxiang"] { f.render(raw) }
    f.client.text = "邮箱的"
    expect(f.client.reads == 0, "rapid renders must not synchronously read the host")
    f.awaitRequests()
    expect(f.runtime.pending[0].request.state.pinyin == "youxiang", "only latest input dispatches")
    expect(f.runtime.pending[0].request.state.context == "邮箱的", "read latest pasted text after coalescing")
    expect(f.client.reads == 2, "one initial capture plus one dispatch check")
    f.runtime.respond(provider: "local", choice: "b")
    f.awaitInstalls()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
    expect(f.runtime.pending.count == 1 && f.controller.rimeAPI.installations.count == 1, "superseded work must not dispatch/apply later")
    pass()
}

private func testOriginalFirst(_ priority: [String]) {
    scenario = "dual recommendations retain original first [\(priority.joined(separator: ","))]"
    let f = Fixture(providers: priority)
    defer { f.stop() }
    f.render()
    f.awaitRequests(2)
    expect(Set(f.runtime.pending.map { $0.request.provider }) == Set(priority), "both configured providers dispatch")
    f.checkBaseline()
    f.runtime.respond(provider: priority[0], choice: "c")
    f.awaitInstalls()
    expect(f.wire()[3] == "key-c", "first reply applied independently")
    f.runtime.respond(provider: priority[1], choice: "a")
    f.awaitInstalls(2)
    let wire = f.wire()
    expect(wire[3] == "key-a,key-c", "lower-priority match to original first remains first in recommendation plan")
    expect(wire[6] == "\(priority[1]),\(priority[0])", "provider labels stay bound to their candidate")
    f.checkBaseline()
    pass()
}

private func testDispatchBudget() {
    scenario = "dispatch read consumes provider wire budget"
    let f = Fixture()
    defer { f.stop() }
    JevSettings.current.timeoutOverrides = ["local": 1000]
    JevInputAdapter.reloadPolicies()
    var readMilliseconds: Int64 = 0
    var firstReadAt: Int64 = 0
    f.client.beforeRead = { count in
        if count == 1 { firstReadAt = JevSystemMonotonicClock().nowMilliseconds() }
        if count == 2 {
            let started = JevSystemMonotonicClock().nowMilliseconds()
            Thread.sleep(forTimeInterval: 0.035)
            readMilliseconds = JevSystemMonotonicClock().nowMilliseconds() - started
        }
    }
    let started = JevSystemMonotonicClock().nowMilliseconds()
    f.render()
    f.awaitRequests()
    let call = f.runtime.pending[0]
    let remaining = 1000 - (call.sentAt - started)
    expect(firstReadAt - started >= 240, "initial host read must wait for the 260ms debounce")
    expect(call.sentAt - firstReadAt < 200, "coordinator must not add a second 260ms debounce")
    expect(readMilliseconds >= 30, "fixture must actually delay the dispatch read")
    expect(call.request.maxAgeMilliseconds > 0, "remaining wire budget must be positive")
    expect(abs(call.request.maxAgeMilliseconds - remaining) <= 10,
           "wire budget must include dispatch read (got \(call.request.maxAgeMilliseconds), expected about \(remaining))")
    f.runtime.respond(provider: "local", choice: "b")
    f.awaitInstalls()
    pass()
}

@main
struct JevContextAdapterTests {
    static func main() {
        expect(Thread.isMainThread, "tests must run on the real main run loop")
        for provider in ["local", "jev"] {
            testPastedLine(provider)
            testEmptyContext(provider, unreadable: false)
            testEmptyContext(provider, unreadable: true)
        }
        testUnknownCaret()
        for caret in [true, false] {
            testChangedBeforeDispatch(caret: caret)
            testChangedBeforeApply(caret: caret)
        }
        testCoalescing()
        testOriginalFirst(["jev", "local"])
        testOriginalFirst(["local", "jev"])
        testDispatchBudget()
        print("JevContextAdapterTests PASS: \(cases) cases; actual adapter/coordinators with main-runloop scheduling")
    }
}
