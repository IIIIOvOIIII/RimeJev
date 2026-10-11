import AppKit
import InputMethodKit
import Carbon
import Darwin

struct JevSettings: Codable {
  var mode = "off"
  var allowedApps: [String] = []
  var appModes: [String: String] = [:]
  static let defaultProjectRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/RimeJev").path
  var projectRoot = JevSettings.defaultProjectRoot
  var modelPath = JevSettings.defaultProjectRoot + "/work/models/this-that-model-1.2"
  var vaultRef = "typesafe_api_key"
  var vaultURL: String?
  var vaultTokenHelper: String?
  var localThreshold = 0.65
  var jevThreshold = 0.55
  var tevThreshold: Double?
  var timeoutOverrides: [String: Int64]?
  var appLocalModels: [String: String]?
  var appModelOrders: [String: [String]]?
  var credentialSource: String?
  var credentialRevision: Int64?
  var defaultMode: String?
  var defaultLocalModel: String?
  var defaultModelOrder: [String]?
  private static let modes=["off","jev","local","dual"]
  private static func normalizedMode(_ value:String)->String {
    if JevProviders.local.contains(value) {return "local"}
    return modes.contains(value) ? value : "off"
  }
  private static func validOrder(_ value:[String])->Bool {
    value.count==2 && Set(value)==Set(["jev","local"])
  }
  var globalMode:String {
    guard let value=defaultMode,Self.modes.contains(value) else {return "off"}
    return value
  }
  var globalLocalModel:String {
    guard let value=defaultLocalModel,JevProviders.local.contains(value) else {return "local"}
    return value
  }
  var globalOrder:[String] {
    guard let value=defaultModelOrder,Self.validOrder(value) else {return ["jev","local"]}
    return value
  }
  func hasAppOverride(_ app:String)->Bool {!app.isEmpty && appModes[app] != nil}
  func enhancementMode(for app:String)->String {
    guard !app.isEmpty else {return "off"}
    return appModes[app].map(Self.normalizedMode) ?? globalMode
  }
  func localModel(for app:String)->String {
    guard hasAppOverride(app) else {return globalLocalModel}
    let value=appLocalModels?[app] ?? appModes[app] ?? "local"
    return JevProviders.local.contains(value) ? value : "local"
  }
  func modelOrder(for app:String)->[String] {
    guard hasAppOverride(app) else {return globalOrder}
    let value=appModelOrders?[app] ?? ["jev","local"]
    return Self.validOrder(value) ? value : ["jev","local"]
  }
  func providers(for app:String)->[String] {
    switch enhancementMode(for:app) {
    case "jev":return ["jev"]
    case "local":return [localModel(for:app)]
    case "dual":return modelOrder(for:app).map {$0=="local" ? localModel(for:app) : "jev"}
    default:return []
    }
  }
  func permitsEnhancement(for app:String,secureInput:Bool)->Bool {
    !secureInput && !app.isEmpty && app != "im.lynx.inputmethod.RimeJev" && !providers(for:app).isEmpty
  }
  mutating func setGlobalMode(_ value:String) {
    if Self.modes.contains(value) {defaultMode=value}
  }
  mutating func setGlobalLocalModel(_ value:String) {
    if JevProviders.local.contains(value) {defaultLocalModel=value}
  }
  mutating func setGlobalOrder(_ value:[String]) {
    if Self.validOrder(value) {defaultModelOrder=value}
  }
  private mutating func materializeOverride(for app:String) {
    let selectedMode=enhancementMode(for:app),local=localModel(for:app),order=modelOrder(for:app)
    appModes[app]=selectedMode
    if appLocalModels==nil {appLocalModels=[:]};appLocalModels?[app]=local
    if appModelOrders==nil {appModelOrders=[:]};appModelOrders?[app]=order
    if !allowedApps.contains(app) {allowedApps.append(app)}
  }
  mutating func setAppMode(_ value:String,for app:String) {
    guard !app.isEmpty,Self.modes.contains(value) else {return}
    materializeOverride(for:app);appModes[app]=value;mode=value
  }
  mutating func setAppLocalModel(_ value:String,for app:String) {
    guard !app.isEmpty,JevProviders.local.contains(value) else {return}
    materializeOverride(for:app);appLocalModels?[app]=value
  }
  mutating func setAppOrder(_ value:[String],for app:String) {
    guard !app.isEmpty,Self.validOrder(value) else {return}
    materializeOverride(for:app);appModelOrders?[app]=value
  }
  mutating func followDefault(for app:String) {
    guard !app.isEmpty else {return}
    appModes.removeValue(forKey:app);appLocalModels?.removeValue(forKey:app);appModelOrders?.removeValue(forKey:app)
    allowedApps.removeAll {$0==app}
  }
  var effectiveCredentialSource: String {
    credentialSource ?? ((vaultURL?.isEmpty==false && vaultTokenHelper?.isEmpty==false) ? "vault" : "keychain")
  }
  static let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Rime-Jev")
  static let file = support.appendingPathComponent("settings.json")
  static var current: JevSettings = {
    guard let data = try? Data(contentsOf: file), let value = try? JSONDecoder().decode(JevSettings.self, from: data) else { return JevSettings() }
    return value
  }()
  static func save() {
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    if let data = try? JSONEncoder().encode(current) { try? data.write(to: file, options: .atomic) }
  }
}

