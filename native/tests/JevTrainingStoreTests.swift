import Foundation
import CryptoKit
import Darwin

private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    do {
        if try !condition() { fatalError("JevTrainingStoreTests failed: \(message)") }
    } catch { fatalError("JevTrainingStoreTests failed: \(message)") }
}

private func expectFailure(_ reason: String? = nil, _ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("JevTrainingStoreTests failed: expected failure")
    } catch {
        if let reason { expect(error.localizedDescription == reason, "fixed error code: \(reason)") }
        expect(!error.localizedDescription.contains("synthetic-private"), "error contains no plaintext")
    }
}

private let syntheticKey = Data(repeating: 0x57, count: 32)

private final class FakeKey: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    private let entered = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    let blocked: Bool
    let fail: Bool
    let value: Data

    init(blocked: Bool = false, fail: Bool = false, value: Data = syntheticKey) {
        self.blocked = blocked
        self.fail = fail
        self.value = value
    }

    var flags: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func provide(_ create: Bool) throws -> Data {
        lock.lock()
        calls.append(create)
        let shouldBlock = blocked && calls.count == 1
        lock.unlock()
        if shouldBlock {
            entered.signal()
            expect(release.wait(timeout: .now() + 10) == .success, "test releases key provider")
        }
        if fail { throw NSError(domain: "synthetic-private-error", code: 1) }
        return value
    }

    func waitUntilEntered() {
        expect(entered.wait(timeout: .now() + 5) == .success, "worker reached injected key provider")
    }

    func unblock() { release.signal() }
}

private final class Fixture {
    let root: URL
    var data: URL { root.appendingPathComponent("capture") }
    init(createCaptureDirectory: Bool = true) throws {
        // Foundation rewrites /private/var back to the /var symlink on macOS.
        let canonical = realpath(FileManager.default.temporaryDirectory.path, nil)!
        defer { free(canonical) }
        root = URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
            .appendingPathComponent("rimejev-training-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o755])
        if createCaptureDirectory { try mkdir(data) }
    }
    deinit { try? FileManager.default.removeItem(at: root) }

    func settings(_ enabled: Bool = true, directory: URL? = nil) -> JevTrainingSettings {
        var value = JevTrainingSettings()
        value.enabled = enabled
        value.directory = (directory ?? data).path
        return value
    }

    func mkdir(_ url: URL, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: mode])
    }
}

private func configureAndDrain(_ store: JevTrainingStore, _ settings: JevTrainingSettings) {
    store.configure(settings)
    store.drain()
}

private func contents(_ store: JevTrainingStore, _ directory: URL) throws -> [Data] {
    var result: [Data] = []
    try store.readRecords(in: directory) { result.append($0) }
    return result
}

private func fileMode(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
}

private func testDisabledHasNoIO() throws {
    let fixture = try Fixture(createCaptureDirectory: false)
    let fake = FakeKey()
    let store = JevTrainingStore(keyProvider: fake.provide)
    expect(store.status().state == "off", "initially disabled")
    configureAndDrain(store, fixture.settings(false))
    for _ in 0..<10 { expect(!store.submit(Data("synthetic-private".utf8)), "off rejects records") }
    store.drain()
    expect(fake.flags.isEmpty, "disabled does not access Keychain")
    expect(!FileManager.default.fileExists(atPath: fixture.data.path), "disabled does not create directory")
    expect(store.status().written == 0 && store.status().dropped == 10, "disabled counters")
    configureAndDrain(store, fixture.settings())
    expect(fake.flags.isEmpty && !FileManager.default.fileExists(atPath: fixture.data.path), "enable is lazy")
    configureAndDrain(store, fixture.settings(false))
    expectFailure { _ = try store.listFiles(in: fixture.data) }
    expectFailure { try store.readRecords(in: fixture.data) { _ in fatalError("unexpected record") } }
    expect(fake.flags.isEmpty, "missing read never creates key")
    expect(!FileManager.default.fileExists(atPath: fixture.data.path), "missing read never creates directory")
}

