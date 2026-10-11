import Foundation
import Security

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("JevKeychainTests failed: \(message)") }
}

private final class FakeSecurity {
    var copyStatus = errSecSuccess
    var updateStatus = errSecSuccess
    var addStatus = errSecSuccess
    var deleteStatus = errSecSuccess
    var returnedData: CFTypeRef? = Data("synthetic-key".utf8) as CFData
    var queries: [(String, [String: Any])] = []
    var writes: [[String: Any]] = []

    var api: JevKeychain.SecurityAPI {
        JevKeychain.SecurityAPI(
            copyMatching: { query, result in
                self.queries.append(("read", query as! [String: Any]))
                result?.pointee = self.returnedData
                return self.copyStatus
            },
            add: { query, _ in
                self.queries.append(("add", query as! [String: Any]))
                return self.addStatus
            },
            update: { query, value in
                self.queries.append(("update", query as! [String: Any]))
                self.writes.append(value as! [String: Any])
                return self.updateStatus
            },
            delete: { query in
                self.queries.append(("delete", query as! [String: Any]))
                return self.deleteStatus
            }
        )
    }

    func assertExactQueries() {
        for (operation, query) in queries {
            expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String,
                   "generic-password class")
            expect(query[kSecAttrService as String] as? String == "RimeJev", "fixed service")
            expect(query[kSecAttrAccount as String] as? String == "Jev API", "fixed account")
            if operation == "delete" || operation == "update" {
                expect(query.count == 3, "mutations use only the exact identity")
            }
        }
    }
}

private func expectFailure(_ operation: () throws -> Void) {
    do {
        try operation()
        fatalError("JevKeychainTests failed: expected failure")
    } catch {
        expect(error.localizedDescription == "credential_unavailable", "fixed safe error")
        expect(!String(describing: error).contains("synthetic-key"), "no value in error")
    }
}

private func testReadAndExistence() throws {
    let fake = FakeSecurity()
    let store = JevKeychain.Store(api: fake.api)
    expect(store.hasKey(), "existing key")
    expect(fake.queries[0].1[kSecReturnData as String] == nil, "existence does not read secret")
    expect(fake.queries[0].1[kSecReturnAttributes as String] as? Bool == true, "attributes only")
    let value = try store.read()
    expect(value == "synthetic-key", "UTF-8 value")
    expect(fake.queries[1].1[kSecReturnData as String] as? Bool == true, "read requests value")
    for (_, query) in fake.queries {
        expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String,
               "read exactly one item")
    }
    fake.assertExactQueries()
    for status in [errSecItemNotFound, errSecAuthFailed, errSecInteractionNotAllowed] {
        fake.copyStatus = status
        expect(!store.hasKey(), "unavailable key is false")
        expectFailure { _ = try store.read() }
    }
    fake.copyStatus = errSecSuccess
    for data: CFTypeRef? in [nil, "synthetic-key" as CFString, Data([0xff]) as CFData,
                             Data() as CFData, Data(" \n".utf8) as CFData] {
        fake.returnedData = data
        expectFailure { _ = try store.read() }
    }
}

private func testSave() throws {
    let existing = FakeSecurity()
    try JevKeychain.Store(api: existing.api).save("synthetic-key")
    expect(existing.queries.map { $0.0 } == ["update"], "replace in place without deletion")
    expect(existing.writes[0].count == 1, "only password data is updated")
    expect(existing.writes[0][kSecValueData as String] as? Data == Data("synthetic-key".utf8),
           "save exact UTF-8 bytes")
    existing.assertExactQueries()

    let missing = FakeSecurity()
    missing.updateStatus = errSecItemNotFound
    try JevKeychain.Store(api: missing.api).save("synthetic-key")
    expect(missing.queries.map { $0.0 } == ["update", "add"], "missing item is created")
    expect(missing.queries[1].1[kSecValueData as String] as? Data == Data("synthetic-key".utf8),
           "add contains password data")
    missing.assertExactQueries()

    let failed = FakeSecurity()
    failed.updateStatus = errSecAuthFailed
    expectFailure { try JevKeychain.Store(api: failed.api).save("synthetic-key") }
    expect(failed.queries.map { $0.0 } == ["update"], "failure cannot trigger another mutation")
    failed.updateStatus = errSecItemNotFound
    failed.addStatus = errSecInteractionNotAllowed
    expectFailure { try JevKeychain.Store(api: failed.api).save("synthetic-key") }
    failed.assertExactQueries()

    let invalid = FakeSecurity()
    for value in ["", " ", " key", "key\nvalue", "key\0value", "key\u{7f}value"] {
        expectFailure { try JevKeychain.Store(api: invalid.api).save(value) }
    }
    expect(invalid.queries.isEmpty, "invalid values never reach Security")
}

private func testConcurrentInsert() throws {
    let fake = FakeSecurity()
    var api = fake.api
    var updates = 0
    let base = api
    api = JevKeychain.SecurityAPI(
        copyMatching: base.copyMatching, add: base.add,
        update: { query, values in
            updates += 1
            fake.updateStatus = updates == 1 ? errSecItemNotFound : errSecSuccess
            return base.update(query, values)
        }, delete: base.delete
    )
    fake.addStatus = errSecDuplicateItem
    try JevKeychain.Store(api: api).save("synthetic-key")
    expect(fake.queries.map { $0.0 } == ["update", "add", "update"], "concurrent insert updates exact item")
    fake.assertExactQueries()
}

private func testKeySizeLimit() throws {
    expect(JevKeychain.maxAPIKeyBytes == 2_000, "shared UTF-8 key limit")
    for unit in ["x", "é", "🧪", "\"", "\\", "/"] {
        let value = String(repeating: unit, count: 2_000 / unit.utf8.count)
        let fake = FakeSecurity()
        let store = JevKeychain.Store(api: fake.api)
        expect(value.utf8.count == 2_000, "fixture reaches byte boundary")
        try store.save(value)
        fake.returnedData = Data(value.utf8) as CFData
        let saved = try store.read()
        expect(saved == value, "key at byte limit is accepted")
        let payload = try JSONSerialization.data(withJSONObject: ["api_key": value])
        expect(payload.count < 4_096, "escaped native JSON fits the pipe limit")

        fake.queries.removeAll()
        expectFailure { try store.save(value + "x") }
        expect(fake.queries.isEmpty, "oversized key is rejected before a Security call")
        fake.returnedData = Data((value + "x").utf8) as CFData
        expectFailure { _ = try store.read() }
    }
}

private func testDelete() throws {
    let fake = FakeSecurity()
    let store = JevKeychain.Store(api: fake.api)
    try store.delete()
    fake.deleteStatus = errSecItemNotFound
    try store.delete()
    fake.deleteStatus = errSecAuthFailed
    expectFailure { try store.delete() }
    expect(fake.queries.map { $0.0 } == ["delete", "delete", "delete"], "only exact delete")
    fake.assertExactQueries()
}

@main
private struct JevKeychainTests {
    static func main() throws {
        // Only injected stores are exercised; no live Security API is called.
        try testReadAndExistence()
        try testSave()
        try testConcurrentInsert()
        try testKeySizeLimit()
        try testDelete()
        print("JevKeychainTests passed (injected Security API only)")
    }
}
