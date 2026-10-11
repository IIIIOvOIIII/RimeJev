import Foundation
import CoreServices

// Discover the installed bundle only. Input-source enablement must be requested
// by that bundle's executable, so macOS names the input method in its consent UI.
let path=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/Rime-Jev.app")
let result=LSRegisterURL(path as CFURL,true)
print("launch_services",result)
if result != noErr { exit(1) }
RunLoop.current.run(until:Date().addingTimeInterval(1))