private func testRoundTripAndPermissions() throws {
    let fixture = try Fixture()
    let fake = FakeKey()
    let store = JevTrainingStore(keyProvider: fake.provide)
    let record = Data("{\"text\":\"synthetic-private-测试\"}".utf8)
    configureAndDrain(store, fixture.settings())
    for _ in 0..<3 {
        expect(store.submit(record), "record accepted: \(store.status().state)/\(store.status().reason)")
        store.drain()
        expect(store.status().state == "ready", "roundtrip worker: \(store.status().reason)")
    }
    expect(fake.flags == [true], "one lazy key load per generation")
    let files = try store.listFiles(in: fixture.data)
    expect(files.count == 1 && files[0].pathExtension == "rjcapture", "owned encrypted file only")
    expect(try fileMode(fixture.data) == 0o700, "existing private directory permissions preserved")
    expect(try fileMode(fixture.root) == 0o755, "parent permissions preserved")
    expect(try fileMode(files[0]) == 0o600, "capture file mode")
    let raw = try Data(contentsOf: files[0])
    expect(raw.range(of: Data("synthetic-private".utf8)) == nil, "plaintext absent on disk")
    expect(raw.range(of: record) == nil, "whole record absent on disk")
    let lines = raw.split(separator: 0x0a)
    expect(lines.count == 3, "one envelope per line")
    var nonces = Set<Data>()
    for line in lines {
        let object = try JSONSerialization.jsonObject(with: Data(line)) as! [String: Any]
        expect(Set(object.keys) == ["schema_version", "sealed"], "only envelope fields persist")
        expect(object["schema_version"] as? Int == 1, "schema version")
        let sealed = Data(base64Encoded: object["sealed"] as! String)!
        nonces.insert(sealed.prefix(12))
        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: sealed), using: SymmetricKey(data: syntheticKey))
        expect(plaintext == record, "standard AES-GCM combined representation")
    }
    expect(nonces.count == 3, "fresh nonce for repeated plaintext")
    expect(try contents(store, fixture.data) == [record, record, record], "streaming roundtrip")
    expect(fake.flags == [true, false], "reader never requests key creation")
    expect(store.status().written == 3 && store.status().bytes == raw.count, "written and byte counts")
    configureAndDrain(store, fixture.settings(false))
    let reopened = JevTrainingStore(keyProvider: fake.provide)
    expect(try contents(reopened, fixture.data).count == 3, "disabled offline reader can decrypt existing captures")
    expect(fake.flags.last == false, "offline reader only reads key")
}

private func testMaximumRecordAndRotation() throws {
    let fixture = try Fixture(createCaptureDirectory: false)
    let store = JevTrainingStore(keyProvider: { _ in syntheticKey })
    configureAndDrain(store, fixture.settings())
    expect(!store.submit(Data(repeating: 0x61, count: 128 * 1024 + 1)), "oversized record rejected")
    expect(!FileManager.default.fileExists(atPath: fixture.data.path), "oversized record triggers no IO")
    try fixture.mkdir(fixture.data)
    let record = Data(repeating: 0x61, count: 128 * 1024)
    for _ in 0..<52 {
        expect(store.submit(record), "maximum-size record accepted")
        store.drain()
    }
    let files = try store.listFiles(in: fixture.data)
    expect(files.count == 2, "rotation around eight MiB")
    for file in files {
        let size = try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber
        expect(size.int64Value <= 8 * 1024 * 1024, "rotation does not exceed threshold")
    }
    var count = 0
    try store.readRecords(in: fixture.data) { data in
        expect(data == record, "large records span read chunks")
        count += 1
    }
    expect(count == 52 && store.status().dropped == 1, "all boundary records survive rotation")
}

private func testBoundedQueue() throws {
    let fixture = try Fixture()
    let fake = FakeKey(blocked: true)
    let store = JevTrainingStore(keyProvider: fake.provide)
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data([1])), "first record queued")
    fake.waitUntilEntered()
    let start = DispatchTime.now().uptimeNanoseconds
    var accepted = 1
    for _ in 0..<256 { if store.submit(Data([2])) { accepted += 1 } }
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
    expect(elapsed < 0.25, "input submissions do not wait on key or disk")
    expect(accepted == 128, "128 includes in-flight record")
    expect(store.status().dropped == 129, "overflow accounted exactly")
    fake.unblock()
    store.drain()
    expect(store.status().written == 128, "bounded queue drains")
}

