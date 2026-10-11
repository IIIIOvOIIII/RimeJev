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
  static let shared = JevRuntimeManager()
  private let queue = DispatchQueue(label: "rime-jev.runtime", qos: .userInitiated)
  private var process: Process?
  private var runningProvider = ""
  private var lastLaunch = Date.distantPast
  private var resourceBackoff = Date.distantPast
  private var pressureMonitor: DispatchSourceMemoryPressure?
  private init() {
    let monitor=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:queue)
    monitor.setEventHandler { [weak self] in
      guard let self else{return}
      self.resourceBackoff=Date().addingTimeInterval(60)
      _ = Self.exchange(self.socketPath("local"),payload:Data("{\"id\":\"pressure\",\"op\":\"shutdown\"}".utf8))
      if self.runningProvider=="local" {self.process?.terminate();self.process=nil;self.runningProvider=""}
    }
    pressureMonitor=monitor;monitor.resume()
  }
  func socketPath(_ provider: String) -> String { JevSettings.support.appendingPathComponent("\(provider).sock").path }
  func ensureRunning(_ provider: String) {
    let settings = JevSettings.current
    guard ["local", "jev"].contains(provider) else { return }
    queue.async { [self] in
      if provider=="local" && resourceBackoff>Date() {return}
      if process?.isRunning == true && runningProvider == provider { return }
      if Date().timeIntervalSince(lastLaunch) < 3 { return }
      if let data=Self.exchange(socketPath(provider),payload:Data("{\"id\":\"reuse\",\"op\":\"health\"}".utf8)),
         let health=try? JSONSerialization.jsonObject(with:data) as? [String:Any], health["provider"] as? String==provider {
        runningProvider=provider;return
      }
      process?.terminate()
      lastLaunch = .now
      let task = Process()
      task.executableURL = URL(fileURLWithPath: settings.projectRoot).appendingPathComponent(".venv/bin/python")
      task.arguments = ["-m", "rime_jev.runtime", "--socket", socketPath(provider), "--provider", provider,
                        "--model-path", settings.modelPath, "--vault-ref", settings.vaultRef]
      var env = ProcessInfo.processInfo.environment
      env["PYTHONPATH"] = settings.projectRoot + "/src"
      env["HF_HUB_OFFLINE"] = "1"
      env["TOKENIZERS_PARALLELISM"] = "false"
      if let url=settings.vaultURL, !url.isEmpty { env["RIME_JEV_VAULT_URL"]=url }
      if let helper=settings.vaultTokenHelper, !helper.isEmpty { env["RIME_JEV_VAULT_TOKEN_HELPER"]=helper }
      task.environment = env
      task.standardOutput = FileHandle.nullDevice
      task.standardError = FileHandle.nullDevice
      do { try task.run(); process = task; runningProvider = provider } catch { process = nil }
    }
  }
  func stop() { queue.async {
    for provider in ["local","jev"] { _ = Self.exchange(self.socketPath(provider),payload:Data("{\"id\":\"stop\",\"op\":\"shutdown\"}".utf8)) }
    self.process?.terminate(); self.process = nil; self.runningProvider = ""; self.lastLaunch = .distantPast
  } }
  func send(_ request: JevDecisionRequest, provider: String, completion: @escaping (JevDecisionResponse) -> Void) -> JevCancellable {
    let call = JevSocketCall(), path = socketPath(provider)
    DispatchQueue.global(qos: .userInitiated).async {
      let failure = JevDecisionResponse(id: request.id, status: "unavailable", provider: provider, probabilities: [:])
      var response = failure
      if !call.isCancelled, let payload = try? request.jsonData(), let data = Self.exchange(path, payload: payload),
         let value = try? JSONDecoder().decode(JevDecisionResponse.self, from: data) { response = value }
      let delivered = response
      DispatchQueue.main.async { if !call.isCancelled { completion(delivered) } }
    }
    return call
  }
  static func exchange(_ path: String, payload: Data) -> Data? {
    guard payload.count < 131072 else { return nil }
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { Darwin.close(fd) }
    var timeout = timeval(tv_sec: 1, tv_usec: 500000), noSignal: Int32 = 1
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
    guard connected == 0 else { return nil }
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
  private var badgeText: String?, badgeWord: String?
  private var badgeKey: String?
  private struct CachedChoice {
    let candidate: JevCandidate
    let signature: String
    let count: Int
    let provider: String
    let matchesFirst: Bool
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
  init(controller: SquirrelInputController) {
    self.controller = controller
    rebuildCoordinator()
    Self.instances.append(WeakAdapter(value: self))
  }
  var provider: String {
    guard let app=controller?.currentApp else{return "off"}
    return JevSettings.current.appModes[app] ?? "off"
  }
  var eligible: Bool {
    guard let controller else { return false }
    let settings = JevSettings.current
    return !IsSecureEventInputEnabled() && ["local","jev"].contains(provider) && settings.allowedApps.contains(controller.currentApp)
  }
  private func rebuildCoordinator() {
    let settings = JevSettings.current
    coordinator = JevDecisionCoordinator(configuration: JevCoordinatorConfiguration(policy: JevDecisionPolicy(
      defaultThreshold: JevDecisionThreshold(minimumProbability: 0.85, minimumMargin: 0.15),
      thresholdsByProvider: ["local": JevDecisionThreshold(minimumProbability: settings.localThreshold, minimumMargin: 0.15),
                             "jev": JevDecisionThreshold(minimumProbability: settings.jevThreshold, minimumMargin: 0.15)],
      probabilitySumTolerance: 0.002)), transport: { [weak self] request, completion in
        guard let self else { return JevSocketCall() }
        self.verifyContinuity()
        guard self.eligible, String((self.context+self.confirmedPrefix).suffix(80)) == request.state.context else {
          self.lastReason="context_changed_before_request"
          completion(JevDecisionResponse(id:request.id,status:"unavailable",provider:request.provider))
          return JevSocketCall()
        }
        self.requests += 1
        return JevRuntimeManager.shared.send(request, provider: request.provider) { [weak self] response in
          self?.responseStatus=response.status
          completion(response)
        }
      }, onDecision: { [weak self] decision in self?.apply(decision) })
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
    coordinator.invalidate(); epoch &+= 1
    preparedSeed="";samplingSeed=""
    identity = ""; input = ""; confirmedPrefix=""; requestContext=""; baseline = []; badgeText = nil; badgeWord = nil; badgeKey = nil
    sortingLocked = false; committingLocked = false
    set("_jev_epoch", String(epoch)); set("_jev_result", "")
    pendingCache = nil
    if clearContext { contextClears += 1; recentContext.reset(); pendingHostCommit=false; cache.removeAll(); focusGeneration &+= 1 }
  }
  func activate() { activations += 1; invalidate(clearContext: true); if eligible { JevRuntimeManager.shared.ensureRunning(provider) } }
  func chooseMode(_ mode: String) {
    invalidate(clearContext: true)
    JevSettings.current.mode = mode
    if let app=controller?.currentApp { JevSettings.current.appModes[app]=mode }
    if let app = controller?.currentApp, !JevSettings.current.allowedApps.contains(app) { JevSettings.current.allowedApps.append(app) }
    JevSettings.save(); rebuildCoordinator()
    JevRuntimeManager.shared.stop()
    if mode == "off" { JevRuntimeManager.shared.stop() } else { JevRuntimeManager.shared.ensureRunning(mode) }
    controller?.rimeUpdate()
  }
  func sortLock() { sortingLocked=true; coordinator.lockSorting() }
  func commitLock() { sortingLocked=true; committingLocked=true; coordinator.lockCommit() }
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
    coordinator.invalidate();badgeText=nil;badgeWord=nil;badgeKey=nil
  }
  func beforeMenu(schema: String) {
    if !self.schema.isEmpty && self.schema != schema { invalidate(clearContext: true) }
    self.schema=schema
    // insertText may update a browser's selection on its next event-loop turn.
    // The same commit refresh must not discard the newly committed context.
    verifyContinuity(allowPendingCommit:true)
    guard !applying, !sortingLocked, !committingLocked, eligible, !context.isEmpty, recentContext.lastCheckReason=="verified", confirmedPrefix.isEmpty, let c=controller,
          let pointer=c.rimeAPI.get_input(c.session) else { return }
    let raw=String(cString:pointer)
    guard !raw.isEmpty else { return }
    cacheKey=[schema,c.currentApp,String(c.session),String(focusGeneration),String(describing:clientIdentity),raw,context,provider].joined(separator:"\u{1f}")
    guard property("_jev_result").isEmpty, let entry=cache[cacheKey], Date().timeIntervalSince(entry.created)<60 else { return }
    pendingCache=entry
    let wire=[String(epoch),Self.hex(raw),entry.candidate.key,String(entry.count),entry.signature,entry.provider].joined(separator:"|")
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
    guard !raw.isEmpty else { coordinator.invalidate(); identity=""; input=""; badgeText=nil; badgeWord=nil; badgeKey=nil; return }
    if !property("_jev_applied").isEmpty { coordinator.invalidate(); return }
    guard let data = property("_jev_snapshot").data(using:.utf8),
          let snap = try? JSONSerialization.jsonObject(with:data) as? [String:Any], snap["input"] as? String == raw,
          snap["protected"] as? Bool == false, let rows = snap["candidates"] as? [[String:String]] else { lastReason="snapshot_unavailable_or_protected";return }
    let pinyin=snap["pinyin"] as? String ?? raw
    let limit=JevCandidateWindow.limit(pinyin:pinyin,displayCode:displayCode)
    let list=decodeRows(rows,limit:limit)
    let modelContext=String((context+confirmedPrefix).suffix(80))
    guard list.count >= 2, page == 0, list.first?.text == candidates.first, !modelContext.isEmpty else { lastReason=modelContext.isEmpty ? "no_context" : "candidate_mismatch";return }
    guard !sortingLocked, !committingLocked else {return}
    let seed = "\(c.session)|\(epoch)|\(focusGeneration)|\(schema)|\(c.currentApp)|\(String(describing:clientIdentity))|\(raw)|\(pinyin)|\(limit)|\(provider)|\(modelContext)"
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
    JevRuntimeManager.shared.ensureRunning(provider)
    coordinator.onNewSnapshot(JevInputSnapshot(identity:identity,pinyin:pinyin,context:modelContext,candidates:list,provider:provider,abbreviated:abbreviated),startedAtMilliseconds:startedAt)
    lastReason="scheduled"
  }
  private func apply(_ decision: JevDecision) {
    decisions += 1; lastReason="decision"
    guard let c=controller, eligible, !applying, !committingLocked, c.rimeAPI.find_session(c.session), coordinator.currentIdentity==identity,
          decision.provider==provider,
          (c.rimeAPI.get_input(c.session).map {String(cString:$0)} ?? "")==input,
          baseline.contains(decision.candidate) else { return }
    verifyContinuity()
    guard !requestContext.isEmpty, String((context+confirmedPrefix).suffix(80))==requestContext else { return }
    if decision.action == .annotate {
      // Compact rows have no hidden badge slots. A late decoration must not
      // expand a cell after the user has started choosing.
      lastReason="late_no_stable_space"
      return
    }
    guard !sortingLocked else { return }
    let wire = [String(epoch), Self.hex(input), decision.candidate.key, String(baseline.count),
                Self.hex(baseline.map(\.key).joined(separator:"\n")), decision.provider].joined(separator:"|")
    applying=true
    set("_jev_result",wire)
    var rebuilt = RimeContext_stdbool.rimeStructInit()
    if c.rimeAPI.get_context(c.session, &rebuilt) { _ = c.rimeAPI.free_context(&rebuilt) }
    if property("_jev_applied")==decision.candidate.key {
      badgeKey=decision.candidate.key; badgeWord=decision.candidate.text; badgeText=JevBadge.label(provider:decision.provider,matchesFirst:baseline.first?.key==decision.candidate.key)
      if cache.count>=128, let oldest=cache.min(by:{$0.value.created<$1.value.created})?.key { cache.removeValue(forKey:oldest) }
      if confirmedPrefix.isEmpty { cache[requestCacheKey]=CachedChoice(candidate:decision.candidate,signature:Self.hex(baseline.map(\.key).joined(separator:"\n")),count:baseline.count,provider:decision.provider,matchesFirst:baseline.first?.key==decision.candidate.key,created:.now) }
    } else {
      set("_jev_result", "")
    }
    c.rimeUpdate()
    applying=false
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
  func badge(for word:String, index:Int) -> NSAttributedString? {
    guard eligible else {return nil}
    if let entry=pendingCache, property("_jev_applied")==entry.candidate.key {
      badgeKey=entry.candidate.key;badgeWord=entry.candidate.text; badgeText=JevBadge.label(provider:entry.provider,matchesFirst:entry.matchesFirst)
      pendingCache=nil
    }
    guard index < visibleKeys.count, visibleKeys[index]==badgeKey, word==badgeWord else {return nil}
    return JevBadge.render(badgeText)
  }
  static func hex(_ value:String)->String { value.utf8.map{String(format:"%02x",$0)}.joined() }
}

final class JevPreferences: NSWindowController {
  private static var retained: JevPreferences?
  private weak var inputOwner: SquirrelInputController?
  private let mode = NSPopUpButton()
  private let status = NSTextField(labelWithString: "")
  private let progress = NSProgressIndicator()
  private var timer: Timer?
  private var download: Process?
  static func show(for inputOwner: SquirrelInputController) {
    inputOwner.jev.invalidate(clearContext: true)
    if retained == nil { retained = JevPreferences(inputOwner: inputOwner) }
    retained?.inputOwner = inputOwner
    retained?.mode.selectItem(at: ["off","local","jev"].firstIndex(of:inputOwner.jev.provider) ?? 0)
    retained?.showWindow(nil)
    NSApp.activate(ignoringOtherApps: true)
    retained?.refreshStatus()
  }
  init(inputOwner: SquirrelInputController) {
    self.inputOwner = inputOwner
    let window = NSWindow(contentRect:NSRect(x:0,y:0,width:480,height:350),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
    window.title="鼠须管 Jev 设置"
    super.init(window:window)
    let content=NSStackView();content.orientation = .vertical;content.alignment = .leading;content.spacing=14
    content.translatesAutoresizingMaskIntoConstraints=false
    window.contentView?.addSubview(content)
    if let view=window.contentView { NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:view.leadingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:view.trailingAnchor,constant:-24),content.topAnchor.constraint(equalTo:view.topAnchor,constant:24)]) }
    let title=NSTextField(labelWithString:"语境选词");title.font=NSFont.boldSystemFont(ofSize:20);content.addArrangedSubview(title)
    mode.addItems(withTitles:["关闭增强，使用万象词库","本地模型，输入留在本机","Jev 云端，发送有限上下文与候选"])
    mode.target=self;mode.action=#selector(jevModeChanged);content.addArrangedSubview(mode)
    let explanation=NSTextField(wrappingLabelWithString:"选择模式后，对当前应用启用。其他应用可从输入法菜单单独开启。模型无结果时，始终保留原有候选。")
    content.addArrangedSubview(explanation)
    let model=NSTextField(labelWithString:"本地模型：this-that-model 1.2 · MLX\n空闲 10 分钟后自动释放模型内存")
    content.addArrangedSubview(model)
    let install=NSButton(title:"安装或校验本地模型",target:self,action:#selector(installModel));content.addArrangedSubview(install)
    progress.style = .bar;progress.isIndeterminate=true;progress.isDisplayedWhenStopped=false;progress.widthAnchor.constraint(equalToConstant:420).isActive=true
    content.addArrangedSubview(progress);content.addArrangedSubview(status)
    window.center()
    timer=Timer.scheduledTimer(withTimeInterval:2,repeats:true) { [weak self] _ in self?.refreshStatus() }
  }
  required init?(coder:NSCoder) { fatalError("init(coder:) is not supported") }
  @objc private func jevModeChanged() { inputOwner?.jev.chooseMode(["off","local","jev"][mode.indexOfSelectedItem]);refreshStatus() }
  private func refreshStatus() {
    guard window?.isVisible==true, download?.isRunning != true else {return}
    let provider=inputOwner?.jev.provider ?? "off"
    if provider=="off" {status.stringValue="当前使用万象原有候选";return}
    let socket=JevRuntimeManager.shared.socketPath(provider)
    DispatchQueue.global().async { [weak self] in
      let data=JevRuntimeManager.exchange(socket,payload:Data("{\"id\":\"settings\",\"op\":\"health\"}".utf8))
      let response=data.flatMap{try? JSONSerialization.jsonObject(with:$0) as? [String:Any]}
      let value=response?["status"] as? String ?? "unavailable"
      DispatchQueue.main.async { [weak self] in
        guard self?.inputOwner?.jev.provider==provider else{return}
        self?.status.stringValue=["ready":"后台已就绪","loading":"模型加载中，当前使用万象候选","unavailable":"后台未就绪，当前使用万象候选","busy":"模型处理中，输入不受影响"][value] ?? "当前使用万象候选"
      }
    }
  }
  @objc private func installModel() {
    guard download?.isRunning != true else{return}
    let settings=JevSettings.current, task=Process()
    task.executableURL=URL(fileURLWithPath:settings.projectRoot+"/.venv/bin/python")
    task.arguments=[settings.projectRoot+"/scripts/download_model.py","--destination",settings.modelPath]
    task.standardOutput=FileHandle.nullDevice;task.standardError=FileHandle.nullDevice
    task.terminationHandler={ [weak self] p in DispatchQueue.main.async { self?.progress.stopAnimation(nil);self?.status.stringValue=p.terminationStatus==0 ? "本地模型已安装并通过校验" : "安装未完成，原有输入仍然可用" } }
    do {try task.run();download=task;progress.startAnimation(nil);status.stringValue="正在下载或校验模型，可继续正常输入"}catch{status.stringValue="无法启动安装，原有输入仍然可用"}
  }
}
