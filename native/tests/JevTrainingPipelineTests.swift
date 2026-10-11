import Foundation

private struct PipelineFailure: Error {
    let reason: String
}

private func check(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    if !condition() { throw PipelineFailure(reason: reason) }
}

@main
private enum JevTrainingPipelineTests {
    static func run(directory: URL, corrected: Bool) throws {
        try check(!Thread.isMainThread, "storage must run off main")
        let captureDirectory = directory.appendingPathComponent("capture", isDirectory: true)
        let files = FileManager.default
        let syntheticKey = Data((0..<32).map(UInt8.init))
        var keyRequests: [Bool] = []
        let store = JevTrainingStore(keyProvider: { create in
            keyRequests.append(create)
            return syntheticKey
        })
        let capture = JevTrainingCapture(sink: { store.submit($0) }, clock: {
            Date(timeIntervalSince1970: 1_791_734_400)
        })
        var settings = JevTrainingSettings()
        settings.directory = captureDirectory.path
        settings.includedApps = ["synthetic.pipeline.editor"]
        settings.includeContext = true
        settings.includeModels = true
        let baseline = [JevCandidate(id: "c0", text: "邮箱", key: "native-0"),
                        JevCandidate(id: "c1", text: "油箱", key: "native-1")]
        let position = JevTextPosition(client: "synthetic-client", selected: NSRange(location: 2, length: 0),
                                       marked: NSRange(location: NSNotFound, length: 0))
        func observe() {
            capture.observe(raw: "youxiang", pinyin: "youxiang", prefix: "", displayCode: "you xiang",
                            abbreviated: false, candidates: baseline, displayed: baseline.map(\.text),
                            page: 0, highlighted: 0, environment: ["fixture": "synthetic-pipeline"])
        }

        // Real settings and collector must stay inert until explicit enablement.
        capture.configure(settings, app: "synthetic.pipeline.editor", secureInput: false)
        observe(); capture.choose(method: "digit", index: 1); capture.commit("油箱", position: position)
        try check(capture.written == 0 && keyRequests.isEmpty, "disabled collector emitted or requested key")
        try check(!files.fileExists(atPath: captureDirectory.path), "disabled collector created directory")
        try files.createDirectory(at: captureDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        settings.enabled = true
        settings = try JSONDecoder().decode(JevTrainingSettings.self, from: JSONEncoder().encode(settings))
        try check(settings.permits(app: "synthetic.pipeline.editor", secureInput: false), "actual settings rejected fixture")
        store.configure(settings); store.drain()
        try check(store.status().state == "ready", "store did not become ready")
        capture.configure(settings, app: "synthetic.pipeline.editor", secureInput: false)
        observe()
        guard let token = capture.token else { throw PipelineFailure(reason: "collector snapshot missing") }

        let host = "汽车" as NSString
        let context = JevLineContext.resolve(position: position, confirmedPrefix: "", read: { range in
            JevTextSlice(text: host.substring(with: range), range: range)
        }, verifiedCommitted: { nil })
        try check(context.context == "汽车" && context.source == "current_line", "actual line resolver lost context")
        capture.context(context, token: token)
        let request = JevDecisionRequest(id: token, state: JevRequestState(context: context.context, pinyin: "youxiang"),
                                         candidates: baseline.map { JevRequestCandidate(id: $0.id, text: $0.text) },
                                         maxAgeMilliseconds: 600, provider: "jev")
        let response = JevDecisionResponse(id: token, provider: "jev", model: "SYNTHETIC_MODEL_ONLY_DO_NOT_TRAIN",
                                           choiceID: "c0", probabilities: ["c0": 0.98, "c1": 0.01, "none": 0.01])
        guard case .accepted(let decision) = JevDecisionValidator.validate(response: response, request: request,
                                                                            candidates: baseline, policy: .inputMethod()),
              let modelChoice = baseline.first(where: { $0.id == decision.candidateID }) else {
            throw PipelineFailure(reason: "actual Core validator rejected synthetic model")
        }
        let plan = JevCandidatePlan.entries(baseline: baseline, choices: ["jev": modelChoice], priority: ["jev"])
        try check(plan.count == 1 && plan[0].candidate.id == "c0", "actual candidate plan lost model recommendation")
        capture.modelRequest(token: token, provider: request.provider, modelCandidates: request.candidates, timeout: 600)
        capture.modelResponse(token: token, response: response, elapsed: 1)
        capture.applied(choices: plan, cached: false)
        capture.choose(method: "digit", index: 1) // Human presses digit 2 despite the c0 recommendation.
        capture.commit("油箱", position: position)
        store.drain()

        if corrected {
            let afterCommit = JevTextPosition(client: position.client, selected: NSRange(location: 4, length: 0),
                                              marked: NSRange(location: NSNotFound, length: 0))
            guard let probe = capture.correctionProbe(position: afterCommit) else {
                throw PipelineFailure(reason: "actual correction probe did not link commit")
            }
            try check(probe.ids == [token] && probe.text == "油箱", "correction probe linked wrong selection")
            capture.corrected(ids: probe.ids)
            store.drain()
        }
        let expected = corrected ? 2 : 1
        try check(capture.written == expected && capture.dropped == 0, "collector emission count differs")
        let stored = store.status()
        try check(stored.written == expected && stored.dropped == 0,
                  "store encryption failed: state=\(stored.state), reason=\(stored.reason), written=\(stored.written), dropped=\(stored.dropped)")
        settings.enabled = false
        capture.configure(settings, app: "synthetic.pipeline.editor", secureInput: false)
        store.configure(settings); store.drain()
        try check(store.status().state == "off", "disable and drain did not stop store")

        let encryptedFiles = try store.listFiles(in: captureDirectory)
        try check(!encryptedFiles.isEmpty, "encrypted capture missing")
        var envelopes = 0
        for file in encryptedFiles {
            let ciphertext = try Data(contentsOf: file)
            for marker in ["汽车", "邮箱", "油箱", "youxiang", "SYNTHETIC_MODEL_ONLY_DO_NOT_TRAIN",
                           "\"selection\"", "\"baseline\"", "\\u6c7d\\u8f66", "\\u6cb9\\u7bb1"] {
                try check(ciphertext.range(of: Data(marker.utf8)) == nil, "plaintext leaked into capture file")
            }
            for line in ciphertext.split(separator: 0x0a) {
                guard let envelope = try JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      Set(envelope.keys) == ["schema_version", "sealed"],
                      envelope["schema_version"] as? Int == 2,
                      let sealed = envelope["sealed"] as? String,
                      let bytes = Data(base64Encoded: sealed), bytes.count > 28 else {
                    throw PipelineFailure(reason: "capture is not an encrypted envelope")
                }
                envelopes += 1
            }
        }
        try check(envelopes == expected, "encrypted envelope count differs")

        var selections = 0, corrections = 0
        try store.readRecords(in: captureDirectory) { data in
            guard let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw PipelineFailure(reason: "decrypted record is invalid")
            }
            if record["event_type"] as? String == "selection" {
                selections += 1
                let selected = record["selection"] as? [String: Any]
                let models = record["models"] as? [[String: Any]]
                try check(record["id"] as? String == token, "selection provenance changed")
                try check(selected?["text"] as? String == "油箱" && selected?["candidate_id"] as? String == "c1",
                          "collector used model instead of human label")
                try check(selected?["method"] as? String == "digit" && selected?["status"] as? String == "committed",
                          "collector lost committed digit selection")
                try check((record["context"] as? [String: Any])?["text"] as? String == "汽车", "collector lost context")
                try check((record["input"] as? [String: Any])?["pinyin"] as? String == "youxiang", "collector lost pinyin")
                try check(models?.count == 1 && models?[0]["choice_id"] as? String == "c0" &&
                          models?[0]["model"] as? String == "SYNTHETIC_MODEL_ONLY_DO_NOT_TRAIN" &&
                          models?[0]["applied"] as? Bool == true, "fixture did not exercise actual model capture")
            } else if record["event_type"] as? String == "correction" {
                corrections += 1
                try check(corrected && record["record_id"] as? String == token, "correction did not reference actual selection")
            } else { throw PipelineFailure(reason: "unexpected collector record") }
            // Only authenticated records from the actual Store are sent to exporter stdin.
            try FileHandle.standardOutput.write(contentsOf: data)
            try FileHandle.standardOutput.write(contentsOf: Data([0x0a]))
        }
        try check(selections == 1 && corrections == (corrected ? 1 : 0), "decrypted event counts differ")
        try check(keyRequests == [true, false], "injected key was not used for both encryption and decryption")
        try check(store.status().state == "off", "export read re-enabled capture")
        let summary: [String: Any] = ["records": expected, "selections": selections, "corrections": corrections,
                                      "selection_id": token, "encrypted_files": encryptedFiles.count,
                                      "synthetic_key_only": true, "off_main_read": true, "state": "off"]
        try FileHandle.standardError.write(contentsOf: JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]))
    }

    static func main() {
        guard CommandLine.arguments.count == 3, ["human", "corrected"].contains(CommandLine.arguments[2]) else { exit(2) }
        // Python supplies realpath; Foundation's resolver rewrites /private/var to the /var symlink.
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let corrected = CommandLine.arguments[2] == "corrected"
        Thread {
            do {
                try run(directory: directory, corrected: corrected)
                exit(0)
            } catch {
                let reason = (error as? PipelineFailure)?.reason ?? "native storage or streaming failed"
                try? FileHandle.standardError.write(contentsOf: Data(("FAIL: " + reason).utf8))
                exit(1)
            }
        }.start()
        dispatchMain()
    }
}
