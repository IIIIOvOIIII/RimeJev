import Foundation

@main
struct JevTrainingPreferencesTests {
  static func main() throws {
    typealias Validation = JevTrainingPreferencesValidation
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
      guard condition() else { fatalError(message) }
    }
    expect(Validation.maximumBytes("1") == 1_048_576, "Minimum capacity")
    expect(Validation.maximumBytes(" 1.5 ") == 1_572_864, "Fractional MB")
    expect(Validation.maximumBytes("102400") == 107_374_182_400, "100 GB capacity")
    for text in ["", "0", "0.99", "-1", "102400.1", "nan", "inf", "1e999", "2 MB", "1,024"] {
      expect(Validation.maximumBytes(text) == nil, "Invalid capacity accepted")
    }
    expect(Validation.directoryURL("") == nil, "Empty path")
    expect(Validation.directoryURL("relative/folder") == nil, "Relative path")
    expect(Validation.directoryURL("/tmp/invalid\0path") == nil, "NUL path")
    expect(Validation.directoryURL("~/Library")?.path.hasPrefix("/") == true, "Home path expansion")
    let defaultDirectory = JevTrainingSettings().directory
    expect(Validation.mayCreateDefaultDirectory(defaultDirectory, explicitlyEnabling: true), "Explicit enable permits default creation")
    expect(!Validation.mayCreateDefaultDirectory(defaultDirectory, explicitlyEnabling: false), "Off/open never creates default")
    expect(!Validation.mayCreateDefaultDirectory(defaultDirectory + "-other", explicitlyEnabling: true), "Custom sibling cannot be created")
    expect(!Validation.mayCreateDefaultDirectory(defaultDirectory + "/child", explicitlyEnabling: true), "Default child cannot be created")

    let files = FileManager.default
    let temporary = files.temporaryDirectory.appendingPathComponent("JevTrainingPreferencesTests-" + UUID().uuidString)
      .resolvingSymlinksInPath()
    try files.createDirectory(at: temporary, withIntermediateDirectories: false)
    defer { try? files.removeItem(at: temporary) }
    let capture = temporary.appendingPathComponent("capture")
    let neighbor = temporary.appendingPathComponent("capture-neighbor")
    try files.createDirectory(at: capture, withIntermediateDirectories: false)
    try files.createDirectory(at: neighbor, withIntermediateDirectories: false)
    expect(Validation.writableDirectory(capture.path) == nil, "Writable directory")
    let afterProbe = try files.contentsOfDirectory(atPath: capture.path)
    expect(afterProbe.isEmpty, "Probe must clean up")
    let missing = temporary.appendingPathComponent("missing")
    expect(Validation.writableDirectory(missing.path) != nil, "Missing directory rejected")
    expect(!files.fileExists(atPath: missing.path), "Probe must not create configured directory")
    expect(Validation.writableDirectory(missing.path, createDefaultDirectory: true) != nil, "Even explicit enable cannot create custom path")
    expect(!files.fileExists(atPath: missing.path), "No silent recreation of a missing custom folder")
    let locked = temporary.appendingPathComponent("locked")
    try files.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
    expect(Validation.writableDirectory(locked.path) != nil, "Unwritable directory rejected")
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)

    let valid = capture.appendingPathComponent("sample.rjcapture")
    let outside = neighbor.appendingPathComponent("sample.rjcapture")
    let plain = capture.appendingPathComponent("sample.jsonl")
    for url in [valid, outside, plain] { try Data("synthetic fixture".utf8).write(to: url) }
    expect(Validation.writableDirectory(valid.path) != nil, "Regular file is not a directory")
    expect(Validation.captureFile(valid, belongsTo: capture), "Direct capture file accepted")
    expect(!Validation.captureFile(outside, belongsTo: capture), "Shared path prefix is not containment")
    expect(!Validation.captureFile(plain, belongsTo: capture), "Plaintext file excluded from deletion")
    let link = capture.appendingPathComponent("linked.rjcapture")
    try files.createSymbolicLink(at: link, withDestinationURL: outside)
    expect(!Validation.captureFile(link, belongsTo: capture), "Symlink outside directory excluded")
    let localLink = capture.appendingPathComponent("local-link.rjcapture")
    try files.createSymbolicLink(at: localLink, withDestinationURL: valid)
    expect(!Validation.captureFile(localLink, belongsTo: capture), "Symlink inside directory excluded")
    let nested = capture.appendingPathComponent("subdir")
    try files.createDirectory(at: nested, withIntermediateDirectories: false)
    let nestedFile = nested.appendingPathComponent("nested.rjcapture")
    try Data().write(to: nestedFile)
    expect(!Validation.captureFile(nestedFile, belongsTo: capture), "Nested files excluded")
    let fakeFile = capture.appendingPathComponent("folder.rjcapture")
    try files.createDirectory(at: fakeFile, withIntermediateDirectories: false)
    expect(!Validation.captureFile(fakeFile, belongsTo: capture), "Capture-named directory excluded")
    print("PASS: capacity bounds, directory probe and cleanup, missing/unwritable paths, deletion containment")
  }
}
