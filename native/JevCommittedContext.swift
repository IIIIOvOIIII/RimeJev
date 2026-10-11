import Foundation

struct JevCommittedContext {
    private(set) var text = ""
    private(set) var expectedEnd: Int?
    private(set) var clientIdentity: String?
    private(set) var lastCheckReason = "empty"

    private let idleTimeout: TimeInterval
    private let characterLimit: Int
    private var lastActivity: TimeInterval?
    private var committedAt: TimeInterval?

    init(idleTimeout: TimeInterval = 10, characterLimit: Int = 80) {
        self.idleTimeout = idleTimeout
        self.characterLimit = max(0, characterLimit)
    }

    mutating func reset() {
        text = ""
        expectedEnd = nil
        clientIdentity = nil
        lastActivity = nil
        committedAt = nil
        lastCheckReason = "reset"
    }

    mutating func commit(_ committed: String, at base: Int, client: String, now: TimeInterval) {
        if clientIdentity != client || expectedEnd != base || isIdle(at: now) {
            text = ""
        }
        text = String((text + committed).suffix(characterLimit))
        guard !text.isEmpty else { reset(); return }
        expectedEnd = base + committed.utf16.count
        clientIdentity = client
        lastActivity = now
        committedAt = now
        lastCheckReason = "committed"
    }

    mutating func verify(
        client: String?, base: Int?, preceding: String?, now: TimeInterval,
        deferredCommit: Bool = false
    ) -> Bool {
        guard !text.isEmpty else { return false }
        guard !isIdle(at: now) else { return reject("idle_timeout") }
        guard let client, client == clientIdentity else { return reject("client_mismatch") }
        // Only the caller's immediate commit-update cycle may defer stale host reads.
        if deferredCommit && mayDeferHostCheck(now: now) {
            lastCheckReason = "pending_commit"
            return true
        }
        guard let base else { return reject("missing_cursor") }
        guard base == expectedEnd, base >= text.utf16.count else {
            return reject("cursor_mismatch")
        }
        guard let preceding else { return reject("missing_text") }
        guard preceding.utf16.elementsEqual(text.utf16) else { return reject("text_mismatch") }
        lastCheckReason = "verified"
        return true
    }

    func mayDeferHostCheck(now: TimeInterval) -> Bool {
        guard let committedAt else { return false }
        return now >= committedAt && now - committedAt < 0.25
    }

    // Menu checks are not activity. Expire before recording a new input event.
    mutating func noteActivity(now: TimeInterval) {
        guard !text.isEmpty else { return }
        guard !isIdle(at: now) else { _ = reject("idle_timeout"); return }
        lastActivity = now
    }

    private func isIdle(at now: TimeInterval) -> Bool {
        guard let lastActivity else { return true }
        return now - lastActivity >= idleTimeout
    }

    private mutating func reject(_ reason: String) -> Bool {
        reset()
        lastCheckReason = reason
        return false
    }
}
