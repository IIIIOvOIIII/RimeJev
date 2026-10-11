import Foundation

/// Captures observed choices, never guesses a gold label from model output.
/// The IME calls this on its event thread; the sink queues encrypted writes.
final class JevTrainingCapture {
    private struct Snapshot {
        let id: String
        let raw: String
        let pinyin: String
        let prefix: String
        let displayCode: String
        let abbreviated: Bool
        var candidates: [JevCandidate]
        var displayed: [String]
        var page: Int
        var highlighted: Int
        var context: JevLineSnapshot?
        var models: [String: [String: Any]] = [:]
        var windows: [String: [String]] = [:]
        var recommended: [String: [String]] = [:]
    }
    private struct Intent { let snapshot: Snapshot; let method: String; let expectedText: String? }
    private let sink: (Data) -> Bool
    private let clock: () -> Date
    private var settings = JevTrainingSettings()
    private var app = ""
    private var allowed = false
    private var sessionID = UUID().uuidString
    private var compositionID = UUID().uuidString
    private var segmentIndex = 0
    private var current: Snapshot?
    private var intent: Intent?
    private var segments: [(Snapshot, String, String)] = []
    private var environment: [String: String] = [:]
    private var lastCommit: (ids: [String], client: String, start: Int, text: String, at: Date)?
    private(set) var written = 0
    private(set) var dropped = 0

    init(sink: @escaping (Data) -> Bool, clock: @escaping () -> Date = Date.init) {
        self.sink = sink; self.clock = clock
    }
    var token: String? { allowed ? current?.id : nil }
    var wantsContext: Bool { allowed && settings.includeContext }
    var hasSnapshot: Bool { allowed && current != nil }

    func configure(_ value: JevTrainingSettings, app: String, secureInput: Bool) {
        let next = value.permits(app: app, secureInput: secureInput)
        if settings != value || self.app != app || allowed != next {
            reset(); lastCommit = nil; sessionID = UUID().uuidString
        }
        settings = value; self.app = app; allowed = next
    }
    func reset() {
        current = nil; intent = nil; segments.removeAll(); segmentIndex = 0
        compositionID = UUID().uuidString
    }
    func detach() { reset(); lastCommit = nil; sessionID = UUID().uuidString }

    func observe(raw: String, pinyin: String, prefix: String, displayCode: String,
                 abbreviated: Bool, candidates: [JevCandidate], displayed: [String],
                 page: Int, highlighted: Int, environment: [String: String]) {
        guard allowed else { return }
        guard !raw.isEmpty else { reset(); return }
        guard raw.utf8.count <= 512, prefix.utf8.count <= 1024, candidates.count <= 24,
              displayed.count <= 32 else { dropped += 1; reset(); return }
        self.environment = environment
        segments.removeAll { !prefix.utf16.starts(with: ($0.0.prefix + $0.1).utf16) }
        if let old = current, old.raw == raw, old.prefix == prefix,
           candidates.count >= old.candidates.count,
           zip(old.candidates,candidates).allSatisfy({ $0.id == $1.id && $0.key == $1.key && $0.text == $1.text }) {
            current?.candidates = candidates
            current?.displayed = displayed; current?.page = page; current?.highlighted = highlighted
            return
        }
        if let pending = intent, let extra = Self.removingPrefix(prefix, pending.snapshot.prefix),
           !extra.isEmpty, pending.snapshot.candidates.filter({ $0.text == extra }).count == 1,
           pending.expectedText == nil || pending.expectedText == extra {
            if segments.count < 16 { segments.append((pending.snapshot, extra, pending.method)) }
            else { dropped += 1; reset() }
        }
        intent = nil
        current = Snapshot(id: UUID().uuidString, raw: raw, pinyin: pinyin, prefix: prefix,
                           displayCode: displayCode, abbreviated: abbreviated, candidates: candidates,
                           displayed: displayed, page: page, highlighted: highlighted)
    }

