import Foundation

private final class TestClock: JevMonotonicClock {
    var milliseconds: Int64 = 0

    func nowMilliseconds() -> Int64 {
        milliseconds
    }

    func advance(by amount: Int64) {
        precondition(amount >= 0)
        milliseconds += amount
    }
}

private final class TestScheduledEntry {
    let due: Int64
    let sequence: Int
    let action: () -> Void
    var cancelled = false

    init(due: Int64, sequence: Int, action: @escaping () -> Void) {
        self.due = due
        self.sequence = sequence
        self.action = action
    }
}

private final class TestScheduleHandle: JevCancellable {
    private let entry: TestScheduledEntry

    init(entry: TestScheduledEntry) {
        self.entry = entry
    }

    func cancel() {
        entry.cancelled = true
    }
}

private final class TestScheduler: JevScheduler {
    let clock: TestClock
    private var nextSequence = 0
    private var entries: [TestScheduledEntry] = []

    init(clock: TestClock) {
        self.clock = clock
    }

    @discardableResult
    func schedule(after milliseconds: Int64, _ action: @escaping () -> Void) -> JevCancellable {
        nextSequence += 1
        let entry = TestScheduledEntry(
            due: clock.nowMilliseconds() + max(0, milliseconds),
            sequence: nextSequence,
            action: action
        )
        entries.append(entry)
        return TestScheduleHandle(entry: entry)
    }

    func advance(by amount: Int64) {
        clock.advance(by: amount)
        runDue()
    }

    func advance(to milliseconds: Int64) {
        precondition(milliseconds >= clock.nowMilliseconds())
        clock.milliseconds = milliseconds
        runDue()
    }

    func runDue() {
        while true {
            let dueEntries = entries.enumerated().filter {
                !$0.element.cancelled && $0.element.due <= clock.nowMilliseconds()
            }
            guard let next = dueEntries.min(by: {
                if $0.element.due == $1.element.due {
                    return $0.element.sequence < $1.element.sequence
                }
                return $0.element.due < $1.element.due
            }) else {
                return
            }
            let entry = entries.remove(at: next.offset)
            if !entry.cancelled {
                entry.action()
            }
        }
    }
}

private final class TestTransport {
    var requests: [JevDecisionRequest] = []
    var completions: [String: (JevDecisionResponse) -> Void] = [:]
    var cancelledRequestIDs: Set<String> = []

    lazy var closure: JevTransport = { [weak self] request, completion in
        guard let self else { return JevNoopCancellable() }
        self.requests.append(request)
        self.completions[request.id] = completion
        return JevClosureCancellable { [weak self] in
            self?.cancelledRequestIDs.insert(request.id)
        }
    }

    func respond(_ response: JevDecisionResponse) {
        completions[response.id]?(response)
    }
}

private final class DecisionBox {
    var values: [JevDecision] = []
}

private let candidates = [
    JevCandidate(id: "a", text: "甲", key: "key-a"),
    JevCandidate(id: "b", text: "乙", key: "key-b"),
    JevCandidate(id: "c", text: "丙", key: "key-c")
]

private func snapshot(
    identity: String,
    provider: String = "jev",
    pinyin: String = "jia",
    context: String = "当前"
) -> JevInputSnapshot {
    JevInputSnapshot(
        identity: identity,
        pinyin: pinyin,
        context: context,
        candidates: candidates,
        provider: provider
    )
}

private func acceptedResponse(
    request: JevDecisionRequest,
    provider: String? = nil,
    choiceID: String = "b",
    probabilities: [String: Double] = [
        "a": 0.10,
        "b": 0.80,
        "c": 0.05,
        "none": 0.05
    ]
) -> JevDecisionResponse {
    JevDecisionResponse(
        id: request.id,
        provider: provider ?? request.provider,
        model: "test-model",
        choiceID: choiceID,
        probabilities: probabilities
    )
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fatalError("JevCoreTests failed: \(message)")
    }
}

private func expectEqual<T: Equatable>(_ lhs: T, _ rhs: T, _ message: String) {
    if lhs != rhs {
        fatalError("JevCoreTests failed: \(message); got \(lhs), expected \(rhs)")
    }
}

