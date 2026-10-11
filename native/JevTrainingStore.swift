import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

struct JevTrainingStoreStatus {
    let state: String
    let reason: String
    let written: Int
    let dropped: Int
    let bytes: Int64
}

final class JevTrainingStore: @unchecked Sendable {
    static let shared = JevTrainingStore()

    private static let recordLimit = 128 * 1024
    private static let rowLimit = ((recordLimit + 28 + 2) / 3) * 4 + 128
    private static let rotationBytes: Int64 = 8 * 1024 * 1024
    private let keyProvider: (Bool) throws -> Data
    private let worker = DispatchQueue(label: "RimeJev.Training.Storage", qos: .utility)
    private let stateLock = NSLock()
    private let ioLock = NSLock()
    private var settings = JevTrainingSettings()
    private var generation: UInt64 = 0
    private var pending: [(Data, UInt64)] = []
    private var running = false
    private var inFlight = false
    private var state = "off"
    private var reason = "disabled"
    private var written = 0
    private var bytes: Int64 = 0

    // OSAtomic supports the application's macOS 13 target. A separate counter
    // lets a contended submit fail immediately while still counting the drop.
    private let dropped = UnsafeMutablePointer<Int64>.allocate(capacity: 1)

    // Protected by ioLock; reset on every configuration generation.
    private var key: SymmetricKey?
    private var directoryIdentity: Identity?
    private var activeFile: (name: String, day: String, identity: Identity)?

    init(keyProvider: ((Bool) throws -> Data)? = nil) {
        self.keyProvider = keyProvider ?? Self.keychainKey
        dropped.initialize(to: 0)
    }

    deinit {
        dropped.deinitialize(count: 1)
        dropped.deallocate()
    }

    /// Input/UI safe: only updates metadata and queues cleanup. "off" in status
    /// acknowledges quiescence; "stopping" means an older operation may be finishing.
    func configure(_ settings: JevTrainingSettings) {
        stateLock.lock()
        guard self.settings != settings else { stateLock.unlock(); return }
        generation &+= 1
        let version = generation
        let discarded = pending
        OSAtomicAdd64Barrier(Int64(pending.count), dropped)
        pending = []
        if self.settings.directory != settings.directory { bytes = 0 }
        self.settings = settings
        state = "stopping"
        reason = ""
        worker.async { self.finishConfiguration(version) }
        stateLock.unlock()
        // Release queued payloads outside the metadata lock.
        withExtendedLifetime(discarded) {}
    }

    private func finishConfiguration(_ version: UInt64) {
        ioLock.lock()
        defer { ioLock.unlock() }
        stateLock.lock()
        defer { stateLock.unlock() }
        guard version == generation else { return }
        key = nil
        directoryIdentity = nil
        activeFile = nil
        state = settings.enabled ? "ready" : "off"
        reason = settings.enabled ? "" : "disabled"
        if settings.enabled && (!Self.validPath(settings.directory) || settings.maximumBytes <= 0) {
            state = "paused"
            reason = "invalid_configuration"
        }
    }

    /// No filesystem, crypto, Keychain, or waiting on a lock on the input path.
    /// The 128-record bound includes the record currently being processed.
    @discardableResult
    func submit(_ data: Data) -> Bool {
        guard data.count <= Self.recordLimit, stateLock.try() else {
            OSAtomicIncrement64Barrier(dropped)
            return false
        }
        defer { stateLock.unlock() }
        guard settings.enabled, state == "ready",
              pending.count + (inFlight ? 1 : 0) < 128 else {
            OSAtomicIncrement64Barrier(dropped)
            return false
        }
        pending.append((data, generation))
        if !running {
            running = true
            worker.async { self.processPending() }
        }
        return true
    }