    func context(_ value: JevLineSnapshot, token: String) {
        guard allowed, settings.includeContext, current?.id == token else { return }
        current?.context = ["current_line","verified_commits"].contains(value.source) && value.position.base != nil ? value : nil
    }
    func clearContext(token: String) {
        if current?.id == token { current?.context = nil }
    }
    func choose(method: String, index: Int? = nil) {
        guard allowed, let snapshot = current else { return }
        let selected = index ?? snapshot.highlighted
        let expected = snapshot.displayed.indices.contains(selected) ? snapshot.displayed[selected] : nil
        intent = Intent(snapshot: snapshot, method: method, expectedText: expected)
    }
    func modelRequest(token: String, provider: String, modelCandidates: [JevRequestCandidate], timeout: Int64) {
        guard allowed, settings.includeModels, current?.id == token else { return }
        current?.windows[provider] = modelCandidates.map(\.id)
        current?.models[provider] = ["provider": provider, "status": "pending_at_selection",
                                    "budget_ms": timeout, "applied": false,
                                    "options": modelCandidates.map { ["id":$0.id,"text":$0.text] }]
    }
    func modelResponse(token: String, response: JevDecisionResponse, elapsed: Double) {
        guard allowed, settings.includeModels, current?.id == token else { return }
        var result = current?.models[response.provider] ?? ["provider": response.provider]
        result["model"] = response.model; result["status"] = response.status
        result["choice_id"] = response.choiceID ?? NSNull() as Any
        if let p = response.probabilities, p.values.allSatisfy({ $0.isFinite }) { result["probabilities"] = p }
        result["elapsed_ms"] = elapsed.isFinite ? elapsed : 0
        result["applied"] = false
        current?.models[response.provider] = result
    }
    func applied(choices: [JevRecommendation], cached: Bool) {
        guard allowed, settings.includeModels else { return }
        for choice in choices {
            current?.recommended[choice.candidate.id] = choice.providers
            guard settings.includeModels else { continue }
            for provider in choice.providers {
                var result = current?.models[provider] ?? ["provider": provider]
                result["applied"] = true; result["choice_id"] = choice.candidate.id
                if cached { result["status"] = "cached" }
                current?.models[provider] = result
            }
        }
    }

    func commit(_ text: String, position: JevTextPosition?) {
        guard allowed, let snapshot = intent?.snapshot ?? current else { reset(); return }
        let selected = Self.removingPrefix(text, snapshot.prefix)
        let expected = intent?.expectedText
        var rows = segments
        let method = intent?.method ?? "automatic"
        if let selected { rows.append((snapshot, selected, method)) }
        else { rows.append((snapshot, text, "unresolved")) }
        var endPrefix = rows.first?.0.prefix ?? ""
        var chainValid = true
        for row in rows {
            chainValid = chainValid && row.0.prefix.utf16.elementsEqual(endPrefix.utf16)
            endPrefix = row.0.prefix + row.1
        }
        chainValid = chainValid && text.utf16.elementsEqual(endPrefix.utf16)
        var emitted: [String] = []
        for (index, row) in rows.enumerated() {
            // A partial choice is usable only when the final commit confirms its prefix.
            let confirmed = text.utf16.starts(with: (row.0.prefix + row.1).utf16)
            let agrees = index != rows.count - 1 || expected == nil || expected == row.1
            let status = chainValid && confirmed && agrees && row.2 != "unresolved" ? "committed" : "raw"
            if let id = emit(row.0, text: row.1, method: row.2, status: status, index: index) { emitted.append(id) }
        }
        if !emitted.isEmpty, let position, let start = position.base, text.utf16.count <= 256,
           start <= Int.max - text.utf16.count {
            lastCommit = (emitted, position.client, start, text, clock())
        } else { lastCommit = nil }
        reset()
    }

    func cancel(_ reason: String) {
        if allowed, let snapshot = current {
            _ = emit(snapshot, text: "", method: reason, status: "cancelled", index: segments.count)
        }
        reset()
    }
    func correctionProbe(position: JevTextPosition) -> (ids: [String], range: NSRange, text: String)? {
        guard allowed, let commit = lastCommit, clock().timeIntervalSince(commit.at) <= 10,
              position.client == commit.client, position.base == commit.start + commit.text.utf16.count,
              !JevTextPosition.valid(position.marked) || position.marked.length == 0 else { return nil }
        return (commit.ids, NSRange(location: commit.start, length: commit.text.utf16.count), commit.text)
    }
    func corrected(ids: [String]) {
        guard allowed, let commit = lastCommit, ids == commit.ids else { return }
        for id in ids {
            write(["schema_version": 1, "event_type": "correction", "id": UUID().uuidString,
                   "record_id": id, "created_at": ISO8601DateFormatter().string(from: clock()),
                   "observation": "edited_after_commit"])
        }
        lastCommit = nil
    }

