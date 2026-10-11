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
    decisions: DecisionBox,
    providerTimeouts: [String: Int64] = [:]
) -> JevDecisionCoordinator {
    var sequence = 0
    let configuration = JevCoordinatorConfiguration(policy: policy, providerTimeouts: providerTimeouts)
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
    expectEqual(object["max_age_ms"] as? Int, 1240, "wire budget subtracts debounce from the legacy 1500ms deadline")
    let state = object["state"] as! [String: Any]
    expectEqual(state["pinyin"] as? String, "jia", "wire pinyin")
    expectEqual(state["context"] as? String, "当前", "wire context")
    let wireCandidates = object["candidates"] as! [[String: Any]]
    expectEqual(wireCandidates.map { $0["id"] as! String }, ["a", "b", "c"], "wire candidate ids")
    expect(decisions.values.isEmpty, "no decision before response")
}

private func testFirstCandidateStillProducesDecision() {
    for provider in ["jev", "local", "tev-0.8b", "tev-4b"] {
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
        for provider in ["local", "jev", "tev-0.8b", "tev-4b"] {
            let capped = provider.hasPrefix("tev-") ? min(expected, 23) : expected
            let limit = JevCandidateWindow.limit(pinyin:raw,displayCode:display,provider:provider)
            expectEqual(limit, capped, "\(provider) candidate window \(raw)")
            if provider.hasPrefix("tev-") { expect(limit + 1 <= 24, "Tev reserves one option for none") }
        }
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

private func testProviderConfiguration() {
    expectEqual(JevProviders.modes, ["off", "local", "tev-0.8b", "tev-4b", "jev"], "stable mode order")
    expectEqual(JevProviders.local, ["local", "tev-0.8b", "tev-4b"], "all local model lifecycles")
    expectEqual(JevProviders.downloadArguments(provider:"local",projectRoot:"/current project",modelPath:"/legacy model"),
                ["/current project/scripts/download_model.py", "--destination", "/legacy model"], "legacy TT download path")
    for provider in ["tev-0.8b", "tev-4b"] {
        expectEqual(JevProviders.downloadArguments(provider:provider,projectRoot:"/current project",modelPath:"/legacy model"),
                    ["/current project/scripts/download_tev.py", "--model", provider], "Tev downloads the selected variant")
    }
    for provider in ["off", "jev", "unknown"] {
        expectEqual(JevProviders.downloadArguments(provider:provider,projectRoot:"/project",modelPath:"/model"), nil,
                    "\(provider) has no local model download")
    }
    expectEqual(JevProviders.name("local"), "TT · this-that-model 1.2", "friendly TT model name")
    expectEqual(JevProviders.name("tev-0.8b"), "Tev 0.8B", "specific small model name")
    expectEqual(JevProviders.name("tev-4b"), "Tev 4B", "specific large model name")
    let policy=JevDecisionPolicy.inputMethod()
    expectEqual(policy.threshold(for:"local"), JevDecisionThreshold(minimumProbability:0.65,minimumMargin:0.15), "TT threshold preserved")
    expectEqual(policy.threshold(for:"jev"), JevDecisionThreshold(minimumProbability:0.55,minimumMargin:0.15), "Jev threshold preserved")
    for provider in ["tev-0.8b", "tev-4b"] {
        expectEqual(policy.threshold(for:provider), JevDecisionThreshold(minimumProbability:0.65,minimumMargin:0.15), "conservative Tev threshold")
        let request=JevDecisionRequest(id:provider,state:JevRequestState(context:"前文",pinyin:"jia"),
            candidates:candidates.map {JevRequestCandidate(id:$0.id,text:$0.text)},maxAgeMilliseconds:1500,provider:provider)
        let below=acceptedResponse(request:request,probabilities:["a":0.2,"b":0.64,"c":0.1,"none":0.06])
        expectEqual(JevDecisionValidator.validate(response:below,request:request,candidates:candidates,policy:policy),
                    .rejected(.thresholdProbability), "Tev does not use cloud probability threshold")
        let accepted=acceptedResponse(request:request,probabilities:["a":0.2,"b":0.65,"c":0.1,"none":0.05])
        guard case .accepted = JevDecisionValidator.validate(response:accepted,request:request,candidates:candidates,policy:policy) else {
            fatalError("Tev threshold boundary rejected")
        }
    }
    let custom=JevDecisionPolicy.inputMethod(localProbability:0.8,jevProbability:0.7,tevProbability:0.75)
    expectEqual(custom.threshold(for:"local").minimumProbability, 0.8, "custom TT threshold preserved")
    expectEqual(custom.threshold(for:"jev").minimumProbability, 0.7, "custom Jev threshold preserved")
    expectEqual(custom.threshold(for:"tev-4b").minimumProbability, 0.75, "independent custom Tev threshold")
}

private func testProviderTimeoutConfiguration() {
    let defaults: [String: Int64] = ["local": 600, "tev-0.8b": 600, "tev-4b": 2000, "jev": 600]
    expectEqual(JevProviders.timeouts(), defaults, "model timeout defaults")
    expectEqual(JevProviders.timeouts(overrides: nil), defaults, "old settings without timeout overrides")
    expectEqual(JevProviders.timeouts(overrides: [:]), defaults, "empty settings retain defaults")
    for provider in JevProviders.active {
        expectEqual(JevProviders.timeoutMilliseconds(provider: provider), defaults[provider], "single model default")
        for valid: Int64 in [300, 875, 10000] {
            let overrides = [provider: valid]
            expectEqual(JevProviders.timeoutMilliseconds(provider: provider, overrides: overrides), valid, "valid stored timeout")
            var expected = defaults
            expected[provider] = valid
            expectEqual(JevProviders.timeouts(overrides: overrides), expected, "override affects only the matching model")
        }
        for invalid: Int64 in [Int64.min, -1, 0, 299, 10001, Int64.max] {
            let overrides = [provider: invalid]
            expectEqual(JevProviders.timeoutMilliseconds(provider: provider, overrides: overrides), defaults[provider], "invalid stored timeout falls back")
            expectEqual(JevProviders.timeouts(overrides: overrides), defaults, "invalid stored timeout does not alter model defaults")
        }
    }
    let custom: [String: Int64] = ["local": 300, "tev-0.8b": 875, "tev-4b": 10000, "jev": 1421]
    let stored = custom.merging(["off": 4000, "unknown": 9000]) { first, _ in first }
    expectEqual(JevProviders.timeouts(overrides: stored), custom, "only active model keys are returned")

    let generic = JevCoordinatorConfiguration()
    expectEqual(generic.providerTimeouts, [:], "generic configuration opts out of model-specific defaults")
    expectEqual(generic.promoteDeadlineMilliseconds, 600, "legacy generic promotion deadline")
    expectEqual(generic.annotateDeadlineMilliseconds, 1500, "legacy generic annotation deadline")
    expectEqual(generic.maxAgeMilliseconds, 1500, "legacy generic max age")
    expectEqual(generic.effectiveDeadlineMilliseconds, 1500, "legacy generic final deadline")
    for provider in JevProviders.active + ["unknown"] {
        expectEqual(generic.promoteDeadlineMilliseconds(for: provider), 600, "unconfigured provider uses generic promotion")
        expectEqual(generic.effectiveDeadlineMilliseconds(for: provider), 1500, "unconfigured provider uses generic final deadline")
    }
    let overridden = JevCoordinatorConfiguration(promoteDeadlineMilliseconds: 400,
        annotateDeadlineMilliseconds: 1200, maxAgeMilliseconds: 900, providerTimeouts: custom)
    expectEqual(overridden.providerTimeouts, custom, "configuration retains provider overrides")
    expectEqual(overridden.effectiveDeadlineMilliseconds, 900, "generic final deadline still honors max age")
    expectEqual(overridden.promoteDeadlineMilliseconds(for: "unknown"), 400, "unmatched provider retains custom generic promotion")
    expectEqual(overridden.effectiveDeadlineMilliseconds(for: "unknown"), 900, "unmatched provider retains custom generic final deadline")
    for (provider, timeout) in custom {
        expectEqual(overridden.promoteDeadlineMilliseconds(for: provider), timeout, "model timeout overrides promotion")
        expectEqual(overridden.effectiveDeadlineMilliseconds(for: provider), timeout, "model timeout overrides both generic final limits")
    }
}

private func testParseTimeoutSeconds() {
    let valid: [(String, Int64)] = [
        ("0.3", 300), ("10", 10000), (" \t0.6\r\n", 600), ("2e0", 2000),
        ("0.6254", 625), ("0.6255", 626), ("0.3001", 300), ("9.9999", 10000)
    ]
    for (text, expected) in valid {
        expectEqual(JevProviders.parseTimeoutSeconds(text), expected, "timeout seconds are trimmed and rounded: \(text)")
    }
    for text in ["", " \t\n", "abc", "1 second", "0,6", "1 0", "NaN", "nan", "inf", "-inf",
                 "Infinity", "1e309", "0", "-0.3", "0.2999", "10.0001", "10000", "1e-300"] {
        expectEqual(JevProviders.parseTimeoutSeconds(text), nil, "invalid timeout seconds rejected before rounding: \(text)")
    }
}

private func testGenericCustomDeadlines() {
    for (annotation, maxAge): (Int64, Int64) in [(900, 750), (750, 900)] {
        let configuration = JevCoordinatorConfiguration(promoteDeadlineMilliseconds: 300,
            annotateDeadlineMilliseconds: annotation, maxAgeMilliseconds: maxAge, providerTimeouts: ["local": 2000])
        let cases: [(Int64, JevDecisionAction?)] = [(299, .promote), (300, .annotate), (750, .annotate), (751, nil)]
        for (age, action) in cases {
            let clock = TestClock(), transport = TestTransport(), decisions = DecisionBox()
            let scheduler = TestScheduler(clock: clock)
            let coordinator = JevDecisionCoordinator(configuration: configuration, clock: clock, scheduler: scheduler,
                transport: transport.closure, onDecision: { decisions.values.append($0) })
            coordinator.onNewSnapshot(snapshot(identity: "generic-custom", provider: "jev"))
            scheduler.advance(to: 260)
            let request = transport.requests[0]
            expectEqual(request.maxAgeMilliseconds, 490, "generic wire budget honors the smaller final limit")
            scheduler.advance(to: age)
            transport.respond(acceptedResponse(request: request))
            scheduler.runDue()
            expectEqual(decisions.values.last?.action, action, "unmatched provider preserves custom generic deadline boundaries")
        }
    }
}

private let timeoutConfigurations = [
    JevProviders.timeouts(),
    JevProviders.timeouts(overrides: ["local": 300, "tev-0.8b": 1250, "tev-4b": 800, "jev": 10000])
]

private func testProviderTimeoutDeadlines() {
    for timeouts in timeoutConfigurations {
        for provider in JevProviders.active {
            let timeout = timeouts[provider]!
            for age in Set([timeout - 1, timeout, timeout + 1, 1800]) {
                let clock = TestClock(), transport = TestTransport(), decisions = DecisionBox()
                let scheduler = TestScheduler(clock: clock)
                let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport,
                    decisions: decisions, providerTimeouts: timeouts)
                coordinator.onNewSnapshot(snapshot(identity: "deadline-" + provider, provider: provider))
                scheduler.advance(to: 260)
                let request = transport.requests[0]
                let object = try! JSONSerialization.jsonObject(with: request.jsonData()) as! [String: Any]
                expectEqual(object["max_age_ms"] as? Int64, timeout - 260, "\(provider) sends only the remaining wire budget")
                scheduler.advance(to: age)
                transport.respond(acceptedResponse(request: request))
                scheduler.runDue()
                if age > timeout {
                    expect(decisions.values.isEmpty, "\(provider) discards results beyond its configured deadline")
                    expect(transport.cancelledRequestIDs.contains(request.id), "model deadline cancels transport")
                    expectEqual(coordinator.lastOutcome, "deadline_expired", "model deadline expiry is recorded")
                } else {
                    expectEqual(decisions.values.count, 1, "\(provider) accepts a result within its configured deadline")
                    expectEqual(decisions.values.last?.action, age < timeout ? .promote : .annotate, "model-specific promotion and inclusive final boundary")
                    expectEqual(decisions.values.last?.elapsedMilliseconds, age, "decision age includes debounce")
                    expect(!transport.cancelledRequestIDs.contains(request.id), "transport remains live through the inclusive deadline")
                    transport.respond(acceptedResponse(request: request))
                    scheduler.runDue()
                    expectEqual(decisions.values.count, 1, "model override preserves apply-once behavior")
                }
            }
        }
    }
}

private func testProviderSamplingBudgetAndQueuedExpiry() {
    for timeouts in timeoutConfigurations {
        for provider in JevProviders.active {
            let timeout = timeouts[provider]!
            let samplingCases: [(Int64, Int64)] = [
                (80, 260), (400, 400), (80, 450), (timeout - 1, timeout - 1), (timeout, timeout), (timeout + 1, timeout + 1)
            ]
            for (samplingAge, sendAge) in samplingCases {
                let clock = TestClock(), transport = TestTransport(), decisions = DecisionBox()
                let scheduler = TestScheduler(clock: clock)
                let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport,
                    decisions: decisions, providerTimeouts: timeouts)
                let startedAt: Int64 = 1000
                clock.advance(by: startedAt + samplingAge)
                coordinator.onNewSnapshot(snapshot(identity: "sampling-" + provider, provider: provider), startedAtMilliseconds: startedAt)
                scheduler.advance(to: startedAt + sendAge)
                if sendAge >= timeout {
                    expect(transport.requests.isEmpty, "sampling or scheduler delay that exhausts the budget sends no request")
                    expectEqual(coordinator.lastOutcome, "deadline_expired", "expired sampling uses the selected model timeout")
                    continue
                }
                expectEqual(transport.requests.count, 1, "sampling leaves a positive request budget")
                let request = transport.requests[0]
                expectEqual(request.maxAgeMilliseconds, timeout - sendAge, "wire budget includes sampling and actual scheduler delay")
                // Queue the response first, then advance only the clock. Receive runs
                // before the due expiry task and must independently reject the result.
                transport.respond(acceptedResponse(request: request))
                clock.advance(by: timeout + 1 - sendAge)
                scheduler.runDue()
                expect(decisions.values.isEmpty, "a queued result cannot extend the deadline while waiting for delivery")
                expect(transport.cancelledRequestIDs.contains(request.id), "receive cancels transport after the model deadline")
                expectEqual(coordinator.lastOutcome, "deadline_expired", "receive enforces the original sampling start time")
            }
        }
    }
}

