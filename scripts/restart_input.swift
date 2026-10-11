import AppKit
import Carbon

let bundleID = "im.lynx.inputmethod.RimeJev"
let sourceID = bundleID + ".Hans"
let stateURL = URL(fileURLWithPath: "work/evidence/input-restart.json")
func sourceName(_ source: TISInputSource) -> String {
    guard let value = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "" }
    return unsafeBitCast(value, to: CFString.self) as String
}
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(1) }
let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
if CommandLine.arguments.dropFirst().first == "--stop" {
    let old = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
    var temporaryID = ""
    if sourceName(current) == sourceID {
        let temporary = TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue()
        guard sourceName(temporary) != sourceID, TISSelectInputSource(temporary) == noErr else {
            fail("Cannot temporarily release the active input source; installation stopped.")
        }
        temporaryID = sourceName(temporary)
    }
    let state = ["previous": sourceName(current), "temporary": temporaryID]
    try JSONSerialization.data(withJSONObject: state).write(to: stateURL, options: .atomic)
    old.forEach { _ = $0.terminate() }
    let deadline = Date().addingTimeInterval(5)
    while old.contains(where: { !$0.isTerminated }) && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    guard old.allSatisfy(\.isTerminated) else { fail("Previous input method is still running; installation stopped.") }
    print("Previous input process exited; input-source restart state saved.")
} else if CommandLine.arguments.dropFirst().first == "--restore" {
    let state = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as! [String: String]
    if state["previous"] == sourceID, state["temporary"] == sourceName(current) {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as! [TISInputSource]
        guard let target = sources.first(where: { sourceName($0) == sourceID }), TISSelectInputSource(target) == noErr else {
            fail("Updated input source is registered but needs selection from the input menu.")
        }
        print("Restored the previously selected RimeJev input source.")
    } else { print("Current input-source choice preserved.") }
} else { fail("Usage: restart_input.swift --stop|--restore") }