final class JevSocketCall: JevCancellable {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() { lock.lock(); cancelled = true; lock.unlock() }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

final class JevRuntimeManager {
  private struct Configuration: Equatable {
    let provider: String
    let projectRoot: String
    let modelPath: String
    let vaultRef: String
    let vaultURL: String?
    let vaultTokenHelper: String?
    let credentialSource: String
    let credentialRevision: Int64
    init(provider: String, settings: JevSettings) {
      self.provider=provider;projectRoot=settings.projectRoot;modelPath=settings.modelPath
      vaultRef=settings.vaultRef;vaultURL=settings.vaultURL;vaultTokenHelper=settings.vaultTokenHelper
      credentialSource=provider=="jev" ? settings.effectiveCredentialSource : "none"
      credentialRevision=provider=="jev" ? settings.credentialRevision ?? 0 : 0
    }
  }
  static let shared = JevRuntimeManager()
  private let queue=DispatchQueue(label:"rime-jev.runtime",qos:.userInitiated)
  private let selectionLock=NSLock()
  private var selection: [String:Configuration]=[:]
  private var generation: UInt64=0
  private var readyProviders=Set<String>()
  private var providerEpochs:[String:UInt64]=[:]
  private let credentialQueue=DispatchQueue(label:"rime-jev.credentials",qos:.utility)
  private let readKey:() throws -> String
  private var pendingCredentials:[String:Configuration]=[:]
  private var processes: [String:Process]=[:]
  private var configurations: [String:Configuration]=[:]
  private var forceReload=Set<String>()
  private var lastLaunch: [String:Date]=[:]
  private var shutdownStarted: [String:TimeInterval]=[:]
  private var resourceBackoff=Date.distantPast
  private var pressureMonitor: DispatchSourceMemoryPressure?
  init(keyReader:@escaping () throws -> String = {try JevKeychain.read()}) {
    readKey=keyReader
    let monitor=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:queue)
    monitor.setEventHandler { [weak self] in self?.handleMemoryPressure() }
    pressureMonitor=monitor;monitor.resume()
  }
  func handleMemoryPressure() {
    queue.async { [self] in
      resourceBackoff=Date().addingTimeInterval(60)
      selectionLock.lock()
      let locals=selection.keys.filter {JevProviders.local.contains($0)}
      for provider in locals {providerEpochs[provider,default:0] &+= 1;readyProviders.remove(provider)}
      let token=generation,desired=selection
      selectionLock.unlock()
      guard !locals.isEmpty else {return}
      forceReload.formUnion(locals);reconcile(desired,token:token)
      queue.asyncAfter(deadline:.now()+60) { [weak self] in
        guard let self,self.isCurrent(token) else {return}
        self.reconcile(desired,token:token)
      }
    }
  }
  func socketPath(_ provider:String)->String {JevSettings.support.appendingPathComponent("\(provider).sock").path}
  private func isCurrent(_ token:UInt64,provider:String?=nil,epoch:UInt64?=nil)->Bool {
    selectionLock.lock();defer {selectionLock.unlock()}
    return token==generation && (provider==nil || (readyProviders.contains(provider!) && (epoch==nil || providerEpochs[provider!,default:0]==epoch!)))
  }
  private func markReady(_ provider:String,token:UInt64) {
    selectionLock.lock();defer {selectionLock.unlock()}
    if token==generation {readyProviders.insert(provider)}
  }
  private func release(_ provider:String)->Bool {
    let path=socketPath(provider), owned=processes[provider]
    _=Self.exchange(path,payload:Data("{\"id\":\"stop\",\"op\":\"shutdown\"}".utf8))
    let deadline=ProcessInfo.processInfo.systemUptime+3
    while FileManager.default.fileExists(atPath:path) || owned?.isRunning==true {
      if ProcessInfo.processInfo.systemUptime>=deadline {return false}
      Thread.sleep(forTimeInterval:0.05)
    }
    processes.removeValue(forKey:provider);configurations.removeValue(forKey:provider)
    lastLaunch.removeValue(forKey:provider)
    forceReload.remove(provider);shutdownStarted.removeValue(forKey:provider)
    return true
  }
  func ensureRunning(_ provider:String) {ensureRunning(providers:[provider])}
  func ensureRunning(providers:[String]) {
    let active=providers.filter {JevProviders.active.contains($0)}
    guard active.filter({JevProviders.local.contains($0)}).count<=1 else {return}
    let settings=JevSettings.current
    let desired=Dictionary(uniqueKeysWithValues:Set(active).map {($0,Configuration(provider:$0,settings:settings))})
    selectionLock.lock()
    if selection != desired {selection=desired;generation &+= 1;readyProviders.removeAll()}
    let token=generation
    selectionLock.unlock()
    queue.async { [self] in reconcile(desired,token:token) }
  }
  private func reconcile(_ desired:[String:Configuration],token:UInt64) {
    guard isCurrent(token) else {return}
    var pending=Set<String>()
    for provider in JevProviders.active {
      guard isCurrent(token) else {return}
      let changed=configurations[provider] != nil && configurations[provider] != desired[provider]
      let unverifiedKey=provider=="jev" && desired[provider]?.credentialSource=="keychain" && configurations[provider]==nil && FileManager.default.fileExists(atPath:socketPath(provider))
      if desired[provider]==nil || changed || unverifiedKey || forceReload.contains(provider) {
        if !release(provider) {
          pending.insert(provider)
          if shutdownStarted[provider]==nil {shutdownStarted[provider]=ProcessInfo.processInfo.systemUptime}
        }
      }
    }
    guard isCurrent(token) else {return}
    // Jev and one local process may coexist. A slow local release does not delay Jev.
    for provider in ["jev"]+JevProviders.local {
      guard isCurrent(token) else {return}
      guard let config=desired[provider], !pending.contains(provider) else {continue}
      if JevProviders.local.contains(provider) && (resourceBackoff>Date() || !pending.isDisjoint(with:JevProviders.local)) {continue}
      if processes[provider]?.isRunning==true && configurations[provider]==config {markReady(provider,token:token);continue}
      if let data=Self.exchange(socketPath(provider),payload:Data("{\"id\":\"reuse\",\"op\":\"health\"}".utf8)),
         let health=try? JSONSerialization.jsonObject(with:data) as? [String:Any],health["provider"] as? String==provider,
         health["error"] as? String != "runtime_closed" {
        configurations[provider]=config;markReady(provider,token:token);continue
      }
      if let date=lastLaunch[provider],Date().timeIntervalSince(date)<3 {continue}
      lastLaunch[provider] = .now
      launch(config,token:token)
    }
    if pending.contains(where:{ProcessInfo.processInfo.systemUptime-(shutdownStarted[$0] ?? 0)<70}) {
      queue.asyncAfter(deadline:.now()+0.25) { [weak self] in self?.reconcile(desired,token:token) }
    }
  }
  private func launch(_ config:Configuration,token:UInt64) {
    guard isCurrent(token) else {return}
    if config.provider=="jev" && config.credentialSource=="keychain" {
      guard pendingCredentials[config.provider] != config else {return}
      pendingCredentials[config.provider]=config
      credentialQueue.async { [self] in
        var credential:Data?
        if let key=try? readKey(),!key.isEmpty,let payload=try? JSONSerialization.data(withJSONObject:["api_key":key]),payload.count<=4096 {credential=payload}
        let payload=credential
        queue.async { [self] in
          guard pendingCredentials[config.provider]==config else {return}
          pendingCredentials.removeValue(forKey:config.provider)
          selectionLock.lock();let current=selection[config.provider]==config,latest=generation;selectionLock.unlock()
          guard current,let payload else {return}
          launchProcess(config,token:latest,credential:payload)
        }
      }
      return
    }
    launchProcess(config,token:token,credential:nil)
  }
  private func launchProcess(_ config:Configuration,token:UInt64,credential:Data?) {
    guard isCurrent(token) else {return}
    let provider=config.provider,task=Process()
    task.executableURL=URL(fileURLWithPath:config.projectRoot+"/.venv/bin/python")
    task.currentDirectoryURL=URL(fileURLWithPath:config.projectRoot)
    var arguments=["-m","rime_jev.runtime","--socket",socketPath(provider),"--provider",provider,
                   "--model-path",config.modelPath,"--vault-ref",config.vaultRef]
    var pipe:Pipe?
    if credential != nil {pipe=Pipe();task.standardInput=pipe;arguments.append("--credential-stdin")}
    else {task.standardInput=FileHandle.nullDevice}
    task.arguments=arguments
    var env=ProcessInfo.processInfo.environment
    env["PYTHONPATH"]=config.projectRoot+"/src";env["RIME_JEV_PROJECT_ROOT"]=config.projectRoot
    env["HF_HUB_OFFLINE"]="1";env["TOKENIZERS_PARALLELISM"]="false"
    if let url=config.vaultURL,!url.isEmpty {env["RIME_JEV_VAULT_URL"]=url}
    if let helper=config.vaultTokenHelper,!helper.isEmpty {env["RIME_JEV_VAULT_TOKEN_HELPER"]=helper}
    task.environment=env;task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
    guard isCurrent(token) else {return}
    do {
      try task.run()
      processes[provider]=task;configurations[provider]=config
      if let pipe,let credential {
        _=fcntl(pipe.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1)
        try pipe.fileHandleForWriting.write(contentsOf:credential);try? pipe.fileHandleForWriting.close()
      }
      markReady(provider,token:token)
    } catch {try? pipe?.fileHandleForWriting.close()}
  }
  func stop() {ensureRunning(providers:[])}
  func reloadSelected(_ provider:String) {
    selectionLock.lock()
    guard selection[provider] != nil else {selectionLock.unlock();return}
    generation &+= 1;readyProviders.removeAll()
    let token=generation,desired=selection
    selectionLock.unlock()
    queue.async { [self] in
      guard isCurrent(token) else {return}
      forceReload.insert(provider);lastLaunch.removeValue(forKey:provider)
      reconcile(desired,token:token)
    }
  }
  func send(_ request:JevDecisionRequest,provider:String,completion:@escaping(JevDecisionResponse)->Void)->JevCancellable {
    let call=JevSocketCall(),path=socketPath(provider)
    selectionLock.lock();let token=generation,selected=selection[provider] != nil,epoch=providerEpochs[provider,default:0];selectionLock.unlock()
    DispatchQueue.global(qos:.userInitiated).async { [self] in
      var response=JevDecisionResponse(id:request.id,status:"unavailable",provider:provider,probabilities:[:])
      if selected,isCurrent(token,provider:provider,epoch:epoch),!call.isCancelled,
         let payload=try? request.jsonData(),let data=Self.exchange(path,payload:payload,timeoutMilliseconds:request.maxAgeMilliseconds),
         let value=try? JSONDecoder().decode(JevDecisionResponse.self,from:data) {response=value}
      let delivered=response
      DispatchQueue.main.async {if !call.isCancelled,self.isCurrent(token,provider:provider,epoch:epoch) {completion(delivered)}}
    }
    return call
  }
  static func exchange(_ path: String, payload: Data, timeoutMilliseconds: Int64 = 1500, onUnavailable: (() -> Void)? = nil) -> Data? {
    guard payload.count < 131072 else { return nil }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    let timeoutMilliseconds=max(1,min(timeoutMilliseconds,10000))
    var timeout = timeval(tv_sec:Int(timeoutMilliseconds/1000),tv_usec:Int32(timeoutMilliseconds%1000)*1000), noSignal: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8) + [0]
    guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
    let connected = withUnsafePointer(to: &address) { p in
      p.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard connected == 0 else {
      if errno==ENOENT || errno==ECONNREFUSED {onUnavailable?()}
      return nil
    }
    var request = payload; request.append(10)
    var sent = 0
    while sent < request.count {
      let n = request.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: sent), request.count-sent) }
      guard n > 0 else { return nil }; sent += n
    }
    var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
    while result.count <= 131072 {
      let n = Darwin.read(fd, &buffer, buffer.count)
      guard n > 0 else { return nil }
      result.append(contentsOf: buffer[..<n])
      if let end = result.firstIndex(of: 10) { return result.prefix(upTo: end) }
    }
    return nil
  }
}

