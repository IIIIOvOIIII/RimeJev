import Foundation

// This file deliberately depends only on Foundation.  The Squirrel/Rime
// adapter owns the actual candidate menu, UI transaction, and session state.

public struct JevCandidate: Equatable, Hashable {
    public let id: String
    public let text: String
    public let key: String

    public init(id: String, text: String, key: String = "") {
        self.id = id
        self.text = text
        self.key = key.isEmpty ? id : key
    }
}

public typealias Candidate = JevCandidate

public struct JevInputSnapshot: Equatable {
    /// The caller binds session, input, context, options, and any other
    /// display identity into this opaque value.
    public let identity: String
    public let pinyin: String
    public let context: String
    public let candidates: [JevCandidate]
    public let provider: String
    public let abbreviated: Bool

    public init(
        identity: String,
        pinyin: String,
        context: String,
        candidates: [JevCandidate],
        provider: String,
        abbreviated: Bool = false
    ) {
        self.identity = identity
        self.pinyin = pinyin
        self.context = context
        self.candidates = candidates
        self.provider = provider
        self.abbreviated = abbreviated
    }
}

public typealias InputSnapshot = JevInputSnapshot

public enum JevCandidateWindow {
    public static func limit(pinyin: String, displayCode: String) -> Int {
        let initials: Set<String> = ["b","p","m","f","d","t","n","l","g","k","h","j","q","x","zh","ch","sh","r","z","c","s","y","w"]
        let parts=displayCode.lowercased().split { $0.isWhitespace || $0 == "'" }.map(String.init)
        let raw=pinyin.lowercased()
        let consonants=Set("bcdfghjklmnpqrstwxyz")
        let abbreviated=parts.count > 1 && parts.contains(where:initials.contains)
        let initialsOnly=raw.count >= 2 && raw.allSatisfy {consonants.contains($0)}
        return abbreviated || initialsOnly ? 24 : 8
    }
}

public protocol JevMonotonicClock {
    func nowMilliseconds() -> Int64
}

public typealias MonotonicClock = JevMonotonicClock

public struct JevSystemMonotonicClock: JevMonotonicClock {
    public init() {}

    public func nowMilliseconds() -> Int64 {
        Int64(DispatchTime.now().uptimeNanoseconds / 1_000_000)
    }
}

public protocol JevCancellable {
    func cancel()
}

public typealias CancellableHandle = JevCancellable

public final class JevNoopCancellable: JevCancellable {
    public init() {}
    public func cancel() {}
}

public final class JevClosureCancellable: JevCancellable {
    private let cancellation: () -> Void
    private var didCancel = false

    public init(_ cancellation: @escaping () -> Void) {
        self.cancellation = cancellation
    }

    public func cancel() {
        guard !didCancel else { return }
        didCancel = true
        cancellation()
    }
}

public protocol JevScheduler {
    @discardableResult
    func schedule(after milliseconds: Int64, _ action: @escaping () -> Void) -> JevCancellable
}

public final class JevDispatchScheduler: JevScheduler {
    public let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    @discardableResult
    public func schedule(after milliseconds: Int64, _ action: @escaping () -> Void) -> JevCancellable {
        let item = DispatchWorkItem(block: action)
        let delay = max(0, milliseconds)
        queue.asyncAfter(deadline: .now() + .milliseconds(Int(delay)), execute: item)
        return JevDispatchWorkItemCancellable(item)
    }
}

private final class JevDispatchWorkItemCancellable: JevCancellable {
    private let item: DispatchWorkItem

    init(_ item: DispatchWorkItem) {
        self.item = item
    }

    func cancel() {
        item.cancel()
    }
}

public struct JevDecisionThreshold: Equatable {
    public let minimumProbability: Double
    public let minimumMargin: Double

    public init(minimumProbability: Double = 0.0, minimumMargin: Double = 0.0) {
        self.minimumProbability = minimumProbability
        self.minimumMargin = minimumMargin
    }
}