private func testProviderTimeoutLocks() {
    for timeouts in timeoutConfigurations {
        for provider in JevProviders.active {
            for commitLocked in [false, true] {
                let clock = TestClock(), transport = TestTransport(), decisions = DecisionBox()
                let scheduler = TestScheduler(clock: clock)
                let coordinator = makeCoordinator(clock: clock, scheduler: scheduler, transport: transport,
                    decisions: decisions, providerTimeouts: timeouts)
                coordinator.onNewSnapshot(snapshot(identity: "locked-" + provider, provider: provider))
                scheduler.advance(to: 260)
                scheduler.advance(to: timeouts[provider]! - 1)
                transport.respond(acceptedResponse(request: transport.requests[0]))
                if commitLocked { coordinator.lockCommit() } else { coordinator.lockSorting() }
                scheduler.runDue()
                expectEqual(decisions.values.last?.action, commitLocked ? nil : .annotate, "model deadline never overrides sort or commit locks")
                expectEqual(coordinator.lastOutcome, commitLocked ? "commit_locked" : "annotate", "locked model result outcome")
                coordinator.onNewSnapshot(snapshot(identity: "unlocked-" + provider, provider: provider))
                scheduler.advance(by: 260)
                let current = transport.requests[1]
                transport.respond(acceptedResponse(request: current))
                scheduler.runDue()
                expectEqual(decisions.values.last?.requestID, current.id, "new snapshot clears previous model locks")
                expectEqual(decisions.values.last?.action, .promote, "fresh model snapshot can promote")
            }
        }
    }
}