private func testDisableRaceAndGeneration() throws {
    for switchDirectory in [false, true] {
        let fixture = try Fixture()
        let fake = FakeKey(blocked: true)
        let store = JevTrainingStore(keyProvider: fake.provide)
        configureAndDrain(store, fixture.settings())
        expect(store.submit(Data("synthetic-private-old".utf8)), "first pending record")
        fake.waitUntilEntered()
        for _ in 0..<10 { expect(store.submit(Data([2])), "queued old generation") }
        let next = fixture.root.appendingPathComponent("next")
        if switchDirectory { try fixture.mkdir(next) }
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            store.configure(fixture.settings(switchDirectory, directory: next))
            done.signal()
        }
        let deadline = Date().addingTimeInterval(5)
        while store.status().dropped < 10 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
        expect(store.status().dropped == 10, "configure immediately discards queued generation")
        expect(done.wait(timeout: .now() + 0.25) == .success, "configure returns while key provider is blocked")
        expect(store.status().state == "stopping", "off acknowledgement waits for worker cleanup")
        expect(!store.submit(Data([3])), "transition rejects input without blocking")
        fake.unblock()
        store.drain()
        expect(store.status().written == 0, "stale active record discarded before write")
        expect(try store.listFiles(in: fixture.data).isEmpty, "old directory has no late capture")
        if switchDirectory {
            let record = Data("synthetic-private-new".utf8)
            expect(store.submit(record), "new generation accepts")
            store.drain()
            expect(try contents(store, next) == [record], "new records use exact configured directory")
        } else {
            expect(store.status().state == "off", "off acknowledgement")
            expect(!store.submit(Data([4])), "off stays off after worker drains")
            expect(!FileManager.default.fileExists(atPath: next.path), "off does not create new path")
        }
    }
}

private func testQuotaAndRecovery() throws {
    let fixture = try Fixture()
    let fake = FakeKey()
    let store = JevTrainingStore(keyProvider: fake.provide)
    var configuration = fixture.settings()
    configuration.maximumBytes = 1
    configureAndDrain(store, configuration)
    expect(store.submit(Data([1])), "quota assessed asynchronously")
    store.drain()
    expect(store.status().state == "paused" && store.status().reason == "quota_exceeded", "quota pauses")
    expect(fake.flags.isEmpty && store.status().bytes == 0, "quota checked before creating a key")
    expect(try store.listFiles(in: fixture.data).isEmpty, "quota failure creates no capture file")
    expect(!store.submit(Data([1])), "paused rejects immediately")
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data([1])), "explicit configure resumes")
    store.drain()
    let used = store.status().bytes
    configuration.maximumBytes = used
    configureAndDrain(store, configuration)
    expect(store.submit(Data([2])), "reopen quota checked by worker")
    store.drain()
    expect(store.status().reason == "quota_exceeded" && store.status().bytes == used, "existing files count toward quota")
    expect(try contents(store, fixture.data) == [Data([1])], "quota preserves existing data")
}

private func testIdenticalConfigurationAndLatestWins() throws {
    let fixture = try Fixture()
    let fake = FakeKey(blocked: true)
    let store = JevTrainingStore(keyProvider: fake.provide)
    let configuration = fixture.settings()
    configureAndDrain(store, configuration)
    expect(store.submit(Data([1])), "identical-config fixture")
    fake.waitUntilEntered()
    expect(store.submit(Data([2])), "record queued before repeated configure")
    let started = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<100 { store.configure(configuration) }
    expect(DispatchTime.now().uptimeNanoseconds - started < 250_000_000, "identical configure never waits on worker")
    expect(store.status().state == "ready" && store.status().dropped == 0, "identical configure preserves generation")
    fake.unblock()
    store.drain()
    expect(store.status().written == 2 && fake.flags == [true], "identical configuration preserves queue and key")
    store.configure(configuration)
    expect(store.submit(Data([3])), "identical configure remains ready immediately")
    store.drain()
    expect(try store.listFiles(in: fixture.data).count == 1, "identical configure preserves active file")

    let blocked = FakeKey(blocked: true)
    let other = JevTrainingStore(keyProvider: blocked.provide)
    let first = fixture.root.appendingPathComponent("first")
    let intermediate = fixture.root.appendingPathComponent("intermediate")
    let latest = fixture.root.appendingPathComponent("latest")
    try fixture.mkdir(first)
    try fixture.mkdir(latest)
    configureAndDrain(other, fixture.settings(directory: first))
    expect(other.submit(Data([4])), "latest-config fixture")
    blocked.waitUntilEntered()
    other.configure(fixture.settings(false))
    other.configure(fixture.settings(directory: intermediate))
    other.configure(fixture.settings(directory: latest))
    expect(other.status().state == "stopping", "pending configurations do not acknowledge early")
    blocked.unblock()
    other.drain()
    expect(other.status().state == "ready", "only latest configuration becomes ready")
    expect(other.submit(Data([5])), "latest generation accepts")
    other.drain()
    expect(try contents(other, latest) == [Data([5])], "latest directory receives new data")
    expect(!FileManager.default.fileExists(atPath: intermediate.path), "superseded configuration creates no directory")
    expect(try other.listFiles(in: first).isEmpty, "superseded write discarded")
}