public struct JevDecisionPolicy: Equatable {
    public let defaultThreshold: JevDecisionThreshold
    public let thresholdsByProvider: [String: JevDecisionThreshold]
    public let probabilitySumTolerance: Double

    public init(
        defaultThreshold: JevDecisionThreshold = JevDecisionThreshold(),
        thresholdsByProvider: [String: JevDecisionThreshold] = [:],
        probabilitySumTolerance: Double = 0.000001
    ) {
        precondition(defaultThreshold.minimumProbability.isFinite)
        precondition(defaultThreshold.minimumMargin.isFinite)
        precondition(probabilitySumTolerance.isFinite && probabilitySumTolerance >= 0)
        self.defaultThreshold = defaultThreshold
        self.thresholdsByProvider = thresholdsByProvider
        self.probabilitySumTolerance = probabilitySumTolerance
    }

    public func threshold(for provider: String) -> JevDecisionThreshold {
        thresholdsByProvider[provider] ?? defaultThreshold
    }
}

public struct JevCoordinatorConfiguration: Equatable {
    public let debounceMilliseconds: Int64
    public let promoteDeadlineMilliseconds: Int64
    public let annotateDeadlineMilliseconds: Int64
    public let maxAgeMilliseconds: Int64
    public let policy: JevDecisionPolicy

    public init(
        debounceMilliseconds: Int64 = 260,
        promoteDeadlineMilliseconds: Int64 = 600,
        annotateDeadlineMilliseconds: Int64 = 1500,
        maxAgeMilliseconds: Int64 = 1500,
        policy: JevDecisionPolicy = JevDecisionPolicy()
    ) {
        precondition(debounceMilliseconds >= 0)
        precondition(promoteDeadlineMilliseconds >= 0)
        precondition(annotateDeadlineMilliseconds >= promoteDeadlineMilliseconds)
        precondition(maxAgeMilliseconds >= 0)
        self.debounceMilliseconds = debounceMilliseconds
        self.promoteDeadlineMilliseconds = promoteDeadlineMilliseconds
        self.annotateDeadlineMilliseconds = annotateDeadlineMilliseconds
        self.maxAgeMilliseconds = maxAgeMilliseconds
        self.policy = policy
    }

    /// Both the coordinator deadline and the wire max_age_ms honor the
    /// smaller of the display policy and the request's explicit max age.
    public var effectiveDeadlineMilliseconds: Int64 {
        min(annotateDeadlineMilliseconds, maxAgeMilliseconds)
    }
}

public struct JevRequestState: Codable, Equatable {
    public let context: String
    public let pinyin: String

    public let abbreviated: Bool

    public init(context: String, pinyin: String, abbreviated: Bool = false) {
        self.context = context
        self.pinyin = pinyin
        self.abbreviated = abbreviated
    }
}

public struct JevRequestCandidate: Codable, Equatable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// The wire shape intentionally follows the Python runtime.  `provider` is
/// local coordinator context and is therefore omitted from encoded JSON.
public struct JevDecisionRequest: Encodable, Equatable {
    public let id: String
    public let op: String
    public let state: JevRequestState
    public let candidates: [JevRequestCandidate]
    public let maxAgeMilliseconds: Int64
    public let provider: String

    public init(
        id: String,
        state: JevRequestState,
        candidates: [JevRequestCandidate],
        maxAgeMilliseconds: Int64,
        provider: String,
        op: String = "decide"
    ) {
        self.id = id
        self.op = op
        self.state = state
        self.candidates = candidates
        self.maxAgeMilliseconds = maxAgeMilliseconds
        self.provider = provider
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case op
        case state
        case candidates
        case maxAgeMilliseconds = "max_age_ms"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(op, forKey: .op)
        try container.encode(state, forKey: .state)
        try container.encode(candidates, forKey: .candidates)
        try container.encode(maxAgeMilliseconds, forKey: .maxAgeMilliseconds)
    }