private func makeCoordinator(
    clock: TestClock,
    scheduler: TestScheduler,
    transport: TestTransport,
    policy: JevDecisionPolicy = JevDecisionPolicy(
        defaultThreshold: JevDecisionThreshold(minimumProbability: 0.50, minimumMargin: 0.20)
    ),
    decisions: DecisionBox
) -> JevDecisionCoordinator {
    var sequence = 0
    let configuration = JevCoordinatorConfiguration(policy: policy)
    let coordinator = JevDecisionCoordinator(
        configuration: configuration,
        clock: clock,
        scheduler: scheduler,
        transport: transport.closure,
        requestIDFactory: {
            sequence += 1
            return "request-\(sequence)"
        },
        onDecision: { decision in
            decisions.values.append(decision)
        }
    )
    return coordinator
}

private func testRequestWireAndDebounce() {
    let clock = TestClock()
    let scheduler = TestScheduler(clock: clock)
    let transport = TestTransport()
    let decisions = DecisionBox()
    let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport, decisions: decisions)

    coordinator.onNewSnapshot(snapshot(identity: "wire"))
    scheduler.advance(by: 259)
    expect(transport.requests.isEmpty, "debounce fired before 260ms")
    scheduler.advance(by: 1)
    expectEqual(transport.requests.count, 1, "one request after debounce")

    let request = transport.requests[0]
    let json = try! request.jsonData()
    let object = try! JSONSerialization.jsonObject(with: json) as! [String: Any]
    expectEqual(Set(object.keys), Set(["id", "op", "state", "candidates", "max_age_ms"]), "wire keys")
    expectEqual(object["op"] as? String, "decide", "wire operation")
    expectEqual(object["max_age_ms"] as? Int, 1500, "wire max age")
    let state = object["state"] as! [String: Any]
    expectEqual(state["pinyin"] as? String, "jia", "wire pinyin")
    expectEqual(state["context"] as? String, "当前", "wire context")
    let wireCandidates = object["candidates"] as! [[String: Any]]
    expectEqual(wireCandidates.map { $0["id"] as! String }, ["a", "b", "c"], "wire candidate ids")
    expect(decisions.values.isEmpty, "no decision before response")
}

private func testFirstCandidateStillProducesDecision() {
    for provider in ["jev", "local"] {
        let clock=TestClock(), transport=TestTransport(), decisions=DecisionBox()
        let scheduler=TestScheduler(clock:clock)
        let coordinator=makeCoordinator(clock:clock,scheduler:scheduler,transport:transport,decisions:decisions)
        coordinator.onNewSnapshot(snapshot(identity:"first-"+provider,provider:provider))
        scheduler.advance(by:260)
        transport.respond(acceptedResponse(request:transport.requests[0],choiceID:"a",probabilities:["a":0.9,"b":0.04,"c":0.03,"none":0.03]))
        scheduler.runDue()
        expectEqual(decisions.values.count,1,"matching first candidate still reaches the badge adapter")
        expectEqual(decisions.values[0].candidate,candidates[0],"first candidate identity is preserved")
        expectEqual(decisions.values[0].provider,provider,"first candidate retains actual source")
    }
}

private func testAbbreviationAndSamplingClock() {
    for (raw, display, expected) in [("sj","s j",24),("sj","sj",24),("shuij","shui j",24),
                                      ("zhongg","zhong g",24),("youxiang","you xiang",8),
                                      ("shijian","shi jian",8),("a","a",8),("n","n",8)] {
        expectEqual(JevCandidateWindow.limit(pinyin:raw,displayCode:display), expected, "candidate window \(raw)")
    }
    let clock=TestClock()
    let scheduler=TestScheduler(clock:clock), transport=TestTransport(), decisions=DecisionBox()
    let coordinator=makeCoordinator(clock:clock,scheduler:scheduler,transport:transport,decisions:decisions)
    clock.advance(by:80)
    let abbreviated=JevInputSnapshot(identity:"sampled",pinyin:"sj",context:"前文",candidates:candidates,provider:"jev",abbreviated:true)
    coordinator.onNewSnapshot(abbreviated,startedAtMilliseconds:0)
    scheduler.advance(to:259)
    expect(transport.requests.isEmpty,"sampling does not skip debounce")
    scheduler.advance(to:260)
    expectEqual(transport.requests.count,1,"sampling consumes debounce time")
    let object=try! JSONSerialization.jsonObject(with:transport.requests[0].jsonData()) as! [String:Any]
    expectEqual((object["state"] as! [String:Any])["abbreviated"] as? Bool,true,"abbreviation reaches runtime")
    scheduler.advance(to:601)
    transport.respond(acceptedResponse(request:transport.requests[0]))
    scheduler.runDue()
    expectEqual(decisions.values.last?.action,.annotate,"sampling cannot extend 600ms promotion window")
    coordinator.onNewSnapshot(snapshot(identity:"expired-sampling"),startedAtMilliseconds:-1000)
    scheduler.runDue()
    expectEqual(transport.requests.count,1,"expired sampling starts no network request")
    coordinator.onNewSnapshot(snapshot(identity:"future-start"),startedAtMilliseconds:9000)
    scheduler.advance(by:260)
    expectEqual(transport.requests.count,2,"future timestamp is clamped")
}

