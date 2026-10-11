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
    var profiles=settings
    profiles.appModes=["old":"tev-4b","test":"dual","cloud":"jev"]
    profiles.appLocalModels=["test":"tev-0.8b"]
    profiles.appModelOrders=["test":["local","jev"]]
    precondition(profiles.enhancementMode(for:"old")=="local" && profiles.providers(for:"old")==["tev-4b"],"legacy local mode migration enabled cloud")
    precondition(profiles.providers(for:"test")==["tev-0.8b","jev"],"dual order/local choice")
    precondition(profiles.providers(for:"cloud")==["jev"] && profiles.providers(for:"unknown").isEmpty,"explicit cloud scope")
    let decoded=try JSONDecoder().decode(JevSettings.self,from:JSONEncoder().encode(profiles))
    precondition(decoded.providers(for:"test")==profiles.providers(for:"test"),"dual profile persistence")
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
    JevSettings.current.credentialSource="vault" // Fake runtime never uses credentials.
    manager.ensureRunning(providers:["jev","local"])
    wait("both runtimes coexist") {events().contains("start jev") && events().filter {$0=="start local"}.count==5}
    var cloudDone=false,localDone=false
    let cloudRequest=JevDecisionRequest(id:"dual-cloud",state:request.state,candidates:request.candidates,maxAgeMilliseconds:1500,provider:"jev")
    let cloudCall=manager.send(cloudRequest,provider:"jev") {cloudDone=$0.status=="ready"}
    let localCall=manager.send(request,provider:"local") {localDone=$0.status=="ready"}
    wait("independent responses") {cloudDone && localDone}
    manager.ensureRunning(providers:["jev","tev-0.8b"])
    wait("local replacement while cloud stays alive") {events().filter {$0=="start tev-0.8b"}.count==2}
    precondition(events().filter {$0=="start jev"}.count==1 && !events().contains("released jev"),"local switch unnecessarily restarted Jev")
    precondition(events().lastIndex(of:"released local")! < events().lastIndex(of:"start tev-0.8b")!,"dual mode loaded two local models")
    manager.ensureRunning("local")
    wait("local-only stops cloud") {events().contains("released jev") && events().filter {$0=="start local"}.count==6}
    manager.stop()
    wait("dual fixtures stopped") {events().filter {$0=="released local"}.count==6}
    cloudCall.cancel();localCall.cancel()
    let blocked=DispatchSemaphore(value:0),credentialEntered=DispatchSemaphore(value:0)
    let waitingManager=JevRuntimeManager(keyReader:{credentialEntered.signal();blocked.wait();return "synthetic-credential"})
    JevSettings.current.credentialSource="keychain"
    let cloudsBefore=events().filter {$0=="start jev"}.count
    waitingManager.ensureRunning(providers:["jev","local"])
    precondition(credentialEntered.wait(timeout:.now()+2) == .success,"credential read never started")
    wait("local starts while Keychain waits") {events().filter {$0=="start local"}.count==7}
    waitingManager.ensureRunning("local");blocked.signal()
    RunLoop.current.run(until:Date().addingTimeInterval(0.3))
    precondition(events().filter {$0=="start jev"}.count==cloudsBefore,"stale Keychain completion launched cloud")
    waitingManager.stop()
    wait("waiting manager stopped") {events().filter {$0=="released local"}.count==7}
    let credentialsManager=JevRuntimeManager(keyReader:{"synthetic-credential"})
    JevSettings.current.credentialRevision=1
    credentialsManager.ensureRunning(providers:["jev","tev-4b"])
    wait("Keychain pipe starts cloud") {events().filter {$0=="start jev"}.count==cloudsBefore+1 && events().filter {$0=="start tev-4b"}.count==3}
    credentialsManager.ensureRunning(providers:["jev","local"])
    JevSettings.current.credentialRevision=2
    credentialsManager.ensureRunning(providers:["jev","local"])
    credentialsManager.reloadSelected("jev")
    credentialsManager.ensureRunning(providers:["jev","tev-0.8b"])
    wait("credential revision survives local selection changes") {events().filter {$0=="start jev"}.count==cloudsBefore+2 && events().filter {$0=="start tev-0.8b"}.count==3}
    precondition(events().filter {$0=="credential jev"}.count==2,"cloud key did not use private pipe twice")
    var pressureCloudDone=false
    let decisionsBefore=events().filter {$0=="decide jev"}.count
    let pressureCall=credentialsManager.send(cloudRequest,provider:"jev") {pressureCloudDone=$0.status=="ready"}
    wait("cloud request entered before local pressure") {events().filter {$0=="decide jev"}.count==decisionsBefore+1}
    credentialsManager.handleMemoryPressure()
    wait("local pressure preserves cloud response") {pressureCloudDone}
    credentialsManager.stop()
    wait("credential manager fully stopped") {!FileManager.default.fileExists(atPath:credentialsManager.socketPath("jev")) && !FileManager.default.fileExists(atPath:credentialsManager.socketPath("tev-0.8b"))}
    pressureCall.cancel()
    adoptedCall.cancel()
    call.cancel()
    print("RuntimeLifecycleTests PASS: dual profiles, concurrent cloud/local, local replacement, no implicit cloud; delayed release; stale variants; all stopped")
  }
}
