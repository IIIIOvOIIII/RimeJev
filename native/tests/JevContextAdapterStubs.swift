import Foundation
import AppKit

// Only external boundaries are replaced. No input-method registration, windows,
// user settings, subprocesses, sockets, models or credentials are accessed.
protocol IMKTextInput: AnyObject {
    func selectedRange() -> NSRange
    func markedRange() -> NSRange
    func string(from range: NSRange, actualRange: inout NSRange) -> String?
    func attributedSubstring(from range: NSRange) -> NSAttributedString?
}

final class AdapterTextClient: IMKTextInput {
    var text: String
    var selected: NSRange
    var marked = NSRange(location: NSNotFound, length: 0)
    var readable = true
    var reads = 0
    var beforeRead: ((Int) -> Void)?

    init(_ text: String) {
        self.text = text
        selected = NSRange(location: text.utf16.count, length: 0)
    }

    func selectedRange() -> NSRange { selected }
    func markedRange() -> NSRange { marked }
    private func substring(_ range: NSRange) -> String? {
        guard readable, JevTextPosition.valid(range), NSMaxRange(range) <= text.utf16.count else { return nil }
        return (text as NSString).substring(with: range)
    }
    func string(from range: NSRange, actualRange: inout NSRange) -> String? {
        reads += 1
        beforeRead?(reads)
        actualRange = range
        return substring(range)
    }
    func attributedSubstring(from range: NSRange) -> NSAttributedString? {
        substring(range).map { NSAttributedString(string: $0) }
    }
}

struct RimeCandidateListIterator {}
struct RimeContext_stdbool {
    static func rimeStructInit() -> Self { Self() }
}

final class AdapterRimeAPI {
    var properties: [String: String] = [:]
    var installations: [String] = []
    var candidate_list_from_index: ((UInt, inout RimeCandidateListIterator, Int32) -> Bool)?
    private var inputBuffer: UnsafeMutablePointer<CChar>?

    deinit { free(inputBuffer) }
    func setInput(_ input: String) {
        free(inputBuffer)
        inputBuffer = strdup(input)
    }
    func get_input(_ session: UInt) -> UnsafePointer<CChar>? { inputBuffer.map { UnsafePointer($0) } }
    func get_property(_ session: UInt, _ name: String, _ buffer: inout [CChar], _ size: Int) -> Bool {
        guard let value = properties[name] else { return false }
        let bytes = value.utf8CString
        precondition(bytes.count <= size)
        buffer.replaceSubrange(0..<bytes.count, with: bytes)
        return true
    }
    func set_property(_ session: UInt, _ name: String, _ value: String) { properties[name] = value }
    func get_option(_ session: UInt, _ name: String) -> Bool { false }
    func find_session(_ session: UInt) -> Bool { session != 0 }
    func get_context(_ session: UInt, _ context: inout RimeContext_stdbool) -> Bool {
        // Acknowledge the wire only. Candidate placement remains the real Lua
        // bridge's responsibility; do not implement a fake ranking algorithm.
        if let wire = properties["_jev_result"], !wire.isEmpty {
            installations.append(wire)
            properties["_jev_applied"] = wire
        }
        return true
    }
    func free_context(_ context: inout RimeContext_stdbool) -> Bool { true }
    func candidate_list_next(_ iterator: inout RimeCandidateListIterator) -> Bool { false }
    func candidate_list_end(_ iterator: inout RimeCandidateListIterator) {}
}

final class SquirrelInputController {
    var client: IMKTextInput?
    var currentApp = "test.context-adapter"
    var session: UInt = 1
    let rimeAPI = AdapterRimeAPI()
    var updates = 0
    func rimeUpdate() { updates += 1 }
}

struct JevSettings {
    static var current = JevSettings()
    var selectedProviders = ["local"]
    var localThreshold = 0.65
    var jevThreshold = 0.55
    var tevThreshold: Double? = 0.65
    var timeoutOverrides: [String: Int64]?
    func enhancementMode(for app: String) -> String { selectedProviders.count == 2 ? "dual" : selectedProviders.first ?? "off" }
    func providers(for app: String) -> [String] { selectedProviders }
    func permitsEnhancement(for app: String, secureInput: Bool) -> Bool { !secureInput && !selectedProviders.isEmpty }
    static func save() {}
    mutating func setAppMode(_ mode: String, for app: String) {}
    mutating func setAppLocalModel(_ model: String, for app: String) {}
    mutating func setAppOrder(_ order: [String], for app: String) {}
    mutating func followDefault(for app: String) {}
}

func IsSecureEventInputEnabled() -> Bool { false }

final class JevSocketCall: JevCancellable {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

final class JevRuntimeManager {
    struct Pending {
        let request: JevDecisionRequest
        let sentAt: Int64
        let completion: (JevDecisionResponse) -> Void
        let handle: JevSocketCall
    }
    static let shared = JevRuntimeManager()
    var pending: [Pending] = []
    var starts: [[String]] = []

    func reset() { pending.removeAll(); starts.removeAll() }
    func ensureRunning(providers: [String]) { starts.append(providers) }
    func send(_ request: JevDecisionRequest, provider: String,
              completion: @escaping (JevDecisionResponse) -> Void) -> JevCancellable {
        precondition(provider == request.provider)
        let handle = JevSocketCall()
        pending.append(Pending(request: request, sentAt: JevSystemMonotonicClock().nowMilliseconds(),
                               completion: completion, handle: handle))
        return handle
    }
    func respond(provider: String, choice: String) {
        guard let call = pending.last(where: { $0.request.provider == provider }) else {
            preconditionFailure("No actual request for \(provider)")
        }
        precondition(!call.handle.cancelled, "Test response missed its live request")
        let ids = call.request.candidates.map(\.id)
        precondition(ids.contains(choice))
        var probabilities = Dictionary(uniqueKeysWithValues: ids.map {
            ($0, $0 == choice ? 0.9 : 0.1 / Double(ids.count))
        })
        probabilities["none"] = 0.1 / Double(ids.count)
        call.completion(JevDecisionResponse(id: call.request.id, provider: provider,
                                           model: "in-memory-fixture", choiceID: choice,
                                           probabilities: probabilities))
    }
}