    public func jsonData() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

public typealias DecisionRequest = JevDecisionRequest

public struct JevDecisionResponse: Codable, Equatable {
    public let id: String
    public let status: String
    public let provider: String
    public let model: String
    public let choiceID: String?
    /// Python ProviderResult may return null while loading/error.  Keeping
    /// this optional lets the decoder preserve the response envelope so the
    /// coordinator can safely produce no decision.
    public let probabilities: [String: Double]?
    /// ProviderResult.elapsed_ms is a floating-point millisecond value.
    public let elapsedMilliseconds: Double?

    public init(
        id: String,
        status: String = "ready",
        provider: String,
        model: String = "",
        choiceID: String? = nil,
        probabilities: [String: Double]? = nil,
        elapsedMilliseconds: Double? = nil
    ) {
        self.id = id
        self.status = status
        self.provider = provider
        self.model = model
        self.choiceID = choiceID
        self.probabilities = probabilities
        self.elapsedMilliseconds = elapsedMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case status
        case provider
        case model
        case choiceID = "choice_id"
        case probabilities
        case elapsedMilliseconds = "elapsed_ms"
    }

    /// Short protocol-shaped spelling for adapter code that mirrors
    /// ProviderResult.elapsed_ms.
    public var elapsedMS: Double? {
        elapsedMilliseconds
    }
}

public typealias DecisionResponse = JevDecisionResponse

public struct JevValidatedDecision: Equatable {
    public let candidateID: String
    public let probability: Double
    public let margin: Double

    public init(candidateID: String, probability: Double, margin: Double) {
        self.candidateID = candidateID
        self.probability = probability
        self.margin = margin
    }
}

public enum JevDecisionValidationError: Error, Equatable, CustomStringConvertible {
    case requestIDMismatch
    case providerMismatch
    case statusNotReady
    case duplicateCandidateIDs
    case candidateIDsMismatch
    case probabilitiesMissing
    case probabilityNotFinite(String)
    case probabilityOutOfRange(String)
    case probabilitySumMismatch
    case missingChoiceID
    case unknownChoiceID
    case choiceIsNotTop
    case ambiguousTop
    case thresholdProbability
    case thresholdMargin

    public var description: String {
        switch self {
        case .requestIDMismatch: return "request id mismatch"
        case .providerMismatch: return "provider mismatch"
        case .statusNotReady: return "response is not ready"
        case .duplicateCandidateIDs: return "duplicate candidate ids"
        case .candidateIDsMismatch: return "candidate ids mismatch"
        case .probabilitiesMissing: return "probabilities are missing"
        case .probabilityNotFinite(let id): return "probability is not finite: \(id)"
        case .probabilityOutOfRange(let id): return "probability is out of range: \(id)"
        case .probabilitySumMismatch: return "probabilities do not sum to one"
        case .missingChoiceID: return "missing choice id"
        case .unknownChoiceID: return "unknown choice id"
        case .choiceIsNotTop: return "choice id is not top probability"
        case .ambiguousTop: return "top probability is ambiguous"
        case .thresholdProbability: return "top probability is below threshold"
        case .thresholdMargin: return "top margin is below threshold"
        }
    }
}

public enum JevDecisionValidationResult: Equatable {
    case accepted(JevValidatedDecision)
    case none
    case rejected(JevDecisionValidationError)
}

public typealias ValidationResult = JevDecisionValidationResult

public enum JevDecisionValidator {
    public static let noneID = "none"

