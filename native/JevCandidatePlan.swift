import Foundation

struct JevRecommendation {
    let candidate: JevCandidate
    let providers: [String]
}

enum JevCandidatePlan {
    static func entries(baseline: [JevCandidate], choices: [String: JevCandidate],
                        priority: [String]) -> [JevRecommendation] {
        let candidates = Set(baseline)
        var entries: [JevRecommendation] = []
        var providers = Set<String>()
        var families = Set<String>()
        for provider in priority {
            guard JevProviders.active.contains(provider), providers.insert(provider).inserted,
                  families.insert(provider == "jev" ? "jev" : "local").inserted,
                  let candidate = choices[provider], candidates.contains(candidate),
                  !candidate.id.isEmpty, !candidate.key.isEmpty, !candidate.text.isEmpty else { continue }
            if let index = entries.firstIndex(where: { $0.candidate.key == candidate.key }) {
                entries[index] = JevRecommendation(candidate: entries[index].candidate,
                                                   providers: entries[index].providers + [provider])
            } else {
                entries.append(JevRecommendation(candidate: candidate, providers: [provider]))
            }
        }
        if let first = baseline.first,
           let index = entries.firstIndex(where: { $0.candidate == first }), index != 0 {
            entries.insert(entries.remove(at: index), at: 0)
        }
        return entries
    }
}