final class JevInputAdapter {
  private struct WeakAdapter { weak var value: JevInputAdapter? }
  private static var instances: [WeakAdapter] = []
  static func invalidateAll() {
    instances.removeAll { $0.value == nil }
    for instance in instances { instance.value?.invalidate(clearContext: true) }
  }
  static func reloadPolicies() {
    instances.removeAll { $0.value == nil }
    for instance in instances {
      instance.value?.invalidate(clearContext:true)
      instance.value?.rebuildCoordinator()
    }
  }
  weak var controller: SquirrelInputController?
  private var epoch: UInt64 = 0
  private var focusGeneration: UInt64 = 0
  private var schema = ""
  private var sortingLocked = false, committingLocked = false
  private var input = "", identity = ""
  private var recentContext = JevCommittedContext()
  private var context: String { recentContext.text }
  private var expectedEnd: Int? { recentContext.expectedEnd }
  private var clientIdentity: String? { recentContext.clientIdentity }
  private var pendingHostCommit = false
  private var confirmedPrefix = "", requestContext = ""
  private var baseline: [JevCandidate] = []
  private var visible: [String] = []
  private var visiblePage = 0
  private var visibleKeys: [String?] = []
  private var badges: [String:String] = [:]
  private var modelChoices: [String:JevCandidate] = [:]
  private struct CachedChoice {
    let recommendations: [JevRecommendation]
    let signature: String
    let count: Int
    let created: Date
  }
  private var cache: [String: CachedChoice] = [:]
  private var cacheKey = ""
  private var requestCacheKey = ""
  private var pendingCache: CachedChoice?
  private var preparedSeed = "", samplingSeed = ""
  private var samplingScanned = 0, samplingBatches = 0
  private var applying = false
  private var commits = 0, proxyChanges = 0, contextClears = 0, activations = 0, requests = 0, decisions = 0
  private var lastReason = "initial", responseStatus = "none"
  private var lastContinuityFailure = "none"
  var diagnostics: [String: Any] {
    ["commits":commits,"proxy_changes":proxyChanges,"context_clears":contextClears,"activations":activations,
     "requests":requests,"decisions":decisions,"reason":lastReason,"response_status":responseStatus,
     "context_check":recentContext.lastCheckReason,"last_context_failure":lastContinuityFailure,"decision_outcome":coordinator.lastOutcome,
     "sampling_scanned":samplingScanned,"sampling_batches":samplingBatches,
     "context_length":context.count,"confirmed_prefix_length":confirmedPrefix.count,"candidate_count":baseline.count]
  }
  func noteProxyChange() { proxyChanges += 1 }
  private var coordinator: JevDecisionCoordinator!
  private var modelCoordinators: [String:JevDecisionCoordinator] = [:]
  init(controller: SquirrelInputController) {
    self.controller = controller
    rebuildCoordinator()
    Self.instances.append(WeakAdapter(value: self))
  }
  var enhancementMode: String {JevSettings.current.enhancementMode(for:controller?.currentApp ?? "")}
  var activeProviders: [String] {JevSettings.current.providers(for:controller?.currentApp ?? "")}
  var provider: String {enhancementMode=="dual" ? "dual" : activeProviders.first ?? "off"}
  var eligible: Bool {
    guard let controller else {return false}
    return JevSettings.current.permitsEnhancement(for:controller.currentApp,secureInput:IsSecureEventInputEnabled())
  }
  private func rebuildCoordinator() {
    let settings=JevSettings.current
    modelCoordinators.removeAll()
    for model in activeProviders.isEmpty ? ["local"] : activeProviders {
      let value=JevDecisionCoordinator(configuration:JevCoordinatorConfiguration(policy:.inputMethod(
        localProbability:settings.localThreshold,jevProbability:settings.jevThreshold,
        tevProbability:settings.tevThreshold ?? 0.65),providerTimeouts:JevProviders.timeouts(overrides:settings.timeoutOverrides)),transport:{ [weak self] request,completion in
          guard let self else {return JevSocketCall()}
          self.verifyContinuity()
          guard self.eligible,self.activeProviders.contains(request.provider),
                String((self.context+self.confirmedPrefix).suffix(80))==request.state.context else {
            self.lastReason="context_changed_before_request"
            completion(JevDecisionResponse(id:request.id,status:"unavailable",provider:request.provider))
            return JevSocketCall()
          }
          self.requests += 1
          return JevRuntimeManager.shared.send(request,provider:request.provider) { [weak self] response in
            self?.responseStatus=response.status;completion(response)
          }
        },onDecision:{ [weak self] decision in self?.apply(decision) })
      modelCoordinators[model]=value
    }
    coordinator=modelCoordinators[activeProviders.first ?? "local"]
  }
  func property(_ name: String) -> String {
    guard let c = controller, c.session != 0 else { return "" }
    var buffer = [CChar](repeating: 0, count: 65536)
    guard c.rimeAPI.get_property(c.session, name, &buffer, buffer.count) else { return "" }
    return String(cString: buffer)
  }
  private func set(_ name: String, _ value: String) {
    guard let c = controller, c.session != 0 else { return }
    c.rimeAPI.set_property(c.session, name, value)
  }
  func invalidate(clearContext: Bool = false) {
    modelCoordinators.values.forEach {$0.invalidate()}; epoch &+= 1
    preparedSeed="";samplingSeed=""
    identity = ""; input = ""; confirmedPrefix=""; requestContext=""; baseline = []; badges.removeAll(); modelChoices.removeAll()
    sortingLocked = false; committingLocked = false
    set("_jev_epoch", String(epoch)); set("_jev_result", "")
    pendingCache = nil
    if clearContext { contextClears += 1; recentContext.reset(); pendingHostCommit=false; cache.removeAll(); focusGeneration &+= 1 }
  }
  func activate() {
    activations += 1;invalidate(clearContext:true);rebuildCoordinator()
    JevRuntimeManager.shared.ensureRunning(providers:eligible ? activeProviders : [])
  }
  private func saveSelection() {
    JevSettings.save();Self.reloadPolicies()
    JevRuntimeManager.shared.ensureRunning(providers:eligible ? activeProviders : [])
    controller?.rimeUpdate()
  }
  func chooseMode(_ mode:String) {
    guard let app=controller?.currentApp else {return}
    JevSettings.current.setAppMode(mode,for:app);saveSelection()
  }
  func chooseLocalModel(_ model:String) {
    guard let app=controller?.currentApp else {return}
    JevSettings.current.setAppLocalModel(model,for:app);saveSelection()
  }
  func chooseOrder(_ order:[String]) {
    guard let app=controller?.currentApp else {return}
    JevSettings.current.setAppOrder(order,for:app);saveSelection()
  }
  func followDefault() {
    guard let app=controller?.currentApp else {return}
    JevSettings.current.followDefault(for:app);saveSelection()
  }
  func sortLock() {sortingLocked=true;modelCoordinators.values.forEach {$0.lockSorting()}}
  func commitLock() {sortingLocked=true;committingLocked=true;modelCoordinators.values.forEach {$0.lockCommit()}}
  func beforeEvent(_ event: NSEvent) {
    guard event.type == .keyDown else { return }
    if event.modifierFlags.contains(.command) { invalidate(clearContext: true); return }
    verifyContinuity(allowPendingCommit:true)
    recentContext.noteActivity(now: ProcessInfo.processInfo.systemUptime)
    let chars = event.charactersIgnoringModifiers ?? ""
    if [36,48,49,76].contains(Int(event.keyCode)) || chars.rangeOfCharacter(from: .decimalDigits) != nil {
      commitLock()
    } else if [125,126,116,121].contains(Int(event.keyCode)) || chars == "," || chars == "." {
      sortLock()
    } else {
      let clear = [123,124,115,119,53].contains(Int(event.keyCode))
      invalidate(clearContext: clear)
    }
  }
  private func cursorBase(_ client: IMKTextInput) -> Int? {
    let marked = client.markedRange(), selected = client.selectedRange()
    let base = marked.location != NSNotFound && marked.length > 0 ? marked.location : selected.location
    return base == NSNotFound ? nil : base
  }
  private func verifyContinuity(allowPendingCommit: Bool = false) {
    guard !context.isEmpty else { return }
    let client=controller?.client
    if allowPendingCommit && pendingHostCommit && recentContext.mayDeferHostCheck(now:ProcessInfo.processInfo.systemUptime) {
      let id=client.map {String(describing:ObjectIdentifier($0 as AnyObject))}
      _ = recentContext.verify(client:id,base:nil,preceding:nil,now:ProcessInfo.processInfo.systemUptime,deferredCommit:true)
      return
    }
    pendingHostCommit=false
    let id=client.map { String(describing:ObjectIdentifier($0 as AnyObject)) }
    let base=client.flatMap { cursorBase($0) }
    let preceding: String?
    if let client, id==clientIdentity, let expectedEnd, base==expectedEnd, expectedEnd >= context.utf16.count {
      preceding=client.attributedSubstring(from:NSRange(location:expectedEnd-context.utf16.count,length:context.utf16.count))?.string
    } else { preceding=nil }
    if !recentContext.verify(client:id,base:base,preceding:preceding,now:ProcessInfo.processInfo.systemUptime) {
      lastContinuityFailure=recentContext.lastCheckReason
    }
  }
  func willCommit(_ text: String) {
    commits += 1
    guard let client=controller?.client, let base=cursorBase(client) else {invalidate(clearContext:true);return}
    recentContext.commit(text,at:base,client:String(describing:ObjectIdentifier(client as AnyObject)),now:ProcessInfo.processInfo.systemUptime)
    pendingHostCommit=true
    modelCoordinators.values.forEach {$0.invalidate()};badges.removeAll();modelChoices.removeAll()
  }
  func beforeMenu(schema: String) {
    if !self.schema.isEmpty && self.schema != schema { invalidate(clearContext: true) }
    self.schema=schema
    // insertText may update a browser's selection on its next event-loop turn.
    // The same commit refresh must not discard the newly committed context.
    verifyContinuity(allowPendingCommit:true)
    guard !applying, !sortingLocked, !committingLocked, eligible, activeProviders.count==1, !context.isEmpty, recentContext.lastCheckReason=="verified", confirmedPrefix.isEmpty, let c=controller,
          let pointer=c.rimeAPI.get_input(c.session) else { return }
    let raw=String(cString:pointer)
    guard !raw.isEmpty else { return }
    cacheKey=[schema,c.currentApp,String(c.session),String(focusGeneration),String(describing:clientIdentity),raw,context,activeProviders.joined(separator:",")].joined(separator:"\u{1f}")
    guard property("_jev_result").isEmpty, let entry=cache[cacheKey], Date().timeIntervalSince(entry.created)<60 else { return }
    pendingCache=entry
    let wire=placementWire(entry,raw:raw)
    set("_jev_result",wire)
  }
  func afterRender(candidates: [String], page: Int, prefix: String, displayCode: String) {
    lastReason="render"
    let previousPrefix=confirmedPrefix
    confirmedPrefix = prefix.unicodeScalars.allSatisfy { (0x3400...0x9fff).contains(Int($0.value)) } ? prefix : ""
    if !confirmedPrefix.isEmpty && confirmedPrefix != previousPrefix {
      sortingLocked=false;committingLocked=false
    }
    visible = candidates; visiblePage = page
    guard !applying, let c = controller, eligible, !c.rimeAPI.get_option(c.session,"ascii_mode") else { lastReason="disabled_or_applying";return }
    let raw = c.rimeAPI.get_input(c.session).map { String(cString:$0) } ?? ""
    guard !raw.isEmpty else { modelCoordinators.values.forEach {$0.invalidate()}; identity=""; input=""; badges.removeAll();modelChoices.removeAll(); return }
    if !property("_jev_applied").isEmpty {return}
    guard let data = property("_jev_snapshot").data(using:.utf8),
          let snap = try? JSONSerialization.jsonObject(with:data) as? [String:Any], snap["input"] as? String == raw,
          snap["protected"] as? Bool == false, let rows = snap["candidates"] as? [[String:String]] else { lastReason="snapshot_unavailable_or_protected";return }
    let pinyin=snap["pinyin"] as? String ?? raw
    let limit=JevCandidateWindow.limit(pinyin:pinyin,displayCode:displayCode,provider:activeProviders.first(where:JevProviders.isTev) ?? activeProviders.first ?? "local")
    let list=decodeRows(rows,limit:limit)
    let modelContext=String((context+confirmedPrefix).suffix(80))
    guard list.count >= 2, page == 0, list.first?.text == candidates.first, !modelContext.isEmpty else { lastReason=modelContext.isEmpty ? "no_context" : "candidate_mismatch";return }
    guard !sortingLocked, !committingLocked else {return}
    let seed = "\(c.session)|\(epoch)|\(focusGeneration)|\(schema)|\(c.currentApp)|\(String(describing:clientIdentity))|\(raw)|\(pinyin)|\(limit)|\(activeProviders.joined(separator:","))|\(modelContext)"
    guard preparedSeed != seed else {return}
    preparedSeed=seed;samplingSeed=seed
    samplingScanned=0;samplingBatches=0
    let startedAt=coordinator.clock.nowMilliseconds()
    let firstKeys=Array(list.prefix(8)).map(\.key)
    if limit==8 || list.count>=limit {
      submitSample(seed:seed,raw:raw,pinyin:pinyin,modelContext:modelContext,list:list,abbreviated:limit>8,startedAt:startedAt)
    } else {
      lastReason="sampling"
      DispatchQueue.main.async { [weak self] in
        self?.sampleBatch(seed:seed,raw:raw,modelContext:modelContext,firstKeys:firstKeys,limit:limit,offset:0,startedAt:startedAt)
      }
    }
  }
  private func decodeRows(_ rows:[[String:String]], limit:Int) -> [JevCandidate] {
    Array(rows.prefix(limit)).compactMap { row in
      guard let id=row["id"],let text=row["text"],let key=row["key"] else {return nil}
      return JevCandidate(id:id,text:text,key:key)
    }
  }
  private func sampleBatch(seed:String,raw:String,modelContext:String,firstKeys:[String],limit:Int,offset:Int,startedAt:Int64) {
    guard samplingSeed==seed, preparedSeed==seed, !sortingLocked, !committingLocked, visiblePage==0,
          let c=controller, eligible, c.rimeAPI.find_session(c.session),
          (c.rimeAPI.get_input(c.session).map{String(cString:$0)} ?? "")==raw else {return}
    var iterator=RimeCandidateListIterator()
    var taken=0, exhausted=false
    let sliceStart=coordinator.clock.nowMilliseconds()
    if let begin=c.rimeAPI.candidate_list_from_index, begin(c.session,&iterator,Int32(offset)) {
      while taken<8 && offset+taken<64 {
        guard c.rimeAPI.candidate_list_next(&iterator) else {exhausted=true;break}
        taken += 1
        if coordinator.clock.nowMilliseconds()-sliceStart>=2 {break}
      }
      c.rimeAPI.candidate_list_end(&iterator)
    } else {exhausted=true}
    samplingScanned=offset+taken;samplingBatches += 1
    guard let data=property("_jev_snapshot").data(using:.utf8),
          let snap=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
          snap["input"] as? String==raw, snap["protected"] as? Bool==false,
          let rows=snap["candidates"] as? [[String:String]] else {lastReason="sampling_unavailable_or_protected";return}
    let list=decodeRows(rows,limit:limit)
    guard Array(list.prefix(firstKeys.count)).map(\.key)==firstKeys else {lastReason="sampling_changed";return}
    if exhausted || taken==0 || list.count>=limit || samplingScanned>=64 {
      submitSample(seed:seed,raw:raw,pinyin:snap["pinyin"] as? String ?? raw,modelContext:modelContext,list:list,abbreviated:limit>8,startedAt:startedAt)
    } else {
      let nextOffset=offset+taken
      DispatchQueue.main.async { [weak self] in
        self?.sampleBatch(seed:seed,raw:raw,modelContext:modelContext,firstKeys:firstKeys,limit:limit,offset:nextOffset,startedAt:startedAt)
      }
    }
  }
  private func submitSample(seed:String,raw:String,pinyin:String,modelContext:String,list:[JevCandidate],abbreviated:Bool,startedAt:Int64) {
    guard samplingSeed==seed, !sortingLocked, !committingLocked, list.count>=2 else {return}
    samplingSeed=""
    identity=seed+"|"+list.map(\.key).joined(separator:",")
    input=raw;baseline=list;requestCacheKey=cacheKey;requestContext=modelContext
    set("_jev_epoch",String(epoch))
    modelChoices.removeAll()
    JevRuntimeManager.shared.ensureRunning(providers:activeProviders)
    for model in activeProviders {
      modelCoordinators[model]?.onNewSnapshot(JevInputSnapshot(identity:identity,pinyin:pinyin,context:modelContext,candidates:list,provider:model,abbreviated:abbreviated),startedAtMilliseconds:startedAt)
    }
    lastReason="scheduled"
  }
  private func placementWire(_ entry:CachedChoice,raw:String)->String {
    ["v2",String(epoch),Self.hex(raw),entry.recommendations.map {$0.candidate.key}.joined(separator:","),String(entry.count),entry.signature,
     entry.recommendations.map {$0.providers.joined(separator:"+")}.joined(separator:",")].joined(separator:"|")
  }
  private func installBadges(_ entry:CachedChoice) {
    badges=Dictionary(uniqueKeysWithValues:entry.recommendations.map { row in
      (row.candidate.key,row.providers.compactMap {JevBadge.label(provider:$0,matchesFirst:false)}.joined(separator:" "))
    })
  }
  private func apply(_ decision:JevDecision) {
    decisions += 1;lastReason="decision"
    guard let c=controller,eligible,!applying,!committingLocked,!sortingLocked,c.rimeAPI.find_session(c.session),
          modelCoordinators[decision.provider]?.currentIdentity==identity,activeProviders.contains(decision.provider),
          (c.rimeAPI.get_input(c.session).map {String(cString:$0)} ?? "")==input,baseline.contains(decision.candidate) else {return}
    verifyContinuity()
    guard !requestContext.isEmpty,String((context+confirmedPrefix).suffix(80))==requestContext else {return}
    guard decision.action == .promote else {lastReason="late_no_stable_space";return}
    modelChoices[decision.provider]=decision.candidate
    let entries=JevCandidatePlan.entries(baseline:baseline,choices:modelChoices,priority:activeProviders)
    guard !entries.isEmpty else {return}
    let entry=CachedChoice(recommendations:entries,signature:Self.hex(baseline.map(\.key).joined(separator:"\n")),count:baseline.count,created:.now)
    let wire=placementWire(entry,raw:input)
    applying=true;set("_jev_result",wire)
    var rebuilt=RimeContext_stdbool.rimeStructInit()
    if c.rimeAPI.get_context(c.session,&rebuilt) {_ = c.rimeAPI.free_context(&rebuilt)}
    if property("_jev_applied")==wire {
      installBadges(entry)
      if cache.count>=128,let oldest=cache.min(by:{$0.value.created<$1.value.created})?.key {cache.removeValue(forKey:oldest)}
      if confirmedPrefix.isEmpty {cache[requestCacheKey]=entry}
    } else {set("_jev_result","");badges.removeAll()}
    c.rimeUpdate();applying=false
  }
  func bindVisible(_ words: [String], page: Int) {
    visible=words;visiblePage=page
    let data=property("_jev_snapshot").data(using:.utf8)
    let snap=data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
    let rows=snap?["candidates"] as? [[String:String]] ?? []
    visibleKeys=words.map { word in
      let matches=rows.filter{$0["text"]==word}
      return words.filter{$0==word}.count==1 && matches.count==1 ? matches[0]["key"] : nil
    }
  }
  func badge(for word:String,index:Int)->NSAttributedString? {
    guard eligible else {return nil}
    if let entry=pendingCache,property("_jev_applied")==property("_jev_result"), !property("_jev_applied").isEmpty {
      installBadges(entry);pendingCache=nil
    }
    guard index<visibleKeys.count,let key=visibleKeys[index],let label=badges[key] else {return nil}
    return JevBadge.render(label)
  }
  static func hex(_ value:String)->String { value.utf8.map{String(format:"%02x",$0)}.joined() }
}

