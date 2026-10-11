import Foundation

struct JevTrainingSettings: Codable, Equatable {
    var enabled = false
    var directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Rime-Jev/TrainingData").path
    var scope = "selected"
    var includedApps: [String] = []
    var excludedApps: [String] = []
    var includeContext = true
    var includeModels = true
    var maximumBytes: Int64 = 1_073_741_824
    var tokenizerDirectory: String?

    init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, directory, scope, includedApps, excludedApps, includeContext, includeModels, maximumBytes, tokenizerDirectory
    }
    init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? values.decode(Bool.self, forKey: .enabled)) ?? false
        directory = (try? values.decode(String.self, forKey: .directory)) ?? directory
        scope = (try? values.decode(String.self, forKey: .scope)) ?? "selected"
        includedApps = (try? values.decode([String].self, forKey: .includedApps)) ?? []
        excludedApps = (try? values.decode([String].self, forKey: .excludedApps)) ?? []
        includeContext = (try? values.decode(Bool.self, forKey: .includeContext)) ?? true
        includeModels = (try? values.decode(Bool.self, forKey: .includeModels)) ?? true
        maximumBytes = (try? values.decode(Int64.self, forKey: .maximumBytes)) ?? maximumBytes
        tokenizerDirectory = try? values.decode(String.self, forKey: .tokenizerDirectory)
        if !["selected", "allExceptExcluded"].contains(scope) { scope = "selected"; enabled = false }
        if !(1_048_576...107_374_182_400).contains(maximumBytes) { maximumBytes = 1_073_741_824 }
    }
    func permits(app: String, secureInput: Bool) -> Bool {
        enabled && !secureInput && !app.isEmpty && app != "im.lynx.inputmethod.RimeJev" &&
        app != "com.apple.loginwindow" && !excludedApps.contains(app) &&
        (scope == "allExceptExcluded" || (scope == "selected" && includedApps.contains(app)))
    }
}