private func testStaleTevVariantResponses(providerTimeouts: [String: Int64] = [:]) {
    let clock=TestClock(), transport=TestTransport(), decisions=DecisionBox()
    let scheduler=TestScheduler(clock:clock)
    let coordinator=makeCoordinator(clock:clock,scheduler:scheduler,transport:transport,decisions:decisions,providerTimeouts:providerTimeouts)
    // Reuse input identity across a small -> large -> small switch: even a matching
    // provider must not revive an earlier generation of the request.
    coordinator.onNewSnapshot(snapshot(identity:"same-input",provider:"tev-0.8b"))
    scheduler.advance(by:260)
    let small=transport.requests[0]
    transport.respond(acceptedResponse(request:small))
    coordinator.setProvider("tev-4b")
    scheduler.runDue()
    expect(decisions.values.isEmpty, "queued small-model callback is invalidated before delivery")
    expect(transport.cancelledRequestIDs.contains(small.id), "small-model transport is cancelled")
    coordinator.onNewSnapshot(snapshot(identity:"same-input",provider:"tev-4b"))
    scheduler.advance(by:260)
    let large=transport.requests[1]
    transport.respond(acceptedResponse(request:small))
    scheduler.runDue()
    expect(decisions.values.isEmpty, "late response from the old variant is ignored")
    transport.respond(acceptedResponse(request:large,provider:"tev-0.8b"))
    scheduler.runDue()
    expect(decisions.values.isEmpty, "new request rejects a different Tev variant")
    coordinator.setProvider("tev-0.8b")
    coordinator.onNewSnapshot(snapshot(identity:"same-input",provider:"tev-0.8b"))
    scheduler.advance(by:260)
    let newSmall=transport.requests[2]
    transport.respond(acceptedResponse(request:small))
    transport.respond(acceptedResponse(request:large))
    scheduler.runDue()
    expect(decisions.values.isEmpty, "returning to small does not accept either stale model response")
    transport.respond(acceptedResponse(request:newSmall))
    scheduler.runDue()
    expectEqual(decisions.values.count, 1, "current variant produces one decision")
    expectEqual(decisions.values[0].requestID, newSmall.id, "decision belongs to current variant generation")
}