    private func emit(_ snapshot: Snapshot, text: String, method: String, status: String, index: Int) -> String? {
        guard allowed else { return nil }
        let matches = snapshot.candidates.filter { $0.text.utf16.elementsEqual(text.utf16) }
        let coverage = matches.count == 1 ? "covered" : (matches.isEmpty ? "missing" : "ambiguous")
        let id = snapshot.id
        let display = snapshot.displayed.enumerated().map { rank, word -> [String: Any] in
            let found = snapshot.candidates.filter { $0.text == word }
            return ["id": found.count == 1 ? found[0].id as Any : NSNull(), "text": word, "rank": rank,
                    "providers": settings.includeModels && found.count == 1 ? snapshot.recommended[found[0].id] ?? [] : []]
        }
        let record: [String: Any] = [
            "schema_version": 1, "event_type": "selection", "id": id, "session_id": sessionID,
            "composition_id": compositionID, "segment_index": index,
            "created_at": ISO8601DateFormatter().string(from: clock()), "app_id": app,
            "environment": environment,
            "input": ["raw": snapshot.raw, "pinyin": snapshot.pinyin, "display_code": snapshot.displayCode,
                      "abbreviated": snapshot.abbreviated, "confirmed_prefix": settings.includeContext ? snapshot.prefix : ""],
            "context": ["text": settings.includeContext ? snapshot.context?.context as Any? ?? NSNull() : NSNull(),
                        "source": settings.includeContext ? snapshot.context?.source ?? "not_captured_before_selection" : "omitted_by_user",
                        "length": settings.includeContext ? snapshot.context?.context.count ?? 0 : 0,
                        "truncated": NSNull(), "limit_reached": (snapshot.context?.context.count ?? 0) >= 80],
            "baseline": snapshot.candidates.enumerated().map { rank, candidate in
                ["id": candidate.id, "key": candidate.key, "text": candidate.text, "rank": rank] as [String: Any]
            },
            "display": ["page": snapshot.page, "items": display],
            "model_windows": settings.includeModels ? snapshot.windows : [:],
            "models": settings.includeModels ? snapshot.models.keys.sorted().compactMap { snapshot.models[$0] } : [],
            "selection": ["candidate_id": matches.count == 1 ? matches[0].id as Any : NSNull(), "text": text,
                          "method": method, "coverage": coverage, "status": status, "host_ack": "unknown",
                          "model_coverage": snapshot.windows.mapValues { ids in matches.count == 1 && ids.contains(matches[0].id) }],
            "correction": "unknown"
        ]
        return write(record) ? id : nil
    }
    @discardableResult private func write(_ record: [String: Any]) -> Bool {
        guard JSONSerialization.isValidJSONObject(record),
              let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]),
              data.count <= 131_072, !Self.containsSecretValue(record) else {
            dropped += 1; return false
        }
        if sink(data) { written += 1; return true }
        dropped += 1; return false
    }
    private static func containsSecretValue(_ value:Any) -> Bool {
        if let text=value as? String {return containsSecret(text)}
        if let array=value as? [Any] {return array.contains(where:containsSecretValue)}
        if let object=value as? [String:Any] {return object.values.contains(where:containsSecretValue)}
        return false
    }
    static func containsSecret(_ text: String) -> Bool {
        let pattern = #"(?i)(?:bearer\s+[a-z0-9._-]{12,}|\b(?:sk-|ghp_|github_pat_)[a-z0-9_-]{12,}|\bAKIA[A-Z0-9]{16}|(?:password|passwd|api[_ -]?key|密码)\s*[:=：]\s*[^\s\",}]{4,})"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    private static func removingPrefix(_ text: String, _ prefix: String) -> String? {
        guard text.utf16.starts(with: prefix.utf16) else { return nil }
        let end = text.utf16.index(text.utf16.startIndex, offsetBy: prefix.utf16.count)
        guard let index = String.Index(end, within: text) else { return nil }
        return String(text[index...])
    }
}
