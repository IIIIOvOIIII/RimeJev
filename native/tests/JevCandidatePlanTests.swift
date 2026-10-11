import Foundation

@main
struct JevCandidatePlanTests {
    static let baseline = ["邮箱", "又想", "油箱", "幽香"].enumerated().map {
        JevCandidate(id: "c\($0.offset)", text: $0.element, key: "key-\($0.offset)")
    }
    static var cases = 0

    static func check(_ name: String, choices: [String: JevCandidate], priority: [String],
                      expected: [(Int, [String])], baseline: [JevCandidate] = Self.baseline) {
        let actual = JevCandidatePlan.entries(baseline: baseline, choices: choices, priority: priority)
        precondition(actual.map(\.candidate) == expected.map { Self.baseline[$0.0] }, "\(name): candidates")
        precondition(actual.map(\.providers) == expected.map { $0.1 }, "\(name): providers")
        precondition(Set(actual.map { $0.candidate.key }).count == actual.count, "\(name): duplicate candidate")
        precondition(actual.allSatisfy { Set($0.providers).count == $0.providers.count }, "\(name): duplicate label")
        cases += 1
    }

    static func main() {
        let b = baseline
        for local in JevProviders.local {
            for priority in [["jev", local], [local, "jev"]] {
                let high = priority[0], low = priority[1]
                check("both match first", choices: ["jev": b[0], local: b[0]], priority: priority,
                      expected: [(0, priority)])
                check("different recommendations", choices: ["jev": b[2], local: b[3]], priority: priority,
                      expected: priority.map { ($0 == "jev" ? 2 : 3, [$0]) })
                check("same recommendation", choices: ["jev": b[2], local: b[2]], priority: priority,
                      expected: [(2, priority)])
                check("lower priority matches first", choices: [high: b[3], low: b[0]], priority: priority,
                      expected: [(0, [low]), (3, [high])])
                check("higher priority matches first", choices: [high: b[0], low: b[3]], priority: priority,
                      expected: [(0, [high]), (3, [low])])
                check("one failure", choices: [low: b[2]], priority: priority, expected: [(2, [low])])
                check("both failures", choices: [:], priority: priority, expected: [])
                check("invalid choice keeps other", choices: [high: JevCandidate(id: "absent", text: "伪造"), low: b[1]],
                      priority: priority, expected: [(1, [low])])
                check("duplicate priority", choices: [high: b[2], low: b[2]], priority: priority + priority,
                      expected: [(2, priority)])
            }
        }
        for invalid in [JevCandidate(id: b[2].id, text: "伪造", key: b[2].key),
                        JevCandidate(id: "wrong-id", text: b[2].text, key: b[2].key),
                        JevCandidate(id: b[2].id, text: b[2].text, key: "wrong-key")] {
            check("exact baseline membership", choices: ["jev": invalid], priority: ["jev"], expected: [])
        }
        check("empty baseline", choices: ["jev": b[0]], priority: ["jev"], expected: [], baseline: [])
        check("empty priority", choices: ["jev": b[0]], priority: [], expected: [])
        check("unconfigured choices", choices: ["jev": b[0]], priority: ["local"], expected: [])
        check("unknown providers", choices: ["off": b[0], "unknown": b[1], "Jev": b[2], "jev": b[3]],
              priority: ["off", "unknown", "Jev", "jev"], expected: [(3, ["jev"])])
        check("at most one local", choices: ["local": b[2], "tev-4b": b[3], "jev": b[1]],
              priority: ["local", "tev-4b", "jev"], expected: [(2, ["local"]), (1, ["jev"])])
        check("duplicate baseline entries", choices: ["jev": b[2], "local": b[2]], priority: ["local", "jev"],
              expected: [(2, ["local", "jev"])], baseline: b + [b[2]])
        for empty in [JevCandidate(id: "", text: ""), JevCandidate(id: "empty-text", text: ""),
                      JevCandidate(id: "", text: "空", key: "empty-id")] {
            check("empty candidate fields", choices: ["jev": empty], priority: ["jev"], expected: [], baseline: [empty])
        }
        print("JevCandidatePlanTests PASS: \(cases) cases; dual choices, both priorities, first preservation, merged labels, failures and exact membership")
    }
}