private func testSystemTrash() throws {
    let fixture = try Fixture()
    let store = JevTrainingStore(keyProvider: { _ in syntheticKey })
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data("synthetic-trash-fixture".utf8)), "trash fixture accepted")
    store.drain()
    configureAndDrain(store, fixture.settings(false))
    let files = try store.listFiles(in: fixture.data)
    let unrelated = fixture.data.appendingPathComponent("keep.txt")
    try Data([7]).write(to: unrelated)
    try store.trashFiles(files, in: fixture.data)
    expect(try store.listFiles(in: fixture.data).isEmpty, "system Trash removes owned captures")
    expect(try Data(contentsOf: unrelated) == Data([7]), "system Trash preserves unrelated files")
    expect(store.status().state == "off", "trash does not enable capture")
}

private func testInvalidPathsAndDisappearance() throws {
    let fixture = try Fixture()
    let fake = FakeKey()
    let store = JevTrainingStore(keyProvider: fake.provide)
    for path in ["relative/capture", "/", fixture.root.path + "/../capture", "bad\0path"] {
        var configuration = fixture.settings()
        configuration.directory = path
        configureAndDrain(store, configuration)
        expect(store.status().state == "paused", "invalid configuration pauses")
        expect(!store.submit(Data([1])), "invalid path refuses submission")
    }
    let missingParent = fixture.root.appendingPathComponent("missing/child")
    configureAndDrain(store, fixture.settings(directory: missingParent))
    expect(store.submit(Data([1])), "missing directory checked asynchronously")
    store.drain()
    expect(store.status().state == "paused", "missing parent is never fabricated")
    expect(!FileManager.default.fileExists(atPath: missingParent.deletingLastPathComponent().path), "no path fallback")
    let ordinary = fixture.root.appendingPathComponent("ordinary")
    try Data([1]).write(to: ordinary)
    configureAndDrain(store, fixture.settings(directory: ordinary))
    expect(store.submit(Data([1])), "file-as-directory checked asynchronously")
    store.drain()
    expect(store.status().state == "paused" && fake.flags.isEmpty, "invalid path pauses before key")
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data([1])), "initial valid path")
    store.drain()
    let moved = fixture.root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: fixture.data, to: moved)
    expect(store.submit(Data([2])), "disappeared directory checked asynchronously")
    store.drain()
    expect(store.status().state == "paused", "disappearance pauses")
    expect(!FileManager.default.fileExists(atPath: fixture.data.path), "no recreation after disappearance")
    expect(try contents(store, moved) == [Data([1])], "existing data preserved after removal")

    configureAndDrain(store, fixture.settings(directory: moved))
    expect(store.submit(Data([2])), "new generation opens explicit path")
    store.drain()
    let relocated = fixture.root.appendingPathComponent("relocated")
    try FileManager.default.moveItem(at: moved, to: relocated)
    try fixture.mkdir(moved)
    expect(store.submit(Data([3])), "replacement directory checked asynchronously")
    store.drain()
    expect(store.status().reason == "directory_changed", "replacement identity pauses")
    expect(try store.listFiles(in: moved).isEmpty, "replacement directory untouched")
}

