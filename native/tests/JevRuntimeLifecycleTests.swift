import Foundation

@main
struct RuntimeLifecycleTests {
  static func main() throws {
    precondition(CommandLine.arguments.count == 2)
    let root=CommandLine.arguments[1]
    let log=URL(fileURLWithPath:root+"/events.log")
    try Data().write(to:log)
    var settings=JevSettings()
    settings.projectRoot=root;settings.modelPath=root+"/unused-model";settings.vaultRef="fake-unused-ref"
    settings.appModes=["example.test":"local"]
    let legacy=try JSONEncoder().encode(settings)
    let migrated=try JSONDecoder().decode(JevSettings.self,from:legacy)
    precondition(migrated.timeoutOverrides==nil && migrated.appModes==settings.appModes,"legacy settings migration")
    settings.timeoutOverrides=["local":1250,"tev-4b":4000]
    JevSettings.current=settings
    JevSettings.save()
    let persisted=try JSONDecoder().decode(JevSettings.self,from:Data(contentsOf:JevSettings.file))
    precondition(persisted.timeoutOverrides==settings.timeoutOverrides && persisted.appModes==settings.appModes,"independent model timeout persistence")
    JevSettings.current.timeoutOverrides?.removeValue(forKey:"local")
    JevSettings.save()
    let restored=try JSONDecoder().decode(JevSettings.self,from:Data(contentsOf:JevSettings.file))
    precondition(JevProviders.timeoutMilliseconds(provider:"local",overrides:restored.timeoutOverrides)==600,"reset selected timeout")
    precondition(JevProviders.timeoutMilliseconds(provider:"tev-4b",overrides:restored.timeoutOverrides)==4000,"reset changed another model")
    let manager=JevRuntimeManager.shared
    func events() -> [String] { (try? String(contentsOf:log,encoding:.utf8))?.split(separator:"\n").map(String.init) ?? [] }
    func wait(_ message: String, until condition: () -> Bool) {
      let deadline=Date().addingTimeInterval(12)
      while !condition(), Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.01))}
      precondition(condition(),message+": "+events().joined(separator:", "))
    }
    manager.ensureRunning("local")
    wait("local starts") { events().contains("start local") }
    var staleDelivered=false
    let request=JevDecisionRequest(id:"old-local",state:JevRequestState(context:"测试",pinyin:"jia"),
      candidates:[JevRequestCandidate(id:"a",text:"甲"),JevRequestCandidate(id:"b",text:"乙")],maxAgeMilliseconds:1500,provider:"local")
    let call=manager.send(request,provider:"local") {_ in staleDelivered=true}
    wait("local request starts") { events().contains("decide local") }
    let switchStart=Date()
    manager.ensureRunning("tev-0.8b")
    precondition(Date().timeIntervalSince(switchStart)<0.1,"switch blocks the caller")
    wait("small Tev starts") { events().contains("start tev-0.8b") }
    precondition(!staleDelivered,"old callback survived model switch")
    precondition(events().firstIndex(of:"released local")! < events().firstIndex(of:"start tev-0.8b")!,"new model started before release")
    manager.ensureRunning("tev-4b")
    wait("large Tev starts") { events().contains("start tev-4b") }
    precondition(events().firstIndex(of:"released tev-0.8b")! < events().firstIndex(of:"start tev-4b")!,"Tev variant release ordering")
    manager.ensureRunning("tev-0.8b")
    manager.ensureRunning("local")
    wait("latest selection starts") { events().filter {$0=="start local"}.count==2 }
    precondition(events().filter {$0=="start tev-0.8b"}.count==1,"superseded queued variant launched")
    precondition(events().contains("root \(root) \(root)"),"runtime does not use current settings root")
    manager.stop()
    wait("stop releases runtime") { events().filter {$0=="released local"}.count==2 }
    wait("socket removed") {!FileManager.default.fileExists(atPath:manager.socketPath("local"))}
    // Reuse a runtime launched by an earlier input-method process, without a Process handle.
    let external=Process()
    external.executableURL=URL(fileURLWithPath:root+"/.venv/bin/python")
    external.currentDirectoryURL=URL(fileURLWithPath:root)
    external.arguments=["-m","rime_jev.runtime","--socket",manager.socketPath("tev-4b"),"--provider","tev-4b"]
    var env=ProcessInfo.processInfo.environment
    env["PYTHONPATH"]=root+"/src";env["RIME_JEV_PROJECT_ROOT"]=root
    external.environment=env
    try external.run()
    wait("external Tev starts") {events().filter {$0=="start tev-4b"}.count==2}
    manager.ensureRunning("tev-4b")
    var reused=false
    // Allow the asynchronous adoption before requesting a decision.
    RunLoop.current.run(until:Date().addingTimeInterval(0.2))
    let adoptedCall=manager.send(request,provider:"tev-4b") {response in reused=response.status=="ready"}
    wait("existing Tev adopted") {reused && events().contains("decide tev-4b")}
    manager.ensureRunning("local")
    wait("local starts after reused Tev") {events().filter {$0=="start local"}.count==3}
    precondition(events().lastIndex(of:"released tev-4b")! < events().lastIndex(of:"start local")!,"reused model not released before next load")
    precondition(!external.isRunning,"adopted runtime still running")
    manager.reloadSelected("local")
    wait("download completion reloads selected runtime") {events().filter {$0=="start local"}.count==4}
    precondition(events().filter {$0=="released local"}.count==3,"reload skipped release")
    manager.reloadSelected("tev-4b")
    RunLoop.current.run(until:Date().addingTimeInterval(0.2))
    precondition(events().filter {$0=="start tev-4b"}.count==2,"download changed current selection")
    manager.stop()
    wait("reloaded runtime stopped") {events().filter {$0=="released local"}.count==4}
    adoptedCall.cancel()
    call.cancel()
    print("RuntimeLifecycleTests PASS: delayed owned/adopted release precedes launch; download reload; stale variants discarded; async switch; all stopped")
  }
}