    public static func validate(
        response: JevDecisionResponse,
        request: JevDecisionRequest,
        candidates: [JevCandidate],
        policy: JevDecisionPolicy
    ) -> JevDecisionValidationResult {
        guard response.id == request.id else { return .rejected(.requestIDMismatch) }
        guard response.provider == request.provider else { return .rejected(.providerMismatch) }
        guard response.status == "ready" else { return .rejected(.statusNotReady) }

        let candidateIDs = candidates.map(\.id)
        let candidateIDSet = Set(candidateIDs)
        guard candidateIDSet.count == candidateIDs.count else {
            return .rejected(.duplicateCandidateIDs)
        }

        guard let probabilities = response.probabilities else {
            return .rejected(.probabilitiesMissing)
        }

        var expectedIDs = candidateIDSet
        expectedIDs.insert(noneID)
        guard Set(probabilities.keys) == expectedIDs,
              probabilities.count == expectedIDs.count else {
            return .rejected(.candidateIDsMismatch)
        }

        let orderedIDs = candidateIDs + [noneID]
        var total = 0.0
        for id in orderedIDs {
            guard let probability = probabilities[id] else {
                return .rejected(.candidateIDsMismatch)
            }
            guard probability.isFinite else {
                return .rejected(.probabilityNotFinite(id))
            }
            guard (0.0...1.0).contains(probability) else {
                return .rejected(.probabilityOutOfRange(id))
            }
            total += probability
        }
        guard abs(total - 1.0) <= policy.probabilitySumTolerance else {
            return .rejected(.probabilitySumMismatch)
        }

        guard let choiceID = response.choiceID else {
            return .rejected(.missingChoiceID)
        }
        guard expectedIDs.contains(choiceID) else {
            return .rejected(.unknownChoiceID)
        }

        let ranked = orderedIDs
            .compactMap { id -> (id: String, probability: Double)? in
                guard let probability = probabilities[id] else { return nil }
                return (id: id, probability: probability)
            }
            .sorted {
                if $0.probability == $1.probability {
                    return $0.id < $1.id
                }
                return $0.probability > $1.probability
            }

        guard let top = ranked.first else {
            return .rejected(.candidateIDsMismatch)
        }
        if ranked.count > 1, top.probability == ranked[1].probability {
            return .rejected(.ambiguousTop)
        }
        guard choiceID == top.id else {
            return .rejected(.choiceIsNotTop)
        }
        if top.id == noneID {
            return .none
        }

        let secondProbability = ranked.dropFirst().first?.probability ?? 0.0
        let margin = top.probability - secondProbability
        let threshold = policy.threshold(for: response.provider)
        guard top.probability >= threshold.minimumProbability else {
            return .rejected(.thresholdProbability)
        }
        guard margin >= threshold.minimumMargin else {
            return .rejected(.thresholdMargin)
        }

        return .accepted(
            JevValidatedDecision(
                candidateID: top.id,
                probability: top.probability,
                margin: margin
            )
        )
    }
}

public enum JevDecisionAction: String, Equatable {
    case promote
    case annotate
}

public struct JevDecision: Equatable {
    public let requestID: String
    public let candidate: JevCandidate
    public let provider: String
    public let action: JevDecisionAction
    public let probability: Double
    public let margin: Double
    public let elapsedMilliseconds: Int64

    public init(
        requestID: String,
        candidate: JevCandidate,
        provider: String,
        action: JevDecisionAction,
        probability: Double,
        margin: Double,
        elapsedMilliseconds: Int64
    ) {
        self.requestID = requestID
        self.candidate = candidate
        self.provider = provider
        self.action = action
        self.probability = probability
        self.margin = margin
        self.elapsedMilliseconds = elapsedMilliseconds
    }
}

public typealias Decision = JevDecision

public typealias JevTransport = (
    _ request: JevDecisionRequest,
    _ completion: @escaping (JevDecisionResponse) -> Void
) -> JevCancellable

public typealias DecisionTransport = JevTransport

public final class JevDecisionCoordinator {
    public typealias DecisionHandler = (JevDecision) -> Void
    public typealias RequestIDFactory = () -> String

    private final class ActiveVersion {
        let number: UInt64
        let snapshot: JevInputSnapshot
        let startedAtMilliseconds: Int64
        var request: JevDecisionRequest?
        var debounceHandle: JevCancellable?
        var deadlineHandle: JevCancellable?
        var transportHandle: JevCancellable?
        var cancelled = false
        var expired = false
        var applied = false
        var sortingLocked = false
        var commitLocked = false