    func status() -> JevTrainingStoreStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return JevTrainingStoreStatus(state: state, reason: reason, written: written,
                                      dropped: Int(OSAtomicAdd64Barrier(0, dropped)), bytes: bytes)
    }

    /// Tests and offline workers only. Producers should stop before draining.
    func drain() {
        worker.sync {}
    }

    /// Synchronous streaming API: invoke on an offline worker, never the main thread.
    /// The callback receives one authenticated record at a time; nothing is exported.
    /// Consumer errors propagate unchanged and do not alter capture status.
    func readRecords(in directory: URL, consume: (Data) throws -> Void) throws {
        guard !Thread.isMainThread else { throw Failure.offMainRequired }
        ioLock.lock()
        defer { ioLock.unlock() }
        let current = currentGeneration()
        do {
            let fd = try Self.openDirectory(directory, create: false)
            defer { close(fd) }
            let files = try Self.entries(fd)
            guard !files.isEmpty else { return }
            let readKey = try symmetricKey(createAllowed: false)
            for file in files {
                let input = openat(fd, file.name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard input >= 0 else { throw Failure.readFailed }
                defer { close(input) }
                let info = try Self.fileInfo(input)
                guard Identity(info) == Identity(file.info),
                      flock(input, LOCK_SH | LOCK_NB) == 0 else { throw Failure.readFailed }
                try Self.readRows(input, key: readKey, consume: consume)
            }
        } catch let failure as ConsumerFailure {
            throw failure.underlying
        } catch {
            let failure = (error as? Failure) ?? .readFailed
            pause(failure, generation: current)
            throw failure
        }
    }

    func listFiles(in directory: URL) throws -> [URL] {
        ioLock.lock()
        defer { ioLock.unlock() }
        do {
            let fd = try Self.openDirectory(directory, create: false)
            defer { close(fd) }
            return try Self.entries(fd).map { directory.appendingPathComponent($0.name) }
        } catch {
            let failure = (error as? Failure) ?? .readFailed
            pause(failure, generation: currentGeneration())
            throw failure
        }
    }

    /// Moves only directly contained, user-owned regular .rjcapture files to Trash.
    /// A verified file reference binds the system trash operation to the inode.
    func trashFiles(_ files: [URL], in directory: URL) throws {
        guard !files.isEmpty else { return }
        ioLock.lock()
        defer { ioLock.unlock() }
        do {
            let fd = try Self.openDirectory(directory, create: false)
            defer { close(fd) }
            let owned = try Self.entries(fd)
            var names: [String] = []
            for file in files {
                guard file.isFileURL, Self.validPath(file.path),
                      file.deletingLastPathComponent().path == directory.path,
                      file.lastPathComponent.hasSuffix(".rjcapture"),
                      owned.contains(where: { $0.name == file.lastPathComponent }) else {
                    throw Failure.unsafeFile
                }
                if !names.contains(file.lastPathComponent) { names.append(file.lastPathComponent) }
            }
            for name in names {
                let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard input >= 0 else { throw Failure.unsafeFile }
                defer { close(input) }
                let info = try Self.fileInfo(input)
                guard let original = owned.first(where: { $0.name == name }),
                      Identity(info) == Identity(original.info) else { throw Failure.unsafeFile }
                let url = directory.appendingPathComponent(name) as NSURL
                guard let reference = url.perform(NSSelectorFromString("fileReferenceURL"))?
                    .takeUnretainedValue() as? NSURL, reference.isFileReferenceURL(),
                    let resolved = reference.filePathURL else { throw Failure.unsafeFile }
                let parent = try Self.openDirectory(resolved.deletingLastPathComponent(), create: false)
                defer { close(parent) }
                guard Identity(try Self.directoryInfo(parent)) == Identity(try Self.directoryInfo(fd)),
                      Identity(try Self.entryInfo(parent, resolved.lastPathComponent)) == Identity(info) else {
                    throw Failure.unsafeFile
                }
                try Self.trashReference(reference)
            }
            activeFile = nil
            let total = try Self.totalBytes(Self.entries(fd))
            stateLock.lock()
            if directory.path == settings.directory { bytes = total }
            stateLock.unlock()
        } catch {
            let failure = (error as? Failure) ?? .trashFailed
            pause(failure, generation: currentGeneration())
            throw failure
        }
    }

    private func processPending() {
        while true {
            stateLock.lock()
            guard !pending.isEmpty else {
                running = false
                stateLock.unlock()
                return
            }
            let (data, version) = pending.removeFirst()
            let configuration = settings
            inFlight = true
            stateLock.unlock()
            ioLock.lock()
            if isCurrent(version) {
                do {
                    try write(data, settings: configuration, generation: version)
                } catch {
                    OSAtomicIncrement64Barrier(dropped)
                    pause((error as? Failure) ?? .storageFailed, generation: version)
                }
            } else {
                OSAtomicIncrement64Barrier(dropped)
            }
            ioLock.unlock()
            stateLock.lock()
            inFlight = false
            stateLock.unlock()
        }
    }

    private func write(_ data: Data, settings: JevTrainingSettings, generation: UInt64) throws {
        let directory = URL(fileURLWithPath: settings.directory, isDirectory: true)
        // Only the built-in path may be created lazily. A chosen custom folder
        // must still exist when the worker reaches it, including its first write.
        let mayCreate = directoryIdentity == nil && settings.directory == JevTrainingSettings().directory
        let fd = try Self.openDirectory(directory, create: mayCreate)
        defer { close(fd) }
        let identity = Identity(try Self.directoryInfo(fd))
        guard directoryIdentity == nil || directoryIdentity == identity else { throw Failure.directoryChanged }
        directoryIdentity = identity
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw Failure.storageFailed }
        let total = try Self.totalBytes(Self.entries(fd))
        stateLock.lock()
        if self.settings.directory == settings.directory { bytes = total }
        stateLock.unlock()
        // Compute the exact JSONL length before asking Keychain to create a key.
        let placeholder = Envelope(schema_version: 1, sealed: String(repeating: "A", count: ((data.count + 30) / 3) * 4))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let expectedBytes = try encoder.encode(placeholder).count + 1
        guard total <= settings.maximumBytes,
              Int64(expectedBytes) <= settings.maximumBytes - total else { throw Failure.quotaExceeded }
        if key == nil { key = try symmetricKey(createAllowed: total == 0) }
        guard isCurrent(generation) else { throw Failure.superseded }
        guard let key else { throw Failure.keyUnavailable }
        let sealed: AES.GCM.SealedBox
        do { sealed = try AES.GCM.seal(data, using: key, nonce: AES.GCM.Nonce()) }
        catch { throw Failure.cryptoFailed }
        guard let combined = sealed.combined else { throw Failure.cryptoFailed }
        var row = try encoder.encode(Envelope(schema_version: 1, sealed: combined.base64EncodedString()))
        row.append(0x0a)
        guard row.count == expectedBytes else { throw Failure.cryptoFailed }
        // Validate the path again after a potentially slow Keychain operation.
        let fresh = try Self.openDirectory(directory, create: false)
        defer { close(fresh) }
        guard Identity(try Self.directoryInfo(fresh)) == identity else { throw Failure.directoryChanged }
        guard isCurrent(generation) else { throw Failure.superseded }
        let day = Self.dayStamp()
        if let active = activeFile {
            let info = try Self.entryInfo(fd, active.name)
            guard Identity(info) == active.identity else { throw Failure.unsafeFile }
            if active.day != day || info.st_size + Int64(row.count) > Self.rotationBytes {
                activeFile = nil
            }
        }
        let output: Int32
        if let active = activeFile {
            output = openat(fd, active.name, O_WRONLY | O_APPEND | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        } else {
            let name = "capture-" + day + "-" + UUID().uuidString + ".rjcapture"
            output = openat(fd, name, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard output >= 0 else { throw Failure.storageFailed }
            guard fchmod(output, 0o600) == 0 else { close(output); throw Failure.storageFailed }
            do { activeFile = (name, day, Identity(try Self.fileInfo(output))) }
            catch { close(output); throw error }
        }
        guard output >= 0 else { throw Failure.storageFailed }
        defer { close(output) }
        let info = try Self.fileInfo(output)
        guard Identity(info) == activeFile?.identity,
              info.st_mode & 0o777 == 0o600,
              flock(output, LOCK_EX | LOCK_NB) == 0 else { throw Failure.unsafeFile }
        guard isCurrent(generation) else { throw Failure.superseded }
        try row.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(output, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.storageFailed }
                offset += count
            }
        }
        stateLock.lock()
        written += 1
        if self.settings.directory == settings.directory { bytes = total + Int64(row.count) }
        stateLock.unlock()
    }

    private func symmetricKey(createAllowed: Bool) throws -> SymmetricKey {
        do {
            let data = try keyProvider(createAllowed)
            guard data.count == 32 else { throw Failure.keyUnavailable }
            return SymmetricKey(data: data)
        } catch { throw Failure.keyUnavailable }
    }

    private func currentGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation
    }

    private func isCurrent(_ version: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == version && settings.enabled && state == "ready"
    }

    private func pause(_ failure: Failure, generation version: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard version == generation, settings.enabled, state != "stopping" else { return }
        state = "paused"
        reason = failure.rawValue
        OSAtomicAdd64Barrier(Int64(pending.count), dropped)
        pending.removeAll(keepingCapacity: true)
    }

    private struct ConsumerFailure: Error {
        let underlying: Error
    }

    private enum Failure: String, Error, LocalizedError {
        case invalidConfiguration = "invalid_configuration"
        case unsafeDirectory = "unsafe_directory"
        case directoryChanged = "directory_changed"
        case unsafeFile = "unsafe_file"
        case keyUnavailable = "key_unavailable"
        case cryptoFailed = "crypto_failed"
        case quotaExceeded = "quota_exceeded"
        case storageFailed = "storage_failed"
        case readFailed = "read_failed"
        case invalidEnvelope = "invalid_envelope"
        case authenticationFailed = "authentication_failed"
        case trashFailed = "trash_failed"
        case offMainRequired = "off_main_required"
        case superseded
        var errorDescription: String? { rawValue }
    }

    private struct Envelope: Codable {
        let schema_version: Int
        let sealed: String
    }

    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        init(_ info: stat) { device = info.st_dev; inode = info.st_ino }
    }

    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path != "/" &&
            !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }

    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        guard url.isFileURL, validPath(url.path) else { throw Failure.invalidConfiguration }
        let components = url.path.split(separator: "/").map(String.init)
        let defaultPath = JevTrainingSettings().directory
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unsafeDirectory }
        do {
            for (index, component) in components.enumerated() {
                let parentInfo = try directoryInfo(fd)
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                let isVolumeRoot = components.first == "Volumes" && index == 1
                let mayCreate = url.path == defaultPath && index >= components.count - 2
                if next < 0 && errno == ENOENT && create && mayCreate && !isVolumeRoot {
                    if mkdirat(fd, component, 0o700) != 0 && errno != EEXIST { throw Failure.unsafeDirectory }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafeDirectory }
                let info: stat
                do { info = try directoryInfo(next) }
                catch { close(next); throw error }
                if isVolumeRoot && info.st_dev == parentInfo.st_dev {
                    close(next)
                    throw Failure.unsafeDirectory
                }
                close(fd)
                fd = next
            }
            guard try directoryInfo(fd).st_uid == geteuid() else { throw Failure.unsafeDirectory }
            return fd
        } catch {
            close(fd)
            throw error
        }
    }

    private static func directoryInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.unsafeDirectory }
        return info
    }

    private static func validateFile(_ info: stat) throws {
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
              info.st_nlink == 1, info.st_size >= 0 else { throw Failure.unsafeFile }
    }

    private static func fileInfo(_ fd: Int32) throws -> stat {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw Failure.unsafeFile }
        try validateFile(info)
        return info
    }

    private static func entryInfo(_ fd: Int32, _ name: String) throws -> stat {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw Failure.unsafeFile }
        try validateFile(info)
        return info
    }

    private static func entries(_ fd: Int32) throws -> [(name: String, info: stat)] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw Failure.readFailed }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw Failure.readFailed }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [(name: String, info: stat)] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw Failure.readFailed }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name.hasSuffix(".rjcapture") { result.append((name, try entryInfo(fd, name))) }
        }
        return result.sorted { $0.name < $1.name }
    }

    private static func totalBytes(_ files: [(name: String, info: stat)]) throws -> Int64 {
        var total: Int64 = 0
        for file in files {
            let (sum, overflow) = total.addingReportingOverflow(file.info.st_size)
            guard !overflow else { throw Failure.quotaExceeded }
            total = sum
        }
        return total
    }

    private static func dayStamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private static func readRows(_ fd: Int32, key: SymmetricKey, consume: (Data) throws -> Void) throws {
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        var row = Data()
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.readFailed }
            if count == 0 {
                guard row.isEmpty else { throw Failure.invalidEnvelope }
                return
            }
            var start = 0
            for index in 0..<count where buffer[index] == 0x0a {
                guard row.count + index - start <= rowLimit else { throw Failure.invalidEnvelope }
                row.append(contentsOf: buffer[start..<index])
                try decodeRow(row, key: key, consume: consume)
                row.removeAll(keepingCapacity: true)
                start = index + 1
            }
            guard row.count + count - start <= rowLimit else { throw Failure.invalidEnvelope }
            row.append(contentsOf: buffer[start..<count])
        }
    }

    private static func decodeRow(_ row: Data, key: SymmetricKey, consume: (Data) throws -> Void) throws {
        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: row)
            guard let object = try JSONSerialization.jsonObject(with: row) as? [String: Any],
                  Set(object.keys) == ["schema_version", "sealed"], envelope.schema_version == 1 else {
                throw Failure.invalidEnvelope
            }
        } catch { throw Failure.invalidEnvelope }
        guard let combined = Data(base64Encoded: envelope.sealed),
              (28...(recordLimit + 28)).contains(combined.count) else { throw Failure.invalidEnvelope }
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key) }
        catch { throw Failure.authenticationFailed }
        do { try consume(plaintext) }
        catch { throw ConsumerFailure(underlying: error) }
    }

    private static func keychainKey(createAllowed: Bool) throws -> Data {
        let identity: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "RimeJev.Training",
            kSecAttrAccount as String: "CaptureKey",
            kSecAttrSynchronizable as String: false
        ]
        var query = identity
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound, createAllowed else { throw Failure.keyUnavailable }
        var random = Data(count: 32)
        let randomStatus = random.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!)
        }
        guard randomStatus == errSecSuccess else { throw Failure.keyUnavailable }
        var attributes = identity
        attributes[kSecValueData as String] = random
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecDuplicateItem { return try keychainKey(createAllowed: false) }
        guard added == errSecSuccess else { throw Failure.keyUnavailable }
        return random
    }

    private static func trashReference(_ reference: NSURL) throws {
        // Swift's NSURL -> URL bridge converts a file reference to a path URL.
        // Keep the reference in Objective-C so a path replacement cannot redirect
        // the deletion. The system API also works without direct ~/.Trash access.
        typealias TrashMethod = @convention(c) (
            AnyObject, Selector, NSURL, UnsafeMutablePointer<NSURL?>?, UnsafeMutablePointer<NSError?>?
        ) -> ObjCBool
        let manager = FileManager.default
        let selector = NSSelectorFromString("trashItemAtURL:resultingItemURL:error:")
        guard manager.responds(to: selector) else { throw Failure.trashFailed }
        let method = unsafeBitCast(manager.method(for: selector), to: TrashMethod.self)
        guard method(manager, selector, reference, nil, nil).boolValue else { throw Failure.trashFailed }
    }
}