private func testCustomDirectoryDeletedBeforeFirstSubmit() throws {
    for removeBeforeConfigure in [false, true] {
        let fixture = try Fixture()
        let fake = FakeKey()
        let store = JevTrainingStore(keyProvider: fake.provide)
        let configuration = fixture.settings()
        if removeBeforeConfigure { try FileManager.default.removeItem(at: fixture.data) }
        configureAndDrain(store, configuration)
        if !removeBeforeConfigure { try FileManager.default.removeItem(at: fixture.data) }
        expect(store.submit(Data("synthetic-private".utf8)), "first write checks chosen directory asynchronously")
        store.drain()
        let status = store.status()
        expect(status.state == "paused" && status.reason == "unsafe_directory", "missing custom directory pauses first write")
        expect(status.written == 0 && status.dropped == 1 && status.bytes == 0, "missing directory records only a drop")
        expect(fake.flags.isEmpty, "missing custom directory never accesses key")
        expect(!FileManager.default.fileExists(atPath: fixture.data.path), "custom directory is never recreated")
        expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).isEmpty, "no replacement or fallback folder")
    }
}

private func testSymlinksHardlinksAndOwnership() throws {
    let fixture = try Fixture()
    let fake = FakeKey()
    let store = JevTrainingStore(keyProvider: fake.provide)
    let target = fixture.root.appendingPathComponent("target")
    try fixture.mkdir(target)
    let link = fixture.root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    for directory in [link, link.appendingPathComponent("child")] {
        configureAndDrain(store, fixture.settings(directory: directory))
        expect(store.submit(Data([1])), "symlink path checked asynchronously")
        store.drain()
        expect(store.status().state == "paused", "no symlink directory traversal")
        expectFailure { _ = try store.listFiles(in: directory) }
    }
    expect(fake.flags.isEmpty, "unsafe paths never access key")
    let secret = target.appendingPathComponent("unrelated.txt")
    try Data("synthetic-private-unrelated".utf8).write(to: secret)
    let bad = target.appendingPathComponent("bad.rjcapture")
    try FileManager.default.createSymbolicLink(at: bad, withDestinationURL: secret)
    expectFailure("unsafe_file") { _ = try store.listFiles(in: target) }
    expectFailure { try store.trashFiles([bad], in: target) }
    try FileManager.default.removeItem(at: bad)
    try FileManager.default.linkItem(at: secret, to: bad)
    expectFailure("unsafe_file") { _ = try store.listFiles(in: target) }
    expectFailure { try store.trashFiles([bad], in: target) }
    try FileManager.default.removeItem(at: bad)
    expect(try store.listFiles(in: target).isEmpty, "unrelated files excluded")
    expectFailure("unsafe_file") { try store.trashFiles([secret], in: target) }
    expectFailure { try store.trashFiles([target.appendingPathComponent("missing.rjcapture")], in: target) }
    try store.trashFiles([], in: target)
    expect(try Data(contentsOf: secret) == Data("synthetic-private-unrelated".utf8), "trash validation preserves unrelated data")
}

private func testExistingDirectoryAndWriteFailure() throws {
    let fixture = try Fixture(createCaptureDirectory: false)
    try fixture.mkdir(fixture.data, mode: 0o755)
    let store = JevTrainingStore(keyProvider: { _ in syntheticKey })
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data([1])), "existing custom directory accepted")
    store.drain()
    expect(try fileMode(fixture.data) == 0o755, "existing custom directory is not chmodded")
    expect(try fileMode(fixture.root) == 0o755, "custom parent is not chmodded")
    let file = try store.listFiles(in: fixture.data)[0]
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    expect(store.submit(Data([2])), "write failure is asynchronous")
    store.drain()
    expect(store.status().state == "paused" && store.status().written == 1, "unwritable file pauses")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    expect(try contents(store, fixture.data) == [Data([1])], "failed write preserves previous record")
}

private func testKeyFailures() throws {
    for fake in [FakeKey(fail: true), FakeKey(value: Data(repeating: 0, count: 31))] {
        let fixture = try Fixture()
        let store = JevTrainingStore(keyProvider: fake.provide)
        configureAndDrain(store, fixture.settings())
        expect(store.submit(Data("synthetic-private".utf8)), "key failure is asynchronous")
        store.drain()
        expect(store.status().state == "paused" && store.status().reason == "key_unavailable", "safe key error")
        expect(try store.listFiles(in: fixture.data).isEmpty, "key failure leaves no plaintext file")
    }
}

