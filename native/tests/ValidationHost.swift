import AppKit

final class ValidationActions: NSObject {
  @objc func connect() {
    NSApp.activate(ignoringOtherApps: true)
    ValidationHost.window.makeKeyAndOrderFront(nil)
    ValidationHost.window.makeFirstResponder(ValidationHost.text)
    ValidationHost.text.inputContext?.activate()
    ValidationHost.text.inputContext?.selectedKeyboardInputSource="im.lynx.inputmethod.RimeJev.Hans"
    update()
  }
  func update() {
    let input=ValidationHost.text.inputContext?.selectedKeyboardInputSource ?? "none"
    ValidationHost.status.stringValue="应用活动：\(NSApp.isActive) · 输入源：\(input)"
  }
}

@main
struct ValidationHost {
  static var window: NSWindow!
  static var text: NSTextView!
  static var status: NSTextField!
  static let actions=ValidationActions()
  static func main() {
    let app=NSApplication.shared
    app.setActivationPolicy(.regular)
    window=NSWindow(contentRect:NSRect(x:0,y:0,width:1000,height:450),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
    window.title="Rime-Jev 输入验收"
    let content=NSView(frame:window.contentView!.bounds)
    let button=NSButton(title:"连接鼠须管·Jev",target:actions,action:#selector(ValidationActions.connect))
    button.frame=NSRect(x:20,y:400,width:180,height:30)
    button.autoresizingMask=[.minYMargin]
    content.addSubview(button)
    status=NSTextField(labelWithString:"")
    status.frame=NSRect(x:220,y:405,width:750,height:24)
    status.autoresizingMask=[.width,.minYMargin]
    content.addSubview(status)
    let scroll=NSScrollView(frame:NSRect(x:0,y:0,width:1000,height:390))
    scroll.autoresizingMask=[.width,.height];scroll.hasVerticalScroller=true
    text=NSTextView(frame:scroll.bounds)
    text.autoresizingMask=[.width,.height];text.isRichText=false
    text.font=NSFont.systemFont(ofSize:28);text.backgroundColor=NSColor(srgbRed:0.12,green:0.12,blue:0.12,alpha:1)
    text.textColor = .white;text.insertionPointColor = .systemYellow
    text.textContainerInset=NSSize(width:24,height:24)
    scroll.documentView=text;content.addSubview(scroll);window.contentView=content
    let menu=NSMenu()
    let editItem=NSMenuItem(title:"编辑",action:nil,keyEquivalent:"")
    let edit=NSMenu(title:"编辑")
    edit.addItem(withTitle:"全选",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
    edit.addItem(withTitle:"复制",action:#selector(NSText.copy(_:)),keyEquivalent:"c")
    edit.addItem(withTitle:"粘贴",action:#selector(NSText.paste(_:)),keyEquivalent:"v")
    editItem.submenu=edit;menu.addItem(editItem);app.mainMenu=menu
    window.center();window.makeKeyAndOrderFront(nil);window.makeFirstResponder(text)
    app.activate(ignoringOtherApps:true)
    Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { _ in actions.update() }
    app.run()
  }
}
