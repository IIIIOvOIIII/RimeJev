import Foundation

private func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError("Training capture: " + message) }
}
private let words = [JevCandidate(id:"c0",text:"邮箱",key:"a"),JevCandidate(id:"c1",text:"油箱",key:"b")]
private final class Fixture {
    var records:[[String:Any]]=[]
    var settings=JevTrainingSettings()
    lazy var capture=JevTrainingCapture(sink:{ [unowned self] data in
        self.records.append(try! JSONSerialization.jsonObject(with:data) as! [String:Any]);return true
    })
    init(enabled:Bool=true) {settings.enabled=enabled;settings.includedApps=["test.editor"];configure()}
    func configure(secure:Bool=false) {capture.configure(settings,app:"test.editor",secureInput:secure)}
    func observe(raw:String="youxiang",prefix:String="",candidates:[JevCandidate]=words,display:[String]=["邮箱","油箱"]) {
        capture.observe(raw:raw,pinyin:raw,prefix:prefix,displayCode:raw,abbreviated:false,
                        candidates:candidates,displayed:display,page:0,highlighted:0,environment:["version":"test"])
        if let token=capture.token {capture.context(JevLineSnapshot(position:position(),context:"汽车",source:"current_line",readReason:"read"),token:token)}
    }
    func position() -> JevTextPosition {JevTextPosition(client:"editor",selected:NSRange(location:2,length:0),marked:NSRange(location:NSNotFound,length:0))}
    func selection(_ index:Int=0)->[String:Any] {records[index]["selection"] as! [String:Any]}
}
@main private enum JevTrainingCaptureTests {
    static func main() {
        let off=Fixture(enabled:false);off.observe();off.capture.choose(method:"digit",index:1);off.capture.commit("油箱",position:off.position())
        expect(off.records.isEmpty && off.capture.token==nil,"off emits nothing")
        let blocked=Fixture();blocked.configure(secure:true);blocked.observe();blocked.capture.commit("油箱",position:blocked.position())
        expect(blocked.records.isEmpty,"secure input excluded")
        var cfg=JevTrainingSettings();cfg.enabled=true
        expect(!cfg.permits(app:"test.editor",secureInput:false),"empty selected-app list collects nowhere")
        cfg.scope="allExceptExcluded";cfg.excludedApps=["blocked"]
        expect(cfg.permits(app:"test.editor",secureInput:false) && !cfg.permits(app:"blocked",secureInput:false),"application scope")
        expect(!cfg.permits(app:"im.lynx.inputmethod.RimeJev",secureInput:false),"own key/settings excluded")
        let partialConfig=try! JSONDecoder().decode(JevTrainingSettings.self,from:Data("{\"enabled\":true}".utf8))
        expect(partialConfig.scope=="selected" && partialConfig.includedApps.isEmpty,"compatible defaults")
        let corrupt=try! JSONDecoder().decode(JevTrainingSettings.self,from:Data("{\"enabled\":true,\"scope\":\"bad\"}".utf8))
        expect(!corrupt.enabled,"invalid scope cannot broaden access")
        let valid=Fixture();valid.observe(display:["邮箱","油箱"])
        let token=valid.capture.token!
        valid.capture.modelRequest(token:token,provider:"jev",modelCandidates:words.map {JevRequestCandidate(id:$0.id,text:$0.text)},timeout:600)
        valid.capture.modelResponse(token:token,response:JevDecisionResponse(id:"req",provider:"jev",model:"fixture",choiceID:"c0",probabilities:["c0":0.9,"c1":0.1]),elapsed:1)
        valid.capture.choose(method:"digit",index:1);valid.capture.commit("油箱",position:valid.position())
        expect(valid.records.count==1 && valid.selection()["candidate_id"] as? String=="c1","human choice overrides model preference")
        expect(valid.selection()["status"] as? String=="committed","matched final commit")
        expect((valid.records[0]["models"] as! [[String:Any]])[0]["choice_id"] as? String=="c0","model decision retained separately")
        valid.capture.modelResponse(token:token,response:JevDecisionResponse(id:"late",provider:"jev"),elapsed:100)
        expect(valid.records.count==1,"late response cannot write a second sample")
        let bare=Fixture();bare.observe();bare.capture.choose(method:"space");bare.capture.commit("邮箱",position:bare.position())
        expect(bare.selection()["method"] as? String=="space","default acceptance distinguished")
        let cancelled=Fixture();cancelled.observe();cancelled.capture.cancel("escape")
        expect(cancelled.selection()["status"] as? String=="cancelled" && cancelled.selection()["candidate_id"] is NSNull,"cancel is not gold none")
        let mismatch=Fixture();mismatch.observe();mismatch.capture.choose(method:"digit",index:1);mismatch.capture.commit("邮箱",position:mismatch.position())
        expect(mismatch.selection()["status"] as? String=="raw","mismatched intent not labeled committed")
        let missing=Fixture();missing.observe();missing.capture.commit("幽香",position:missing.position())
        expect(missing.selection()["coverage"] as? String=="missing","absent target is coverage gap")
        let duplicates=Fixture();duplicates.observe(candidates:[words[0],JevCandidate(id:"other",text:"邮箱",key:"duplicate")]);duplicates.capture.commit("邮箱",position:duplicates.position())
        expect(duplicates.selection()["coverage"] as? String=="ambiguous","duplicate strings require identity")
        let privacy=Fixture();privacy.settings.includeContext=false;privacy.settings.includeModels=false;privacy.configure();privacy.observe(prefix:"前缀")
        privacy.capture.commit("前缀邮箱",position:privacy.position())
        expect((privacy.records[0]["context"] as! [String:Any])["text"] is NSNull,"context opt-out")
        expect((privacy.records[0]["input"] as! [String:Any])["confirmed_prefix"] as? String=="","prefix must not bypass context opt-out")
        expect((privacy.records[0]["models"] as! [Any]).isEmpty,"model opt-out")
        let secret=Fixture();secret.observe();secret.capture.context(JevLineSnapshot(position:secret.position(),context:"api_key=synthetic-secret-value",source:"current_line",readReason:"read"),token:secret.capture.token!)
        secret.capture.commit("邮箱",position:secret.position())
        expect(secret.records.isEmpty && secret.capture.dropped==1,"sensitive-pattern record discarded")
        let disabling=Fixture();disabling.observe();disabling.settings.enabled=false;disabling.configure();disabling.capture.commit("邮箱",position:disabling.position())
        expect(disabling.records.isEmpty,"disable drops pending snapshot")
        let segments=Fixture();segments.observe(raw:"youxiangyouxiang")
        segments.capture.choose(method:"digit",index:1)
        segments.observe(raw:"youxiangyouxiang",prefix:"油箱")
        segments.capture.choose(method:"space");segments.capture.commit("油箱邮箱",position:segments.position())
        expect(segments.records.count==2,"partial choices become separate confirmed segments")
        expect(segments.records[0]["composition_id"] as? String==segments.records[1]["composition_id"] as? String,"one composition grouping")
        expect(segments.selection(0)["text"] as? String=="油箱" && segments.selection(1)["text"] as? String=="邮箱","partial target alignment")
        let correctionPosition=JevTextPosition(client:"editor",selected:NSRange(location:6,length:0),marked:NSRange(location:NSNotFound,length:0))
        let probe=segments.capture.correctionProbe(position:correctionPosition)
        expect(probe != nil,"bounded same-client correction link")
        segments.capture.corrected(ids:probe!.ids)
        expect(segments.records.count==4 && segments.records[2]["event_type"] as? String=="correction","correction events reference saved choices")
        let unavailable=Fixture();unavailable.observe()
        unavailable.capture.context(JevLineSnapshot(position:unavailable.position(),context:"",source:"no_context",readReason:"text_unavailable"),token:unavailable.capture.token!)
        unavailable.capture.commit("邮箱",position:unavailable.position())
        expect((unavailable.records[0]["context"] as! [String:Any])["text"] is NSNull,"unavailable context is not a known empty context")
        let optout=Fixture();optout.settings.includeModels=false;optout.configure();optout.observe()
        optout.capture.applied(choices:[JevRecommendation(candidate:words[0],providers:["jev"])],cached:false)
        optout.capture.commit("邮箱",position:optout.position())
        let display=(optout.records[0]["display"] as! [String:Any])["items"] as! [[String:Any]]
        expect((display[0]["providers"] as! [String]).isEmpty,"model opt-out also removes source badges")
        let rollback=Fixture()
        rollback.observe(raw:"jia",candidates:[JevCandidate(id:"a",text:"甲"),JevCandidate(id:"b",text:"夹")],display:["甲","夹"])
        rollback.capture.choose(method:"space")
        rollback.observe(raw:"jiayi",prefix:"甲",candidates:[JevCandidate(id:"a",text:"乙"),JevCandidate(id:"b",text:"以")],display:["乙","以"])
        rollback.observe(raw:"jiayi",prefix:"",candidates:[JevCandidate(id:"a",text:"甲乙"),JevCandidate(id:"b",text:"甲以")],display:["甲乙","甲以"])
        rollback.capture.choose(method:"space")
        rollback.observe(raw:"jiayibing",prefix:"甲乙",candidates:[JevCandidate(id:"a",text:"丙"),JevCandidate(id:"b",text:"并")],display:["丙","并"])
        rollback.capture.choose(method:"space");rollback.capture.commit("甲乙丙",position:rollback.position())
        expect(rollback.records.count==2 && rollback.selection(0)["text"] as? String=="甲乙","undone partial selection must not survive a prefix rollback")
        expect(rollback.selection(1)["text"] as? String=="丙","surviving segment chain must match full commit")
        let other=JevTextPosition(client:"other",selected:correctionPosition.selected,marked:correctionPosition.marked)
        expect(segments.capture.correctionProbe(position:other)==nil,"no cross-client correction")
        print("JevTrainingCaptureTests PASS: off/scope/privacy, observed human choices, model isolation, partial alignment, cancellation and corrections")
    }
}