private func testTamperAndReaderValidation() throws {
    let fixture = try Fixture()
    let store = JevTrainingStore(keyProvider: { _ in syntheticKey })
    configureAndDrain(store, fixture.settings())
    expect(store.submit(Data("synthetic-private".utf8)), "prepare encrypted fixture")
    store.drain()
    let file = try store.listFiles(in: fixture.data)[0]
    let original = try Data(contentsOf: file)
    let object = try JSONSerialization.jsonObject(with: original) as! [String: Any]
    var sealed = Data(base64Encoded: object["sealed"] as! String)!
    sealed[sealed.count - 1] ^= 1
    var tampered = object
    tampered["sealed"] = sealed.base64EncodedString()
    let tamperedRow = try JSONSerialization.data(withJSONObject: tampered) + Data([0x0a])
    let variants: [(Data, String)] = [
        (tamperedRow, "authentication_failed"),
        (Data("{\"schema_version\":2,\"sealed\":\"AA==\"}\n".utf8), "invalid_envelope"),
        (Data("{\"schema_version\":true,\"sealed\":\"AA==\"}\n".utf8), "invalid_envelope"),
        (Data("{\"schema_version\":1,\"sealed\":\"***\"}\n".utf8), "invalid_envelope"),
        (Data("{\"schema_version\":1,\"sealed\":\"AA==\",\"extra\":1}\n".utf8), "invalid_envelope"),
        (Data("not-json\n".utf8), "invalid_envelope"),
        (Data([0x0a]), "invalid_envelope"),
        (Data(original.dropLast()), "invalid_envelope"),
        (Data(repeating: 0x61, count: 180_000), "invalid_envelope")
    ]
    for (row, failure) in variants {
        try row.write(to: file)
        configureAndDrain(store, fixture.settings())
        var consumed = false
        expectFailure(failure) { try store.readRecords(in: fixture.data) { _ in consumed = true } }
        expect(!consumed, "unauthenticated or malformed record never delivered")
        expect(store.status().state == "paused", "reader failure pauses capture")
        expect(!store.submit(Data([2])), "read failure prevents further capture")
    }
    try original.write(to: file)
    let wrongKey = JevTrainingStore(keyProvider: { _ in Data(repeating: 0x21, count: 32) })
    expectFailure("authentication_failed") { _ = try contents(wrongKey, fixture.data) }
    let missingKey = JevTrainingStore(keyProvider: { create in
        expect(!create, "reader cannot generate replacement key")
        throw NSError(domain: "synthetic-private", code: 1)
    })
    expectFailure("key_unavailable") { _ = try contents(missingKey, fixture.data) }
    expect(try Data(contentsOf: file) == original, "read errors preserve ciphertext")
    try (original + tamperedRow).write(to: file)
    var verifiedRecords = 0
    expectFailure("authentication_failed") {
        try store.readRecords(in: fixture.data) { _ in verifiedRecords += 1 }
    }
    expect(verifiedRecords == 1, "reader streams verified records and stops at corrupt row")
}

private func testConsumerCancellationPreservesErrorAndStatus() throws {
    enum PreviewStop: Error { case limitReached }
    let fixture = try Fixture()
    let store = JevTrainingStore(keyProvider: { _ in syntheticKey })
    configureAndDrain(store, fixture.settings())
    let records = [Data([1]), Data([2]), Data([3])]
    for record in records {
        expect(store.submit(record), "cancellation fixture accepted")
        store.drain()
    }
    let file = try store.listFiles(in: fixture.data)[0]
    let ciphertext = try Data(contentsOf: file)
    let consumerError = NSError(domain: "synthetic-private-consumer", code: 42)
    let errors: [Error] = [PreviewStop.limitReached, CancellationError(), consumerError]
    for (index, expectedError) in errors.enumerated() {
        let before = store.status()
        var callbacks = 0
        do {
            try store.readRecords(in: fixture.data) { record in
                expect(record == records[callbacks], "consumer receives authenticated records in order")
                callbacks += 1
                if callbacks == 2 { throw expectedError }
            }
            fatalError("JevTrainingStoreTests failed: consumer error was swallowed")
        } catch {
            switch index {
            case 0:
                guard case PreviewStop.limitReached = error else {
                    fatalError("JevTrainingStoreTests failed: preview sentinel changed")
                }
            case 1:
                expect(error is CancellationError, "cancellation retains original type")
            default:
                expect(error as NSError === consumerError, "consumer error retains exact object identity")
            }
        }
        expect(callbacks == 2, "consumer stop prevents later callbacks")
        let after = store.status()
        expect(after.state == "ready" && after.reason == before.reason, "consumer stop never pauses storage")
        expect(after.written == before.written && after.dropped == before.dropped && after.bytes == before.bytes,
               "consumer stop preserves storage counters")
        expect(try Data(contentsOf: file) == ciphertext, "consumer stop preserves encrypted file")
    }
    expect(store.submit(Data([4])), "capture continues after consumer cancellation")
    store.drain()
    expect(try contents(store, fixture.data) == records + [Data([4])], "stream can be read again after cancellation")
}