private func testParallelModelDeadlinesAndPriority() {
    for priority in [["jev","tev-4b"],["tev-4b","jev"]] {
        for lockBeforeSecond in [false,true] {
            let clock=TestClock()
            let shared=TestScheduler(clock:clock)
            var choices:[String:JevCandidate]=[:]
            var coordinators:[String:JevDecisionCoordinator]=[:]
            var transports:[String:TestTransport]=[:]
            for provider in priority {
                let transport=TestTransport();transports[provider]=transport
                let coordinator=JevDecisionCoordinator(configuration:JevCoordinatorConfiguration(providerTimeouts:["jev":600,"tev-4b":2000]),clock:clock,scheduler:shared,transport:transport.closure,onDecision:{ decision in
                    if decision.action == .promote {choices[decision.provider]=decision.candidate}
                })
                coordinators[provider]=coordinator
                coordinator.onNewSnapshot(snapshot(identity:"parallel",provider:provider))
            }
            shared.advance(to:260)
            expectEqual(transports["jev"]!.requests[0].maxAgeMilliseconds,340,"independent cloud budget")
            expectEqual(transports["tev-4b"]!.requests[0].maxAgeMilliseconds,1740,"independent local budget")
            shared.advance(to:400)
            transports["jev"]!.respond(acceptedResponse(request:transports["jev"]!.requests[0]))
            shared.runDue()
            if lockBeforeSecond {coordinators.values.forEach {$0.lockSorting()}}
            shared.advance(to:1200)
            transports["tev-4b"]!.respond(acceptedResponse(request:transports["tev-4b"]!.requests[0],choiceID:"c",probabilities:["a":0.05,"b":0.1,"c":0.8,"none":0.05]))
            shared.runDue()
            let entries=JevCandidatePlan.entries(baseline:candidates,choices:choices,priority:priority)
            expectEqual(entries.map(\.candidate.id),lockBeforeSecond ? ["b"] : priority.map {$0=="jev" ? "b" : "c"},"local deadline remains independent and user priority wins over response order")
            coordinators.values.forEach {$0.invalidate()}
        }
    }
}

@main
private enum JevCoreTests {
    static func main() {
        testParallelModelDeadlinesAndPriority()
        testRequestWireAndDebounce()
        testFirstCandidateStillProducesDecision()
        testAbbreviationAndSamplingClock()
        testAThenBThenAAndApplyOnce()
        testLocksAndDeadlines()
        testValidation()
        testProviderResponseDecoding()
        testDisableAndProviderSwitch()
        testProviderConfiguration()
        testProviderTimeoutConfiguration()
        testParseTimeoutSeconds()
        testGenericCustomDeadlines()
        testProviderTimeoutDeadlines()
        testProviderSamplingBudgetAndQueuedExpiry()
        testProviderTimeoutLocks()
        testStaleTevVariantResponses()
        for timeouts in timeoutConfigurations { testStaleTevVariantResponses(providerTimeouts: timeouts) }
        print("JevCoreTests: PASS (wire budgets, debounce, sampling, window caps, first candidate, locks, generic/model deadlines, timeout settings/parsing, thresholds, provider downloads, stale variants)")
    }
}