        init(number: UInt64, snapshot: JevInputSnapshot, startedAtMilliseconds: Int64) {
            self.number = number
            self.snapshot = snapshot
            self.startedAtMilliseconds = startedAtMilliseconds
        }

        func cancel() {
            guard !cancelled else { return }
            cancelled = true
            debounceHandle?.cancel()
            deadlineHandle?.cancel()
            transportHandle?.cancel()
            debounceHandle = nil
            deadlineHandle = nil
            transportHandle = nil
        }
    }

    public let configuration: JevCoordinatorConfiguration
    public let clock: JevMonotonicClock
    public let scheduler: JevScheduler
    public let transport: JevTransport
    public var onDecision: DecisionHandler?
    public private(set) var lastOutcome = "idle"

    public private(set) var isEnabled: Bool

    private let requestIDFactory: RequestIDFactory
    private var nextVersionNumber: UInt64 = 0
    private var currentVersion: ActiveVersion?

    public init(
        configuration: JevCoordinatorConfiguration = JevCoordinatorConfiguration(),
        clock: JevMonotonicClock = JevSystemMonotonicClock(),
        scheduler: JevScheduler = JevDispatchScheduler(),
        enabled: Bool = true,
        transport: @escaping JevTransport,
        requestIDFactory: @escaping RequestIDFactory = { UUID().uuidString },
        onDecision: DecisionHandler? = nil
    ) {
        self.configuration = configuration
        self.clock = clock
        self.scheduler = scheduler
        self.isEnabled = enabled
        self.transport = transport
        self.requestIDFactory = requestIDFactory
        self.onDecision = onDecision
    }

    /// Call this from the adapter's main-thread input snapshot path.  The
    /// method only schedules local work; it never waits for transport or IO.
    public func onNewSnapshot(_ snapshot: JevInputSnapshot, startedAtMilliseconds: Int64? = nil) {
        lastOutcome = "scheduled"
        invalidateCurrentVersion()
        nextVersionNumber &+= 1
        let now=clock.nowMilliseconds()
        let startedAt=min(startedAtMilliseconds ?? now, now)
        let version = ActiveVersion(
            number: nextVersionNumber,
            snapshot: snapshot,
            startedAtMilliseconds: startedAt
        )
        currentVersion = version

        guard isEnabled,
              !snapshot.provider.isEmpty,
              !snapshot.candidates.isEmpty,
              hasUniqueCandidateIDs(snapshot.candidates) else {
            return
        }

        version.debounceHandle = scheduler.schedule(
            after: max(0, configuration.debounceMilliseconds - max(0, now-startedAt))
        ) { [weak self, weak version] in
            guard let self, let version else { return }
            self.beginRequest(for: version)
        }
    }

    public func onSnapshot(_ snapshot: JevInputSnapshot) {
        onNewSnapshot(snapshot)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            invalidateCurrentVersion()
        }
    }

    public func enable() {
        setEnabled(true)
    }

    public func disable() {
        setEnabled(false)
    }

    /// A provider switch invalidates the current version.  The next snapshot
    /// supplies the new provider and starts a fresh request identity.
    public func setProvider(_ provider: String) {
        if currentVersion?.snapshot.provider != provider {
            invalidateCurrentVersion()
        }
    }

    public func lockSorting() {
        currentVersion?.sortingLocked = true
    }

    public func lockSort() {
        lockSorting()
    }

    public func lockCommit() {
        guard let version = currentVersion else { return }
        version.sortingLocked = true
        version.commitLocked = true
    }

    public func invalidate() {
        invalidateCurrentVersion()
    }

    public var currentRequestID: String? {
        currentVersion?.request?.id
    }

    public var currentIdentity: String? {
        currentVersion?.snapshot.identity
    }

    public var currentVersionNumber: UInt64? {
        currentVersion?.number
    }

    private func hasUniqueCandidateIDs(_ candidates: [JevCandidate]) -> Bool {
        Set(candidates.map(\.id)).count == candidates.count
    }