private func testAThenBThenAAndApplyOnce() {
    let clock = TestClock()
    let scheduler = TestScheduler(clock: clock)
    let transport = TestTransport()
    let decisions = DecisionBox()
    let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport, decisions: decisions)

    coordinator.onNewSnapshot(snapshot(identity: "A"))
    scheduler.advance(by: 260)
    let requestA1 = transport.requests[0]

    scheduler.advance(by: 40)
    coordinator.onNewSnapshot(snapshot(identity: "B"))
    scheduler.advance(by: 260)
    let requestB = transport.requests[1]

    scheduler.advance(by: 40)
    coordinator.onNewSnapshot(snapshot(identity: "A"))
    scheduler.advance(by: 260)
    let requestA2 = transport.requests[2]
    expect(transport.cancelledRequestIDs.contains(requestA1.id), "old A transport cancelled")
    expect(transport.cancelledRequestIDs.contains(requestB.id), "old B transport cancelled")

    transport.respond(acceptedResponse(request: requestA1))
    transport.respond(acceptedResponse(request: requestB))
    scheduler.runDue()
    expect(decisions.values.isEmpty, "old A and B responses cannot reflow into A2")

    transport.respond(acceptedResponse(request: requestA2))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "A2 produces one decision")
    expectEqual(decisions.values[0].candidate.id, "b", "A2 candidate")
    expectEqual(decisions.values[0].action, .promote, "early A2 response promotes")

    transport.respond(acceptedResponse(request: requestA2))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "one decision per version")
}

private func testLocksAndDeadlines() {
    let clock = TestClock()
    let scheduler = TestScheduler(clock: clock)
    let transport = TestTransport()
    let decisions = DecisionBox()
    let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport, decisions: decisions)

    coordinator.onNewSnapshot(snapshot(identity: "sort-lock"))
    scheduler.advance(by: 260)
    let sortLockedRequest = transport.requests[0]
    coordinator.lockSorting()
    transport.respond(acceptedResponse(request: sortLockedRequest))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "sorting lock still permits annotation")
    expectEqual(decisions.values[0].action, .annotate, "sorting lock downgrades to annotation")

    coordinator.onNewSnapshot(snapshot(identity: "commit-lock"))
    scheduler.advance(by: 260)
    let commitLockedRequest = transport.requests[1]
    coordinator.lockCommit()
    transport.respond(acceptedResponse(request: commitLockedRequest))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "commit lock discards response")

    coordinator.onNewSnapshot(snapshot(identity: "boundary-promote"))
    scheduler.advance(by: 260)
    let beforeSixHundred = transport.requests[2]
    scheduler.advance(by: 339)
    transport.respond(acceptedResponse(request: beforeSixHundred))
    scheduler.runDue()
    expectEqual(decisions.values.last?.action, .promote, "599ms promotes")

    coordinator.onNewSnapshot(snapshot(identity: "boundary-annotate"))
    scheduler.advance(by: 260)
    let atSixHundred = transport.requests[3]
    scheduler.advance(by: 340)
    transport.respond(acceptedResponse(request: atSixHundred))
    scheduler.runDue()
    expectEqual(decisions.values.last?.action, .annotate, "600ms annotates")

    coordinator.onNewSnapshot(snapshot(identity: "boundary-final"))
    scheduler.advance(by: 260)
    let atFinalDeadline = transport.requests[4]
    scheduler.advance(by: 1240)
    transport.respond(acceptedResponse(request: atFinalDeadline))
    scheduler.runDue()
    expectEqual(decisions.values.last?.requestID, atFinalDeadline.id, "1500ms remains eligible")
    expectEqual(decisions.values.last?.action, .annotate, "1500ms annotates")

    coordinator.onNewSnapshot(snapshot(identity: "expired"))
    scheduler.advance(by: 260)
    let expired = transport.requests[5]
    scheduler.advance(by: 1241)
    transport.respond(acceptedResponse(request: expired))
    scheduler.runDue()
    expectEqual(decisions.values.last?.requestID, atFinalDeadline.id, "1501ms is discarded")
}