private func testLifecycle() throws {
    let fixture = try Fixture()
    let fake = FakeKey()
    var store: JevTrainingStore? = JevTrainingStore(keyProvider: fake.provide)
    weak let released = store
    configureAndDrain(store!, fixture.settings())
    expect(store!.submit(Data([1])), "lifecycle initial record")
    store!.drain()
    configureAndDrain(store!, fixture.settings(false))
    store!.drain()
    store = nil
    expect(released == nil, "worker releases store after drain")
    let reopened = JevTrainingStore(keyProvider: fake.provide)
    expect(try contents(reopened, fixture.data) == [Data([1])], "fresh store reads old generation")
    configureAndDrain(reopened, fixture.settings())
    expect(reopened.submit(Data([2])), "fresh store writes another file")
    reopened.drain()
    let records = try contents(reopened, fixture.data)
    expect(Set(records) == [Data([1]), Data([2])], "restart preserves records")
    expect(try reopened.listFiles(in: fixture.data).count == 2, "restart never appends a potentially torn old file")
}

@main
private struct JevTrainingStoreTests {
    static func main() {
        let mainThreadStore = JevTrainingStore(keyProvider: { _ in fatalError("main thread accessed key") })
        expectFailure("off_main_required") {
            try mainThreadStore.readRecords(in: URL(fileURLWithPath: "/nonexistent")) { _ in }
        }
        let finished = DispatchSemaphore(value: 0)
        Thread {
            do {
                let tests: [(String, () throws -> Void)] = [
                    ("disabled/no IO", testDisabledHasNoIO),
                    ("roundtrip/nonce/permissions", testRoundTripAndPermissions),
                    ("record boundary/rotation", testMaximumRecordAndRotation),
                    ("nonblocking/bounded queue", testBoundedQueue),
                    ("disable/configuration races", testDisableRaceAndGeneration),
                    ("identical configuration/latest generation", testIdenticalConfigurationAndLatestWins),
                    ("quota/recovery", testQuotaAndRecovery),
                    ("paths/disappearance/replacement", testInvalidPathsAndDisappearance),
                    ("custom directory missing before first submit", testCustomDirectoryDeletedBeforeFirstSubmit),
                    ("symlinks/hardlinks/trash boundaries", testSymlinksHardlinksAndOwnership),
                    ("custom permissions/write failure", testExistingDirectoryAndWriteFailure),
                    ("key failures", testKeyFailures),
                    ("tamper/streaming schema validation", testTamperAndReaderValidation),
                    ("consumer sentinel/cancellation propagation", testConsumerCancellationPreservesErrorAndStatus),
                    ("lifecycle/reopen", testLifecycle)
                ]
                for (name, test) in tests { try test(); print("PASS \(name)") }
                print("JevTrainingStoreTests: all \(tests.count) suites passed (synthetic records and injected keys only)")
                if ProcessInfo.processInfo.environment["RIMEJEV_TEST_SYSTEM_TRASH"] == "1" {
                    try testSystemTrash()
                    print("PASS optional system Trash (one synthetic encrypted file moved to Trash)")
                }
            } catch { fatalError("JevTrainingStoreTests failed with safe error: \(error.localizedDescription)") }
            finished.signal()
        }.start()
        expect(finished.wait(timeout: .now() + 60) == .success, "suite completed within bounded time")
    }
}
