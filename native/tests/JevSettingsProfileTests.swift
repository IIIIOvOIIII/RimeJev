import Foundation

@main
struct JevSettingsProfileTests {
  static let first = "example.settings.first"
  static let second = "example.settings.second"
  static let own = "im.lynx.inputmethod.RimeJev"
  static let jevFirst = ["jev", "local"]
  static let localFirst = ["local", "jev"]
  static var failures = 0

  // No new optional fields: this is a pre-profile settings file, not a new encoder's output.
  static let legacyJSON = """
  {
    "mode": "dual", "allowedApps": ["legacy.off", "legacy.allowed"],
    "appModes": {"legacy.off": "off", "legacy.tt": "local", "legacy.small": "tev-0.8b",
                 "legacy.large": "tev-4b", "legacy.cloud": "jev", "legacy.dual": "dual"},
    "projectRoot": "/synthetic/project", "modelPath": "/synthetic/unused-model",
    "vaultRef": "fixture-unused-ref", "localThreshold": 0.71, "jevThreshold": 0.61,
    "timeoutOverrides": {"local": 1250, "tev-0.8b": 1750, "tev-4b": 4000, "jev": 900}
  }
  """

  static func expect<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    if actual != expected {
      failures += 1
      print("FAIL: \(message): expected \(expected), got \(actual)")
    }
  }

  static func profile(_ settings: JevSettings, _ app: String, mode: String, model: String,
                      order: [String], providers: [String], _ message: String) {
    expect(settings.enhancementMode(for: app), mode, message + " mode")
    expect(settings.localModel(for: app), model, message + " local model")
    expect(settings.modelOrder(for: app), order, message + " order")
    expect(settings.providers(for: app), providers, message + " providers")
  }

  static func storedProfile(_ settings: JevSettings, _ app: String, mode: String,
                            model: String, order: [String], _ message: String) {
    expect(settings.hasAppOverride(app), true, message + " has override")
    expect(settings.appModes[app], Optional(mode), message + " stored mode")
    expect(settings.appLocalModels?[app], Optional(model), message + " stored model")
    expect(settings.appModelOrders?[app], Optional(order), message + " stored order")
  }

  static func encoded(_ settings: JevSettings) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(settings)
  }

  static func legacy() throws -> JevSettings {
    try JSONDecoder().decode(JevSettings.self, from: Data(legacyJSON.utf8))
  }

  static func defaultsAndActivation() {
    var settings = JevSettings()
    expect(settings.defaultMode, nil, "default mode is optional")
    expect(settings.defaultLocalModel, nil, "default model is optional")
    expect(settings.defaultModelOrder, nil, "default order is optional")
    expect(settings.globalMode, "off", "missing global mode")
    expect(settings.globalLocalModel, "local", "missing global model is TT")
    expect(settings.globalOrder, jevFirst, "missing global order")
    for oldMode in ["off", "local", "jev", "dual", "tev-0.8b", "tev-4b"] {
      settings.mode = oldMode
      profile(settings, first, mode: "off", model: "local", order: jevFirst, providers: [],
              "last-selected \(oldMode) never becomes global")
    }
    settings.allowedApps = []
    settings.setGlobalMode("dual")
    settings.setGlobalLocalModel("tev-4b")
    settings.setGlobalOrder(localFirst)
    for app in [first, second] {
      profile(settings, app, mode: "dual", model: "tev-4b", order: localFirst,
              providers: ["tev-4b", "jev"], "unseen app \(app)")
      expect(settings.hasAppOverride(app), false, "unseen app still follows default")
      expect(settings.permitsEnhancement(for: app, secureInput: false), true, "empty allowlist permits global")
    }
    settings.setAppMode("off", for: first)
    expect(settings.permitsEnhancement(for: first, secureInput: false), false, "explicit off beats active global")
    expect(settings.permitsEnhancement(for: second, secureInput: false), true, "other app remains active")
    settings.allowedApps = [first]
    expect(settings.permitsEnhancement(for: first, secureInput: false), false, "allowlist cannot enable explicit off")
    expect(settings.permitsEnhancement(for: second, secureInput: false), true, "allowlist cannot exclude inherited app")
  }

  static func legacyAndOrphans() throws {
    var settings = try legacy()
    expect(settings.defaultMode, nil, "legacy JSON missing default mode")
    expect(settings.defaultLocalModel, nil, "legacy JSON missing default model")
    expect(settings.defaultModelOrder, nil, "legacy JSON missing default order")
    profile(settings, first, mode: "off", model: "local", order: jevFirst, providers: [], "legacy unconfigured")
    settings.setGlobalMode("dual")
    settings.setGlobalLocalModel("tev-4b")
    settings.setGlobalOrder(localFirst)
    for (app, mode, model, providers) in [
      ("legacy.off", "off", "local", [String]()),
      ("legacy.tt", "local", "local", ["local"]),
      ("legacy.small", "local", "tev-0.8b", ["tev-0.8b"]),
      ("legacy.large", "local", "tev-4b", ["tev-4b"]),
      ("legacy.cloud", "jev", "local", ["jev"]),
      ("legacy.dual", "dual", "local", ["jev", "local"]),
    ] {
      expect(settings.hasAppOverride(app), true, "legacy app mode owns entire profile")
      profile(settings, app, mode: mode, model: model, order: jevFirst, providers: providers, app)
    }
    settings.appLocalModels = [first: "tev-0.8b", "legacy.small": "local"]
    settings.appModelOrders = [first: jevFirst, "legacy.dual": localFirst]
    expect(settings.hasAppOverride(first), false, "orphan fields are not an override")
    profile(settings, first, mode: "dual", model: "tev-4b", order: localFirst,
            providers: ["tev-4b", "jev"], "orphan fields ignored")
    profile(settings, "legacy.small", mode: "local", model: "local", order: jevFirst,
            providers: ["local"], "explicit model supersedes legacy model ID")
    profile(settings, "legacy.dual", mode: "dual", model: "local", order: localFirst,
            providers: ["local", "jev"], "existing app order preserved")
    settings.appModes[first] = "dual"
    profile(settings, first, mode: "dual", model: "tev-0.8b", order: jevFirst,
            providers: ["jev", "tev-0.8b"], "stored fields become active with app mode")
  }

  static func modesModelsAndOrders() {
    for model in ["local", "tev-0.8b", "tev-4b"] {
      for order in [jevFirst, localFirst] {
        let dual = order == jevFirst ? ["jev", model] : [model, "jev"]
        for (mode, providers) in [("off", [String]()), ("local", [model]), ("jev", ["jev"]), ("dual", dual)] {
          var settings = JevSettings()
          settings.setGlobalMode(mode)
          settings.setGlobalLocalModel(model)
          settings.setGlobalOrder(order)
          expect(settings.globalMode, mode, "valid global mode")
          expect(settings.globalLocalModel, model, "valid global model")
          expect(settings.globalOrder, order, "valid global order")
          let label = "\(mode)/\(model)/\(order)"
          profile(settings, first, mode: mode, model: model, order: order, providers: providers, label + " global")
          settings.setAppMode(mode, for: second)
          settings.setAppLocalModel(model, for: second)
          settings.setAppOrder(order, for: second)
          storedProfile(settings, second, mode: mode, model: model, order: order, label)
          profile(settings, second, mode: mode, model: model, order: order, providers: providers, label + " override")
          for app in [first, second] {
            expect(settings.permitsEnhancement(for: app, secureInput: false), mode != "off", label + " eligibility")
          }
        }
      }
    }
  }

  static func freezeEditAndReset() throws {
    let edits: [(String, (inout JevSettings) -> Void, String, String, [String], [String])] = [
      ("mode", { $0.setAppMode("jev", for: first) }, "jev", "tev-4b", localFirst, ["jev"]),
      ("model", { $0.setAppLocalModel("tev-0.8b", for: first) }, "dual", "tev-0.8b", localFirst, ["tev-0.8b", "jev"]),
      ("order", { $0.setAppOrder(jevFirst, for: first) }, "dual", "tev-4b", jevFirst, ["jev", "tev-4b"]),
    ]
    for (label, edit, mode, model, order, providers) in edits {
      var settings = JevSettings()
      settings.setGlobalMode("dual")
      settings.setGlobalLocalModel("tev-4b")
      settings.setGlobalOrder(localFirst)
      settings.allowedApps = [first, second, first]
      settings.appLocalModels = [first: "local"]
      settings.appModelOrders = [first: jevFirst]
      settings.setAppMode("local", for: second)
      let before = settings
      edit(&settings)
      storedProfile(settings, first, mode: mode, model: model, order: order, label + " snapshots effective global")
      settings.setGlobalMode("off")
      settings.setGlobalLocalModel("local")
      settings.setGlobalOrder(jevFirst)
      profile(settings, first, mode: mode, model: model, order: order, providers: providers, label + " stays frozen")
      settings.setAppMode("dual", for: first)
      storedProfile(settings, first, mode: "dual", model: model, order: order, label + " edit keeps other app fields")
      settings.setAppLocalModel("tev-0.8b", for: first)
      settings.setAppOrder(localFirst, for: first)
      profile(settings, first, mode: "dual", model: "tev-0.8b", order: localFirst,
              providers: ["tev-0.8b", "jev"], label + " independent app edits")
      settings.followDefault(for: first)
      expect(settings.hasAppOverride(first), false, label + " reset clears override")
      expect(settings.appModes[first], nil, label + " reset clears mode")
      expect(settings.appLocalModels?[first], nil, label + " reset clears model")
      expect(settings.appModelOrders?[first], nil, label + " reset clears order")
      expect(settings.allowedApps, [second], label + " reset removes all deprecated allowlist entries")
      profile(settings, first, mode: "off", model: "local", order: jevFirst, providers: [], label + " reset follows current default")
      storedProfile(settings, second, mode: "local", model: "tev-4b", order: localFirst, label + " reset preserves neighbor")
      expect(settings.timeoutOverrides, before.timeoutOverrides, label + " reset preserves timeouts")
      settings.setGlobalMode("jev")
      profile(settings, first, mode: "jev", model: "local", order: jevFirst, providers: ["jev"], label + " reset follows future default")
      let reset = try encoded(settings)
      settings.followDefault(for: first)
      expect(try encoded(settings), reset, label + " repeated reset is idempotent")
    }
    var orphan = JevSettings()
    orphan.appLocalModels = [first: "tev-4b"]
    orphan.appModelOrders = [first: localFirst]
    orphan.allowedApps = [first]
    orphan.followDefault(for: first)
    expect(orphan.appLocalModels?[first], nil, "reset removes orphan model")
    expect(orphan.appModelOrders?[first], nil, "reset removes orphan order")
    expect(orphan.allowedApps, [], "reset removes orphan allowlist entry")
  }

  static func invalidStoredValues() throws {
    var settings = JevSettings()
    for mode in ["", "unknown", "DUAL", "tev-0.8b", "tev-4b"] {
      settings.defaultMode = mode
      expect(settings.globalMode, "off", "unknown global mode \(mode)")
      expect(settings.permitsEnhancement(for: first, secureInput: false), false, "invalid global mode cannot enable")
    }
    settings.defaultMode = "dual"
    for model in ["", "unknown", "jev", "off", "TT"] {
      settings.defaultLocalModel = model
      expect(settings.globalLocalModel, "local", "invalid stored model falls back to TT")
    }
    let badOrders = [[String](), ["local"], ["jev"], ["local", "local"], ["jev", "jev"],
                     ["jev", "tev-4b"], ["jev", "local", "jev"], ["unknown", "local"]]
    for order in badOrders {
      settings.defaultModelOrder = order
      expect(settings.globalOrder, jevFirst, "malformed stored order")
    }
    profile(settings, first, mode: "dual", model: "local", order: jevFirst,
            providers: ["jev", "local"], "bad global fields normalized independently")
    settings.setGlobalLocalModel("tev-4b")
    settings.setGlobalOrder(localFirst)
    settings.appModes = [first: "unknown", second: "dual"]
    settings.appLocalModels = [first: "bad", second: "jev"]
    settings.appModelOrders = [first: ["local"], second: []]
    expect(settings.hasAppOverride(first), true, "invalid stored mode still marks explicit app")
    profile(settings, first, mode: "off", model: "local", order: jevFirst, providers: [], "bad app fields do not inherit active global")
    profile(settings, second, mode: "dual", model: "local", order: jevFirst,
            providers: ["jev", "local"], "bad explicit model and order retain legacy fallbacks")
    let decoded = try JSONDecoder().decode(JevSettings.self, from: encoded(settings))
    profile(decoded, first, mode: "off", model: "local", order: jevFirst, providers: [], "bad stored values after JSON decode")
  }

  static func invalidSetters() throws {
    let badOrders = [[String](), ["local"], ["jev"], ["local", "local"], ["jev", "jev"],
                     ["jev", "tev-4b"], ["jev", "local", "jev"]]
    for configured in [false, true] {
      var settings = JevSettings()
      if configured {
        settings.setGlobalMode("dual")
        settings.setGlobalLocalModel("tev-4b")
        settings.setGlobalOrder(localFirst)
        settings.setAppMode("jev", for: first)
      }
      let before = try encoded(settings)
      for mode in ["", "unknown", "DUAL", "tev-0.8b", "tev-4b"] {
        settings.setGlobalMode(mode)
        expect(try encoded(settings), before, "invalid global mode is ignored")
        for app in [first, second] {
          settings.setAppMode(mode, for: app)
          expect(try encoded(settings), before, "invalid app mode cannot create or change override")
        }
      }
      for model in ["", "unknown", "jev", "off", "TT"] {
        settings.setGlobalLocalModel(model)
        expect(try encoded(settings), before, "invalid global model is ignored")
        for app in [first, second] {
          settings.setAppLocalModel(model, for: app)
          expect(try encoded(settings), before, "invalid app model cannot create or change override")
        }
      }
      for order in badOrders {
        settings.setGlobalOrder(order)
        expect(try encoded(settings), before, "invalid global order is ignored")
        for app in [first, second] {
          settings.setAppOrder(order, for: app)
          expect(try encoded(settings), before, "invalid app order cannot create or change override")
        }
      }
    }
  }

  static func eligibilityGuards() {
    for mode in ["off", "local", "jev", "dual"] {
      var settings = JevSettings()
      settings.setGlobalMode(mode)
      settings.setGlobalLocalModel("tev-4b")
      for app in [first, second, "", own] {
        expect(settings.permitsEnhancement(for: app, secureInput: true), false, "secure input always blocks \(app)/\(mode)")
        expect(settings.permitsEnhancement(for: app, secureInput: false),
               mode != "off" && app != "" && app != own, "inherited eligibility \(app)/\(mode)")
        settings.appModes[app] = mode
      }
      settings.allowedApps = [first, second, "", own]
      for app in [first, second, "", own] {
        expect(settings.permitsEnhancement(for: app, secureInput: true), false, "explicit override never bypasses secure input")
        expect(settings.permitsEnhancement(for: app, secureInput: false),
               mode != "off" && app != "" && app != own, "explicit eligibility \(app)/\(mode)")
      }
    }
  }

  static func persistenceAndTimeouts() throws {
    var settings = try legacy()
    let original = settings
    settings.setGlobalMode("dual")
    settings.setGlobalLocalModel("tev-4b")
    settings.setGlobalOrder(localFirst)
    settings.setAppMode("off", for: first)
    settings.setAppLocalModel("tev-0.8b", for: second)
    settings.setAppOrder(jevFirst, for: second)
    settings.followDefault(for: "legacy.off")
    JevSettings.current = settings
    JevSettings.save()
    let saved = try Data(contentsOf: JevSettings.file)
    let decoded = try JSONDecoder().decode(JevSettings.self, from: saved)
    expect(try encoded(decoded), try encoded(settings), "all fields survive save/decode")
    expect(decoded.timeoutOverrides, original.timeoutOverrides, "profile edits preserve per-model timeouts")
    expect(decoded.projectRoot, original.projectRoot, "profile edits preserve project root")
    expect(decoded.modelPath, original.modelPath, "profile edits preserve model path")
    expect(decoded.vaultRef, original.vaultRef, "profile edits preserve credential reference")
    expect(decoded.localThreshold, original.localThreshold, "profile edits preserve local threshold")
    expect(decoded.jevThreshold, original.jevThreshold, "profile edits preserve cloud threshold")
    for (provider, timeout) in original.timeoutOverrides ?? [:] {
      expect(JevProviders.timeoutMilliseconds(provider: provider, overrides: decoded.timeoutOverrides), timeout,
             "profile persistence leaves \(provider) timeout unchanged")
    }
    var withoutOptionals = try JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as! [String: Any]
    withoutOptionals.removeValue(forKey: "timeoutOverrides")
    let old = try JSONDecoder().decode(JevSettings.self, from: JSONSerialization.data(withJSONObject: withoutOptionals))
    expect(old.timeoutOverrides, nil, "old JSON need not contain timeout overrides")
    expect(JevProviders.timeoutMilliseconds(provider: "local", overrides: old.timeoutOverrides), 600, "legacy TT timeout")
    expect(JevProviders.timeoutMilliseconds(provider: "tev-4b", overrides: old.timeoutOverrides), 2000, "legacy large model timeout")
    for key in ["defaultMode", "defaultLocalModel", "defaultModelOrder"] { withoutOptionals[key] = NSNull() }
    let nulls = try JSONDecoder().decode(JevSettings.self, from: JSONSerialization.data(withJSONObject: withoutOptionals))
    profile(nulls, first, mode: "off", model: "local", order: jevFirst, providers: [], "null optional global fields")
  }

  static func main() throws {
    guard CommandLine.arguments.count == 3 else { fatalError("Use scripts/test_settings_profiles.py") }
    let fixture = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
    // Check the redirection before touching the lazy loader or writing any fixture.
    guard JevSettings.support.standardizedFileURL == fixture,
          JevSettings.file.standardizedFileURL == fixture.appendingPathComponent("settings.json") else {
      fatalError("Settings storage is not isolated")
    }
    let scenario = CommandLine.arguments[2]
    if scenario == "suite" {
      let tests: [(String, () throws -> Void)] = [
        ("defaults and activation", defaultsAndActivation), ("legacy and orphan profiles", legacyAndOrphans),
        ("all modes, models and orders", modesModelsAndOrders), ("freeze, edit and reset", freezeEditAndReset),
        ("invalid stored values", invalidStoredValues), ("invalid setters", invalidSetters),
        ("eligibility guards", eligibilityGuards), ("persistence and timeouts", persistenceAndTimeouts),
      ]
      for (name, run) in tests {
        let before = failures
        do { try run() } catch { failures += 1; print("FAIL: \(name): \(error)") }
        if before == failures { print("PASS: \(name)") }
      }
    } else {
      try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
      switch scenario {
      case "missing":
        guard !FileManager.default.fileExists(atPath: JevSettings.file.path) else { fatalError("Expected fresh fixture") }
      case "legacy": try Data(legacyJSON.utf8).write(to: JevSettings.file)
      case "corrupt": try Data("{broken-json".utf8).write(to: JevSettings.file)
      case "wrong-type":
        var object = try JSONSerialization.jsonObject(with: Data(legacyJSON.utf8)) as! [String: Any]
        object["defaultMode"] = ["dual"]
        try JSONSerialization.data(withJSONObject: object).write(to: JevSettings.file)
      case "reload": break
      default: fatalError("Unknown fixture scenario")
      }
      let settings = JevSettings.current
      if scenario == "reload" {
        profile(settings, "unseen.after.reload", mode: "dual", model: "tev-4b", order: localFirst,
                providers: ["tev-4b", "jev"], "saved global loads in fresh process")
        profile(settings, first, mode: "off", model: "tev-4b", order: localFirst, providers: [], "saved explicit off")
        profile(settings, second, mode: "dual", model: "tev-0.8b", order: jevFirst,
                providers: ["jev", "tev-0.8b"], "saved app profile")
        expect(settings.hasAppOverride("legacy.off"), false, "reset remains reset after reload")
        expect(settings.allowedApps.contains("legacy.off"), false, "deprecated allowlist removal persisted")
        expect(settings.timeoutOverrides, try legacy().timeoutOverrides, "timeouts survive actual load")
      } else {
        profile(settings, first, mode: "off", model: "local", order: jevFirst, providers: [], "\(scenario) safe defaults")
        expect(settings.permitsEnhancement(for: first, secureInput: false), false, "\(scenario) cannot enable unseen app")
        if scenario == "legacy" {
          expect(try encoded(settings), try encoded(legacy()), "real loader decodes full legacy JSON")
          profile(settings, "legacy.large", mode: "local", model: "tev-4b", order: jevFirst,
                  providers: ["tev-4b"], "real loader preserves legacy model")
        } else {
          expect(try encoded(settings), try encoded(JevSettings()), "\(scenario) loads fresh defaults")
        }
      }
    }
    if failures > 0 { print("JevSettingsProfileTests FAIL: \(failures) checks in \(scenario)"); exit(1) }
    print("JevSettingsProfileTests PASS: \(scenario)")
  }
}