private func testValidation() {
    let request = JevDecisionRequest(
        id: "validation-request",
        state: JevRequestState(context: "上下文", pinyin: "jia"),
        candidates: candidates.map { JevRequestCandidate(id: $0.id, text: $0.text) },
        maxAgeMilliseconds: 1500,
        provider: "jev"
    )
    let policy = JevDecisionPolicy(
        defaultThreshold: JevDecisionThreshold(minimumProbability: 0.70, minimumMargin: 0.30),
        thresholdsByProvider: [
            "local": JevDecisionThreshold(minimumProbability: 0.60, minimumMargin: 0.10)
        ]
    )

    let accepted = JevDecisionValidator.validate(
        response: acceptedResponse(request: request),
        request: request,
        candidates: candidates,
        policy: policy
    )
    guard case .accepted(let value) = accepted else {
        fatalError("JevCoreTests failed: valid response rejected")
    }
    expectEqual(value.candidateID, "b", "top candidate id")
    expect(abs(value.probability - 0.80) < 0.000001, "top probability")
    expect(abs(value.margin - 0.70) < 0.000001, "top margin")

    let wrongID = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: "wrong",
            provider: "jev",
            choiceID: "b",
            probabilities: ["a": 0.10, "b": 0.80, "c": 0.05, "none": 0.05]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(wrongID, .rejected(.requestIDMismatch), "wrong response id rejected")

    let wrongProvider = JevDecisionValidator.validate(
        response: acceptedResponse(request: request, provider: "local"),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(wrongProvider, .rejected(.providerMismatch), "wrong provider rejected")

    let extraID = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "b",
            probabilities: ["a": 0.10, "b": 0.75, "c": 0.05, "none": 0.05, "extra": 0.05]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(extraID, .rejected(.candidateIDsMismatch), "unknown probability id rejected")

    let nan = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "b",
            probabilities: ["a": 0.10, "b": Double.nan, "c": 0.05, "none": 0.05]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(nan, .rejected(.probabilityNotFinite("b")), "non-finite probability rejected")

    let outOfRange = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "b",
            probabilities: ["a": 0.10, "b": 1.10, "c": 0.05, "none": 0.0]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(outOfRange, .rejected(.probabilityOutOfRange("b")), "out of range probability rejected")

    let badSum = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "b",
            probabilities: ["a": 0.10, "b": 0.70, "c": 0.05, "none": 0.05]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(badSum, .rejected(.probabilitySumMismatch), "probability sum rejected")

    let wrongTop = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "a",
            probabilities: ["a": 0.10, "b": 0.80, "c": 0.05, "none": 0.05]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(wrongTop, .rejected(.choiceIsNotTop), "non-top choice rejected")

    let none = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "none",
            probabilities: ["a": 0.10, "b": 0.10, "c": 0.10, "none": 0.70]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(none, .none, "none response has no decision")

    let belowThreshold = JevDecisionValidator.validate(
        response: JevDecisionResponse(
            id: request.id,
            provider: request.provider,
            choiceID: "b",
            probabilities: ["a": 0.10, "b": 0.60, "c": 0.05, "none": 0.25]
        ),
        request: request,
        candidates: candidates,
        policy: policy
    )
    expectEqual(belowThreshold, .rejected(.thresholdProbability), "provider probability threshold")

    let localRequest = JevDecisionRequest(
        id: request.id,
        state: request.state,
        candidates: request.candidates,
        maxAgeMilliseconds: request.maxAgeMilliseconds,
        provider: "local"
    )
    let localAccepted = JevDecisionValidator.validate(
        response: acceptedResponse(request: localRequest, probabilities: [
            "a": 0.10,
            "b": 0.65,
            "c": 0.05,
            "none": 0.20
        ]),
        request: localRequest,
        candidates: candidates,
        policy: policy
    )
    guard case .accepted = localAccepted else {
        fatalError("JevCoreTests failed: provider-specific threshold rejected local response")
    }
}

private func testProviderResponseDecoding() {
    let floatingJSON = Data("{\"id\":\"float-response\",\"status\":\"ready\",\"provider\":\"jev\",\"model\":\"provider-model\",\"choice_id\":\"b\",\"probabilities\":{\"a\":0.10,\"b\":0.80,\"c\":0.05,\"none\":0.05},\"elapsed_ms\":153.630458}".utf8)
    let floating = try! JSONDecoder().decode(JevDecisionResponse.self, from: floatingJSON)
    expect(abs((floating.elapsedMilliseconds ?? 0.0) - 153.630458) < 0.0000001, "floating elapsed_ms decodes")
    expect(floating.probabilities != nil, "ready probabilities decode")

    let request = JevDecisionRequest(
        id: "null-response",
        state: JevRequestState(context: "", pinyin: "jia"),
        candidates: candidates.map { JevRequestCandidate(id: $0.id, text: $0.text) },
        maxAgeMilliseconds: 1500,
        provider: "jev"
    )
    let nullJSON = Data("{\"id\":\"null-response\",\"status\":\"loading\",\"provider\":\"jev\",\"model\":\"provider-model\",\"choice_id\":null,\"probabilities\":null,\"elapsed_ms\":1}".utf8)
    let nullResponse = try! JSONDecoder().decode(JevDecisionResponse.self, from: nullJSON)
    expect(nullResponse.probabilities == nil, "loading null probabilities decode")
    let nullValidation = JevDecisionValidator.validate(
        response: nullResponse,
        request: request,
        candidates: candidates,
        policy: JevDecisionPolicy()
    )
    expectEqual(nullValidation, .rejected(.statusNotReady), "loading response has no decision")

    let readyNullResponse = JevDecisionResponse(
        id: request.id,
        status: "ready",
        provider: request.provider,
        choiceID: nil,
        probabilities: nil,
        elapsedMilliseconds: 153.630458
    )
    let readyNullValidation = JevDecisionValidator.validate(
        response: readyNullResponse,
        request: request,
        candidates: candidates,
        policy: JevDecisionPolicy()
    )
    expectEqual(readyNullValidation, .rejected(.probabilitiesMissing), "ready null probabilities have no decision")
}

private func testDisableAndProviderSwitch() {
    let clock = TestClock()
    let scheduler = TestScheduler(clock: clock)
    let transport = TestTransport()
    let decisions = DecisionBox()
    let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport, decisions: decisions)

    coordinator.onNewSnapshot(snapshot(identity: "disabled"))
    coordinator.disable()
    scheduler.advance(by: 500)
    expect(transport.requests.isEmpty, "disabled coordinator sends no request")

    coordinator.enable()
    coordinator.onNewSnapshot(snapshot(identity: "provider-old", provider: "jev"))
    scheduler.advance(by: 260)
    let oldProviderRequest = transport.requests[0]
    coordinator.setProvider("local")
    transport.respond(acceptedResponse(request: oldProviderRequest))
    scheduler.runDue()
    expect(decisions.values.isEmpty, "provider switch clears old response")

    coordinator.onNewSnapshot(snapshot(identity: "provider-new", provider: "local"))
    scheduler.advance(by: 260)
    let newProviderRequest = transport.requests[1]
    transport.respond(acceptedResponse(request: newProviderRequest))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "new provider can produce a decision")
    expectEqual(decisions.values[0].provider, "local", "callback provider")
}

@main
private enum JevCoreTests {
    static func main() {
        testRequestWireAndDebounce()
        testFirstCandidateStillProducesDecision()
        testAbbreviationAndSamplingClock()
        testAThenBThenAAndApplyOnce()
        testLocksAndDeadlines()
        testValidation()
        testProviderResponseDecoding()
        testDisableAndProviderSwitch()
        print("JevCoreTests: PASS (wire, debounce, stale identity, locks, deadlines, validation, disable/provider switch)")
    }
}