    private func invalidateCurrentVersion() {
        currentVersion?.cancel()
        currentVersion = nil
    }

    private func beginRequest(for version: ActiveVersion) {
        guard currentVersion === version,
              isEnabled,
              !version.cancelled,
              !version.snapshot.provider.isEmpty else {
            return
        }
        version.debounceHandle = nil

        let now = clock.nowMilliseconds()
        let age = max(0, now - version.startedAtMilliseconds)
        let finalDeadline = configuration.effectiveDeadlineMilliseconds
        guard age < finalDeadline else {
            expire(version)
            return
        }

        let requestID = requestIDFactory()
        let request = JevDecisionRequest(
            id: requestID,
            state: JevRequestState(
                context: version.snapshot.context,
                pinyin: version.snapshot.pinyin,
                abbreviated: version.snapshot.abbreviated
            ),
            candidates: version.snapshot.candidates.map {
                JevRequestCandidate(id: $0.id, text: $0.text)
            },
            maxAgeMilliseconds: finalDeadline,
            provider: version.snapshot.provider
        )
        version.request = request

        let remaining = max(0, finalDeadline - age)
        // The deadline is inclusive: a response at exactly max_age_ms is
        // still eligible, while the next monotonic millisecond is expired.
        let deadlineDelay = remaining == Int64.max ? remaining : remaining + 1
        version.deadlineHandle = scheduler.schedule(after: deadlineDelay) { [weak self, weak version] in
            guard let self, let version else { return }
            self.expire(version)
        }

        version.transportHandle = transport(request) { [weak self, weak version] response in
            guard let self, let version else { return }
            // Transport callbacks may be on any queue.  The scheduler is the
            // injected main-thread hop in production and in deterministic tests.
            _ = self.scheduler.schedule(after: 0) { [weak self, weak version] in
                guard let self, let version else { return }
                self.receive(response, for: version)
            }
        }
    }

    private func expire(_ version: ActiveVersion) {
        guard currentVersion === version, !version.cancelled else { return }
        version.expired = true
        lastOutcome = "deadline_expired"
        version.deadlineHandle = nil
        version.transportHandle?.cancel()
        version.transportHandle = nil
    }

    private func receive(_ response: JevDecisionResponse, for version: ActiveVersion) {
        guard currentVersion === version,
              isEnabled,
              !version.cancelled,
              !version.expired,
              let request = version.request,
              response.id == request.id else {
            return
        }

        let elapsed = max(0, clock.nowMilliseconds() - version.startedAtMilliseconds)
        let finalDeadline = configuration.effectiveDeadlineMilliseconds
        guard elapsed <= finalDeadline else {
            expire(version)
            return
        }
        guard !version.applied else { return }

        let validation = JevDecisionValidator.validate(
            response: response,
            request: request,
            candidates: version.snapshot.candidates,
            policy: configuration.policy
        )
        let accepted: JevValidatedDecision
        switch validation {
        case .accepted(let value): accepted=value
        case .none: lastOutcome="none"; return
        case .rejected(let error): lastOutcome=error.description; return
        }
        guard !version.commitLocked else { lastOutcome="commit_locked"; return }

        let action: JevDecisionAction
        if !version.sortingLocked && elapsed < configuration.promoteDeadlineMilliseconds {
            action = .promote
        } else if elapsed <= finalDeadline {
            // Sorting lock intentionally degrades promotion to annotation,
            // including an early response.  The UI owns visibility/layout checks.
            action = .annotate
        } else {
            return
        }

        guard let candidate = version.snapshot.candidates.first(where: {
            $0.id == accepted.candidateID
        }) else {
            return
        }

        version.applied = true
        lastOutcome = action.rawValue
        let decision = JevDecision(
            requestID: request.id,
            candidate: candidate,
            provider: response.provider,
            action: action,
            probability: accepted.probability,
            margin: accepted.margin,
            elapsedMilliseconds: elapsed
        )
        onDecision?(decision)
    }
}

public typealias DecisionCoordinator = JevDecisionCoordinator