final class JevPreferences: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
  private static var retained:JevPreferences?
  private weak var inputOwner:SquirrelInputController?
  private let mode=NSPopUpButton(), localModel=NSPopUpButton(), timeoutModel=NSPopUpButton()
  private let scope=NSPopUpButton(), follow=NSButton()
  private let scopeHint=NSTextField(wrappingLabelWithString:"")
  private let status=NSTextField(wrappingLabelWithString:""), model=NSTextField(wrappingLabelWithString:"")
  private let install=NSButton(),up=NSButton(),down=NSButton()
  private let orderTable=NSTableView()
  private let localRow=NSStackView(),orderRow=NSStackView()
  private let timeoutField=NSTextField(string:"0.6"), timeoutSave=NSButton(), timeoutReset=NSButton()
  private let timeoutHint=NSTextField(wrappingLabelWithString:"0.3–10 秒；按模型保存，各应用共用。从停止键入起计时，继续输入或选词会作废旧结果。")
  private let keyField=NSSecureTextField(),keySave=NSButton(),keyDelete=NSButton()
  private let keyHint=NSTextField(wrappingLabelWithString:"")
  private let progress=NSProgressIndicator()
  private var timer:Timer?,download:Process?
  private var statusGeneration:UInt64=0
  private var keyBusy=false
  private var app:String {inputOwner?.currentApp ?? ""}
  private var providers:[String] {inputOwner?.jev.activeProviders ?? []}
  private var editingDefaults:Bool {scope.indexOfSelectedItem==0}
  private var selectedMode:String {editingDefaults ? JevSettings.current.globalMode : JevSettings.current.enhancementMode(for:app)}
  private var selectedLocalModel:String {editingDefaults ? JevSettings.current.globalLocalModel : JevSettings.current.localModel(for:app)}
  private var selectedOrder:[String] {editingDefaults ? JevSettings.current.globalOrder : JevSettings.current.modelOrder(for:app)}
  private var displayedProviders:[String] {
    switch selectedMode {
    case "jev":return ["jev"]
    case "local":return [selectedLocalModel]
    case "dual":return selectedOrder.map {$0=="local" ? selectedLocalModel : "jev"}
    default:return []
    }
  }
  private var selectedTimeoutProvider:String {JevProviders.active.indices.contains(timeoutModel.indexOfSelectedItem) ? JevProviders.active[timeoutModel.indexOfSelectedItem] : "jev"}
  static func show(for inputOwner:SquirrelInputController) {
    inputOwner.jev.invalidate(clearContext:true)
    if retained==nil {retained=JevPreferences(inputOwner:inputOwner)}
    retained?.inputOwner=inputOwner;retained?.scope.selectItem(at:0);retained?.syncSelection();retained?.keyField.stringValue=""
    retained?.showWindow(nil);NSApp.activate(ignoringOtherApps:true)
    retained?.refreshKeyStatus();retained?.refreshStatus()
  }
  init(inputOwner:SquirrelInputController) {
    self.inputOwner=inputOwner
    let window=NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:720),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
    window.title="鼠须管 Jev 设置"
    super.init(window:window)
    let content=NSStackView();content.orientation = .vertical;content.alignment = .leading;content.spacing=12
    content.translatesAutoresizingMaskIntoConstraints=false;window.contentView?.addSubview(content)
    if let view=window.contentView {NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),content.topAnchor.constraint(equalTo:view.topAnchor,constant:24)])}
    func button(_ b:NSButton,_ title:String,_ action:Selector) {b.title=title;b.target=self;b.action=action;b.bezelStyle = .rounded}
    func row(_ views:[NSView])->NSStackView {let r=NSStackView(views:views);r.orientation = .horizontal;r.spacing=8;return r}
    let title=NSTextField(labelWithString:"语境选词");title.font = .boldSystemFont(ofSize:20);content.addArrangedSubview(title)
    scope.addItems(withTitles:["所有应用默认设置","当前应用单独设置"])
    scope.target=self;scope.action=#selector(scopeChanged)
    button(follow,"跟随默认",#selector(followDefaults))
    content.addArrangedSubview(row([NSTextField(labelWithString:"设置范围"),scope,follow]));content.addArrangedSubview(scopeHint)
    mode.addItems(withTitles:["关闭增强","使用云端 Jev 模型","使用本地模型","使用云端＋本地模型"])
    mode.target=self;mode.action=#selector(modeChanged);content.addArrangedSubview(mode)
    let explanation=NSTextField(wrappingLabelWithString:"可统一设置模式、本地模型和推荐顺序，也可为当前应用单独覆盖。云端模式会发送有限上下文与候选；无结果时保留万象候选。")
    content.addArrangedSubview(explanation)
    localModel.addItems(withTitles:JevProviders.local.map(JevProviders.name));localModel.target=self;localModel.action=#selector(localChanged)
    localRow.orientation = .horizontal;localRow.spacing=8;localRow.addArrangedSubview(NSTextField(labelWithString:"本地模型"));localRow.addArrangedSubview(localModel);content.addArrangedSubview(localRow)
    let column=NSTableColumn(identifier:NSUserInterfaceItemIdentifier("model"));column.width=395;column.isEditable=false
    orderTable.addTableColumn(column);orderTable.headerView=nil;orderTable.rowHeight=26
    orderTable.dataSource=self;orderTable.delegate=self;orderTable.allowsMultipleSelection=false
    orderTable.setAccessibilityLabel("模型推荐优先级")
    let scroll=NSScrollView();scroll.borderType = .bezelBorder;scroll.documentView=orderTable;scroll.hasVerticalScroller=false
    scroll.widthAnchor.constraint(equalToConstant:400).isActive=true;scroll.heightAnchor.constraint(equalToConstant:58).isActive=true
    button(up,"上移 ↑",#selector(orderUp));button(down,"下移 ↓",#selector(orderDown))
    let arrows=NSStackView(views:[up,down]);arrows.orientation = .vertical;arrows.spacing=4
    orderRow.orientation = .horizontal;orderRow.spacing=12;orderRow.addArrangedSubview(scroll);orderRow.addArrangedSubview(arrows);content.addArrangedSubview(orderRow)
    content.addArrangedSubview(model)
    timeoutModel.addItems(withTitles:JevProviders.active.map(JevProviders.name));timeoutModel.target=self;timeoutModel.action=#selector(timeoutModelChanged)
    timeoutField.widthAnchor.constraint(equalToConstant:64).isActive=true;timeoutField.target=self;timeoutField.action=#selector(saveTimeout)
    button(timeoutSave,"保存",#selector(saveTimeout));button(timeoutReset,"恢复默认",#selector(resetTimeout))
    content.addArrangedSubview(row([NSTextField(labelWithString:"超时"),timeoutModel,timeoutField,NSTextField(labelWithString:"秒"),timeoutSave,timeoutReset]));content.addArrangedSubview(timeoutHint)
    let keyTitle=NSTextField(labelWithString:"Jev API 密钥");keyTitle.font = .boldSystemFont(ofSize:13);content.addArrangedSubview(keyTitle)
    keyField.placeholderString="输入 API 密钥";keyField.widthAnchor.constraint(equalToConstant:330).isActive=true
    keyField.setAccessibilityLabel("Jev API 密钥（隐藏输入）")
    button(keySave,"保存密钥",#selector(saveKey));button(keyDelete,"删除密钥",#selector(deleteKey))
    content.addArrangedSubview(row([keyField,keySave,keyDelete]));content.addArrangedSubview(keyHint)
    button(install,"下载或校验所选本地模型",#selector(installModel));content.addArrangedSubview(install)
    progress.style = .bar;progress.isIndeterminate=true;progress.isDisplayedWhenStopped=false
    progress.widthAnchor.constraint(equalToConstant:510).isActive=true;content.addArrangedSubview(progress);content.addArrangedSubview(status)
    for label in [explanation,model,status,timeoutHint,keyHint,scopeHint] {label.widthAnchor.constraint(lessThanOrEqualToConstant:552).isActive=true}
    window.center();syncSelection()
    timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.refreshStatus() }
  }
  required init?(coder:NSCoder) {fatalError("init(coder:) is not supported")}
  private func syncSelection() {
    let selected=selectedMode
    follow.isHidden=editingDefaults;follow.isEnabled=JevSettings.current.hasAppOverride(app)
    let appName=NSRunningApplication.runningApplications(withBundleIdentifier:app).first?.localizedName ?? "当前应用"
    if editingDefaults {
      scopeHint.stringValue="未单独设置的应用自动使用此默认配置。已有应用的单独设置优先。"
    } else {
      scopeHint.stringValue=appName+(JevSettings.current.hasAppOverride(app) ? "：使用单独设置；可恢复跟随默认。" : "：跟随所有应用默认；修改下方选项将建立单独设置。")
    }
    mode.selectItem(at:["off","jev","local","dual"].firstIndex(of:selected) ?? 0)
    localModel.selectItem(at:JevProviders.local.firstIndex(of:selectedLocalModel) ?? 0)
    localRow.isHidden = !["local","dual"].contains(selected);orderRow.isHidden=selected != "dual"
    let current=displayedProviders.first ?? "jev"
    timeoutModel.selectItem(at:JevProviders.active.firstIndex(of:current) ?? 0);timeoutModelChanged()
    orderTable.reloadData();orderTable.selectRowIndexes(IndexSet(integer:0),byExtendingSelection:false);updateArrows()
  }
  func numberOfRows(in tableView:NSTableView)->Int {2}
  func tableView(_ tableView:NSTableView,objectValueFor tableColumn:NSTableColumn?,row:Int)->Any? {
    let values=selectedOrder
    guard values.indices.contains(row) else {return nil}
    let provider=values[row]=="local" ? selectedLocalModel : "jev"
    return "\(row+1).  "+JevProviders.name(provider)
  }
  func tableViewSelectionDidChange(_ notification:Notification) {updateArrows()}
  private func updateArrows() {up.isEnabled=orderTable.selectedRow==1;down.isEnabled=orderTable.selectedRow==0}
  private func move(_ delta:Int) {
    let index=orderTable.selectedRow,next=index+delta
    guard (0...1).contains(index),(0...1).contains(next) else {return}
    var order=selectedOrder;order.swapAt(index,next)
    if editingDefaults {JevSettings.current.setGlobalOrder(order);saveDefaults()} else {inputOwner?.jev.chooseOrder(order)}
    updateScopeHint()
    orderTable.reloadData();orderTable.selectRowIndexes(IndexSet(integer:next),byExtendingSelection:false);updateArrows();refreshStatus()
  }
  @objc private func orderUp() {move(-1)}
  @objc private func orderDown() {move(1)}
  private func saveDefaults() {
    JevSettings.save();JevInputAdapter.reloadPolicies()
    if let owner=inputOwner,owner.client != nil {
      JevRuntimeManager.shared.ensureRunning(providers:owner.jev.eligible ? owner.jev.activeProviders : [])
      owner.rimeUpdate()
    }
  }
  @objc private func scopeChanged() {syncSelection();refreshStatus()}
  @objc private func followDefaults() {
    guard !editingDefaults else {return}
    inputOwner?.jev.followDefault();syncSelection();refreshStatus()
  }
  private func updateScopeHint() {
    guard !editingDefaults else {return}
    follow.isEnabled=JevSettings.current.hasAppOverride(app)
    let appName=NSRunningApplication.runningApplications(withBundleIdentifier:app).first?.localizedName ?? "当前应用"
    scopeHint.stringValue=appName+"：使用单独设置；可恢复跟随默认。"
  }
  @objc private func modeChanged() {
    let modes=["off","jev","local","dual"]
    guard modes.indices.contains(mode.indexOfSelectedItem) else {return}
    let value=modes[mode.indexOfSelectedItem]
    if editingDefaults {JevSettings.current.setGlobalMode(value);saveDefaults()} else {inputOwner?.jev.chooseMode(value)}
    syncSelection();refreshStatus()
  }
  @objc private func localChanged() {
    guard JevProviders.local.indices.contains(localModel.indexOfSelectedItem) else {return}
    let value=JevProviders.local[localModel.indexOfSelectedItem]
    if editingDefaults {JevSettings.current.setGlobalLocalModel(value);saveDefaults()} else {inputOwner?.jev.chooseLocalModel(value)}
    syncSelection();refreshStatus()
  }
  @objc private func timeoutModelChanged() {
    timeoutField.stringValue=String(Double(JevProviders.timeoutMilliseconds(provider:selectedTimeoutProvider,overrides:JevSettings.current.timeoutOverrides))/1000)
    timeoutHint.stringValue="0.3–10 秒；按模型保存，各应用共用。从停止键入起计时，继续输入或选词会作废旧结果。"
  }
  @objc private func saveTimeout() {
    guard let milliseconds=JevProviders.parseTimeoutSeconds(timeoutField.stringValue) else {timeoutHint.stringValue="请输入 0.3–10 秒之间的数值。";return}
    var values=JevSettings.current.timeoutOverrides ?? [:];values[selectedTimeoutProvider]=milliseconds
    JevSettings.current.timeoutOverrides=values;JevSettings.save();JevInputAdapter.reloadPolicies()
    timeoutField.stringValue=String(Double(milliseconds)/1000);timeoutHint.stringValue=JevProviders.name(selectedTimeoutProvider)+"超时已保存。"
  }
  @objc private func resetTimeout() {
    JevSettings.current.timeoutOverrides?.removeValue(forKey:selectedTimeoutProvider);JevSettings.save();JevInputAdapter.reloadPolicies()
    timeoutModelChanged();timeoutHint.stringValue=JevProviders.name(selectedTimeoutProvider)+"已恢复默认超时。"
  }
  private func refreshKeyStatus() {
    guard !keyBusy else {return}
    DispatchQueue.global(qos:.utility).async { [weak self] in
      let saved=JevKeychain.hasKey()
      DispatchQueue.main.async { [weak self] in
        guard let self,!self.keyBusy else {return}
        self.keyField.placeholderString=saved ? "已保存；输入新密钥可替换" : "输入 API 密钥"
        self.keyDelete.isEnabled=saved
        self.keyHint.stringValue=saved ? "密钥已保存在 macOS 钥匙串，不会回显。" : (JevSettings.current.effectiveCredentialSource=="vault" ? "当前使用已配置的凭据服务；保存新密钥后改用钥匙串。" : "尚未保存密钥。密钥仅存入 macOS 钥匙串。")
      }
    }
  }
  private func editKey(deleting:Bool) {
    guard !keyBusy else {return}
    let value=keyField.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
    guard deleting || !value.isEmpty else {keyHint.stringValue="请先输入 API 密钥。";return}
    keyBusy=true;keySave.isEnabled=false;keyDelete.isEnabled=false;keyField.stringValue="";keyHint.stringValue="正在更新钥匙串…"
    DispatchQueue.global(qos:.userInitiated).async { [weak self] in
      var succeeded=false
      do {if deleting {try JevKeychain.delete()} else {try JevKeychain.save(value)};succeeded=true} catch {}
      let ok=succeeded
      DispatchQueue.main.async { [weak self] in
        guard let self else {return}
        self.keyBusy=false;self.keySave.isEnabled=true
        if ok {
          JevSettings.current.credentialSource="keychain"
          JevSettings.current.credentialRevision=(JevSettings.current.credentialRevision ?? 0) &+ 1
          JevSettings.save();JevInputAdapter.reloadPolicies()
          if self.providers.contains("jev") {JevRuntimeManager.shared.ensureRunning(providers:self.providers);JevRuntimeManager.shared.reloadSelected("jev")}
          self.refreshKeyStatus()
        } else {self.keyHint.stringValue="钥匙串更新失败；原有配置保留，请重试。"}
      }
    }
  }
  @objc private func saveKey() {editKey(deleting:false)}
  @objc private func deleteKey() {editKey(deleting:true)}
  private func refreshStatus() {
    guard window?.isVisible==true else {return}
    statusGeneration &+= 1;let generation=statusGeneration,active=providers,configured=displayedProviders
    model.stringValue=configured.isEmpty ? "使用万象原有候选。" : (editingDefaults ? "默认模型：" : "当前模型：")+configured.map(JevProviders.name).joined(separator:" ＋ ")+(configured.count==2 ? "\n列表从上到下决定推荐优先级；命中首选的模型优先标注。" : "")
    install.isEnabled=["local","dual"].contains(selectedMode) && download?.isRunning != true
    guard download?.isRunning != true else {return}
    if editingDefaults {
      status.stringValue=configured.isEmpty ? "默认增强已关闭，未单独设置的应用使用万象候选。" : "未单独设置的应用将自动使用上述默认模型。"
      return
    }
    if active.isEmpty {status.stringValue="增强已关闭，正常输入不受影响。";return}
    DispatchQueue.global().async { [weak self] in
      let descriptions=active.map { provider -> String in
        let data=JevRuntimeManager.exchange(JevRuntimeManager.shared.socketPath(provider),payload:Data("{\"id\":\"settings\",\"op\":\"health\"}".utf8))
        let response=data.flatMap {try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
        let value=response?["provider"] as? String==provider ? response?["status"] as? String ?? "unavailable" : "unavailable"
        let description=["ready":"已就绪","loading":"加载中","unavailable":"未就绪，保留原候选","unloaded":"内存已释放","busy":"处理中"][value] ?? "保留原候选"
        return JevProviders.name(provider)+"："+description
      }
      DispatchQueue.main.async { [weak self] in
        guard let self,self.statusGeneration==generation,self.providers==active,self.download?.isRunning != true else {return}
        self.status.stringValue=descriptions.joined(separator:"\n")
      }
    }
  }
  @objc private func installModel() {
    guard download?.isRunning != true else {return}
    let settings=JevSettings.current,provider=selectedLocalModel,task=Process()
    guard let arguments=JevProviders.downloadArguments(provider:provider,projectRoot:settings.projectRoot,modelPath:settings.modelPath) else {return}
    statusGeneration &+= 1
    task.executableURL=URL(fileURLWithPath:settings.projectRoot+"/.venv/bin/python");task.currentDirectoryURL=URL(fileURLWithPath:settings.projectRoot);task.arguments=arguments
    var env=ProcessInfo.processInfo.environment;env["PYTHONPATH"]=settings.projectRoot+"/src";env["RIME_JEV_PROJECT_ROOT"]=settings.projectRoot;task.environment=env
    task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
    task.terminationHandler={ [weak self] p in DispatchQueue.main.async {
      guard let self else {return}
      self.progress.stopAnimation(nil);self.download=nil
      if p.terminationStatus==0,self.providers.contains(provider) {JevRuntimeManager.shared.reloadSelected(provider)}
      self.refreshStatus();self.statusGeneration &+= 1
      self.status.stringValue=JevProviders.name(provider)+(p.terminationStatus==0 ? "：已下载并通过校验" : "：下载未完成，原有输入仍然可用")
    }}
    do {try task.run();download=task;install.isEnabled=false;progress.startAnimation(nil);status.stringValue="正在下载或校验，可继续正常输入。"}
    catch {status.stringValue="无法启动下载，原有输入仍然可用。"}
  }
}
