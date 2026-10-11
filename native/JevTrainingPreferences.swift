import AppKit
import Darwin
import UniformTypeIdentifiers

enum JevTrainingPreferencesValidation {
  static let bytesPerMB: Int64 = 1_048_576

  static func maximumBytes(_ text: String) -> Int64? {
    guard let value = Double(text.trimmingCharacters(in: .whitespacesAndNewlines)),
          value.isFinite, (1...102_400).contains(value) else { return nil }
    return Int64(value * Double(bytesPerMB))
  }

  static func directoryURL(_ path: String) -> URL? {
    let expanded = (path as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/"), !expanded.contains("\0") else { return nil }
    return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
  }

  static func mayCreateDefaultDirectory(_ path: String, explicitlyEnabling: Bool) -> Bool {
    explicitlyEnabling && path == JevTrainingSettings().directory
  }

  static func writableDirectory(_ path: String, createDefaultDirectory: Bool = false) -> String? {
    guard let directory = directoryURL(path) else { return "请选择有效的本地文件夹。" }
    var isDirectory: ObjCBool = false
    let files = FileManager.default
    if !files.fileExists(atPath: directory.path),
       mayCreateDefaultDirectory(path, explicitlyEnabling: createDefaultDirectory) {
      do {
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
      } catch { return "无法创建默认采集文件夹；采集不会开启，请检查权限。" }
    }
    guard files.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      return "文件夹不存在；请在选择窗口中创建或选择现有文件夹。"
    }
    let probe = directory.appendingPathComponent(".jev-write-probe-" + UUID().uuidString)
    do {
      // Only this fixed marker is written; never use captured text to probe permissions.
      try Data([0x4a]).write(to: probe, options: .withoutOverwriting)
      try files.removeItem(at: probe)
      return nil
    } catch {
      try? files.removeItem(at: probe)
      return "文件夹不可写或无法清理检查文件；采集不会开启，请重新选择。"
    }
  }

  static func captureFile(_ file: URL, belongsTo directory: URL) -> Bool {
    let root = directory.standardizedFileURL.resolvingSymlinksInPath()
    let candidate = file.standardizedFileURL
    guard candidate.isFileURL, candidate.pathExtension == "rjcapture",
          candidate.deletingLastPathComponent().resolvingSymlinksInPath() == root,
          candidate.resolvingSymlinksInPath().deletingLastPathComponent() == root,
          let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
          values.isRegularFile == true, values.isSymbolicLink != true else { return false }
    return true
  }
}

private final class JevTrainingDocumentView: NSView {
  override var isFlipped: Bool { true }
}

final class JevTrainingPreferences: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
  private static var retained: JevTrainingPreferences?
  private var saved: JevTrainingSettings
  private var draft: JevTrainingSettings
  private var currentApp: String
  private let projectRoot: String
  private var onSave: (JevTrainingSettings) -> Void
  private let worker = DispatchQueue(label: "im.lynx.rimejev.training-preferences", qos: .userInitiated)
  private var busy = false
  private var timer: Timer?
  private var previewWindow: NSWindow?
  private var appNames: [String: String] = [:]
  private var controls: [NSControl] = []
  private let master = NSButton(checkboxWithTitle: "启用训练数据采集", target: nil, action: nil)
  private let directory = NSTextField(wrappingLabelWithString: "")
  private let tokenizer = NSTextField(wrappingLabelWithString: "")
  private let scope = NSPopUpButton()
  private let apps = NSTableView()
  private let scopeHint = NSTextField(wrappingLabelWithString: "")
  private let context = NSButton(checkboxWithTitle: "包含上下文", target: nil, action: nil)
  private let models = NSButton(checkboxWithTitle: "包含模型结果", target: nil, action: nil)
  private let maximum = NSTextField(string: "")
  private let liveStatus = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let progress = NSProgressIndicator()
  private let removeApp = NSButton()
  private let addCurrent = NSButton()

  static func show(settings: JevTrainingSettings, currentApp: String, projectRoot: String,
                   onSave: @escaping (JevTrainingSettings) -> Void) {
    if let controller = retained, controller.window?.isVisible == true || controller.busy {
      controller.currentApp = currentApp
      controller.onSave = onSave
      controller.updateControls()
      controller.refreshStatus()
      controller.showWindow(nil)
    } else {
      let controller = JevTrainingPreferences(settings: settings, currentApp: currentApp,
                                               projectRoot: projectRoot, onSave: onSave)
      retained = controller
      controller.showWindow(nil)
      // Persist the default off state through the owner's settings callback.
      if !settings.enabled { onSave(settings) }
      controller.refreshStatus()
    }
    NSApp.activate(ignoringOtherApps: true)
  }

  private init(settings: JevTrainingSettings, currentApp: String, projectRoot: String,
               onSave: @escaping (JevTrainingSettings) -> Void) {
    saved = settings; draft = settings; self.currentApp = currentApp
    self.projectRoot = projectRoot; self.onSave = onSave
    let available = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1000, height: 850)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(680, available.width - 60),
                                             height: min(760, available.height - 90)),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.title = "鼠须管 Jev · 训练数据"
    window.minSize = NSSize(width: 560, height: 500)
    window.maxSize = NSSize(width: 900, height: 1000)
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    buildUI()
    syncFields()
    window.center()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
      guard self?.window?.isVisible == true else { return }
      self?.refreshStatus()
    }
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
  deinit { timer?.invalidate() }

  private func button(_ title: String, _ action: Selector, existing: NSButton? = nil) -> NSButton {
    let result = existing ?? NSButton()
    result.title = title; result.target = self; result.action = action; result.bezelStyle = .rounded
    result.setAccessibilityLabel(title)
    controls.append(result)
    return result
  }

  private func row(_ views: [NSView]) -> NSStackView {
    let result = NSStackView(views: views)
    result.orientation = .horizontal; result.alignment = .centerY; result.spacing = 8
    return result
  }

  private func buildUI() {
    guard let root = window?.contentView else { return }
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
    scroll.drawsBackground = false; scroll.translatesAutoresizingMaskIntoConstraints = false
    let document = JevTrainingDocumentView()
    document.translatesAutoresizingMaskIntoConstraints = false
    let content = NSStackView()
    content.orientation = .vertical; content.alignment = .leading; content.spacing = 12
    content.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(content); scroll.documentView = document; root.addSubview(scroll)
    func add(_ view: NSView) {
      content.addArrangedSubview(view)
      view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    func label(_ text: String) { add(NSTextField(wrappingLabelWithString: text)) }
    func heading(_ text: String) {
      let field = NSTextField(labelWithString: text); field.font = .boldSystemFont(ofSize: 13); add(field)
    }
    master.target = self; master.action = #selector(masterChanged)
    controls.append(master); add(master)
    label("默认关闭。仅在明确启用后采集；原始数据加密保存在本机。此设置不改变输入增强。")
    add(liveStatus)
    heading("采集文件夹")
    directory.isSelectable = true; directory.setAccessibilityLabel("采集文件夹路径"); add(directory)
    add(row([button("选择文件夹…", #selector(chooseDirectory)), button("在 Finder 中打开", #selector(revealDirectory))]))
    label("默认文件夹仅在启用并保存时创建；自选文件夹须已存在且可写。")
    heading("应用范围")
    scope.addItems(withTitles: ["仅所选应用", "所有应用，排除所列"])
    scope.target = self; scope.action = #selector(scopeChanged); scope.setAccessibilityLabel("训练数据采集范围")
    controls.append(scope); add(scope); add(scopeHint)
    for (identifier, title, width) in [("name", "应用", 180.0), ("bundle", "应用标识（Bundle ID）", 390.0)] {
      let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
      column.title = title; column.width = width; column.isEditable = false; apps.addTableColumn(column)
    }
    apps.dataSource = self; apps.delegate = self; apps.rowHeight = 26
    apps.allowsMultipleSelection = true; apps.usesAlternatingRowBackgroundColors = true
    apps.setAccessibilityLabel("采集范围应用列表")
    let appScroll = NSScrollView()
    appScroll.borderType = .bezelBorder; appScroll.hasVerticalScroller = true; appScroll.hasHorizontalScroller = true
    appScroll.documentView = apps; appScroll.heightAnchor.constraint(equalToConstant: 146).isActive = true; add(appScroll)
    add(row([button("添加应用…", #selector(chooseApps)), button("添加当前应用", #selector(addCurrentApp), existing: addCurrent),
             button("移除所选", #selector(removeSelectedApps), existing: removeApp)]))
    heading("记录内容与容量")
    controls.append(contentsOf: [context, models, maximum])
    add(row([context, models]))
    maximum.widthAnchor.constraint(equalToConstant: 110).isActive = true
    maximum.setAccessibilityLabel("容量上限，单位 MB")
    add(row([NSTextField(labelWithString: "容量上限"), maximum, NSTextField(labelWithString: "MB")]))
    label("1–102400 MB（100 GB；1 MB = 1024² 字节）。达到上限后停止写入。")
    heading("本地分词器（可选）")
    tokenizer.isSelectable = true; tokenizer.setAccessibilityLabel("本地分词器路径"); add(tokenizer)
    add(row([button("选择分词器…", #selector(chooseTokenizer)), button("清除分词器", #selector(clearTokenizer))]))
    label("不配置也可导出 records/ 和 sft/；配置本地分词器后可导出官方 prompt / completion 格式并校验 token 数。不会下载或联网。")
    heading("查看与导出")
    label("下列操作使用已保存的配置。预览会在窗口内解密最多 20 条记录。导出是明文，请审阅后再自行使用或分享。预览、导出与删除前会关闭采集，完成或取消后仍保持关闭。")
    add(row([button("预览 20 条…", #selector(preview)), button("导出…", #selector(exportRecords)),
             button("删除采集文件…", #selector(deleteFiles))]))
    progress.style = .spinning; progress.controlSize = .small
    progress.isIndeterminate = true; progress.isDisplayedWhenStopped = false
    message.font = .systemFont(ofSize: 12); message.setAccessibilityLabel("训练数据操作结果")
    let feedback = row([progress, message]); feedback.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(feedback)
    let footer = row([button("保存设置", #selector(save)), button("关闭", #selector(closeWindow))])
    footer.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(footer)
    NSLayoutConstraint.activate([
      scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      scroll.topAnchor.constraint(equalTo: root.topAnchor), scroll.bottomAnchor.constraint(equalTo: feedback.topAnchor, constant: -12),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 20),
      content.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -20),
      content.topAnchor.constraint(equalTo: document.topAnchor, constant: 20),
      content.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20),
      feedback.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      feedback.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
      feedback.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
      footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
      progress.widthAnchor.constraint(equalToConstant: 16), progress.heightAnchor.constraint(equalToConstant: 16)
    ])
  }

  private var listedApps: [String] {
    get { draft.scope == "allExceptExcluded" ? draft.excludedApps : draft.includedApps }
    set {
      if draft.scope == "allExceptExcluded" { draft.excludedApps = newValue }
      else { draft.includedApps = newValue }
    }
  }

  private func syncFields() {
    master.state = draft.enabled ? .on : .off
    directory.stringValue = draft.directory
    tokenizer.stringValue = draft.tokenizerDirectory ?? "未配置（仍可导出 records / sft）"
    scope.selectItem(at: draft.scope == "allExceptExcluded" ? 1 : 0)
    context.state = draft.includeContext ? .on : .off; models.state = draft.includeModels ? .on : .off
    maximum.stringValue = String(Double(draft.maximumBytes) / Double(JevTrainingPreferencesValidation.bytesPerMB))
    apps.reloadData(); updateControls(); refreshScopeHint()
    message.stringValue = saved.enabled ? "修改后请保存。取消勾选会立即关闭采集。" : "采集已关闭。勾选启用并保存后才会开始。"
  }

  private func refreshScopeHint() {
    if draft.scope == "selected" {
      scopeHint.stringValue = listedApps.isEmpty ? "包含名单为空：可保存，但不能采集。" : "列表为包含名单，只采集所列应用。"
    } else {
      scopeHint.stringValue = "列表为排除名单；未列出的应用均在采集范围内。请谨慎启用。"
    }
  }

  private func refreshStatus() {
    let status = JevTrainingStore.shared.status()
    let states = ["off": "关闭", "ready": "就绪", "paused": "暂停", "stopping": "正在停止／切换配置"]
    let reasons = ["disabled": "采集未开启", "invalid_configuration": "配置无效", "unsafe_directory": "目录不可用或权限不符合要求",
                   "directory_changed": "目录已变更", "unsafe_file": "采集文件不符合读取要求", "key_unavailable": "加密密钥不可用",
                   "crypto_failed": "加密失败", "quota_exceeded": "已达容量上限", "storage_failed": "写入失败",
                   "read_failed": "读取失败", "invalid_envelope": "采集文件格式无效", "authentication_failed": "采集文件无法通过解密校验",
                   "trash_failed": "无法移到废纸篓", "off_main_required": "操作需要在后台执行", "superseded": "配置已更新"]
    let reason = status.reason.isEmpty ? "" : (reasons[status.reason] ?? "存储暂不可用") + "\n"
    liveStatus.stringValue = "采集\(saved.enabled ? "已启用" : "已关闭") · 状态：\(states[status.state] ?? "未知")\n\(reason)本次启动：已写入 \(status.written) · 已丢弃 \(status.dropped) · 最后观测占用 \(ByteCountFormatter.string(fromByteCount: Int64(status.bytes), countStyle: .file))"
    if saved.scope == "selected", saved.includedApps.isEmpty {
      liveStatus.stringValue += "\n包含名单为空，当前无法采集。"
    }
  }

  private func updateControls() {
    for control in controls { control.isEnabled = !busy }
    apps.isEnabled = !busy
    addCurrent.isEnabled = !busy && !currentApp.isEmpty
    removeApp.isEnabled = !busy && apps.selectedRow >= 0
  }

  private func setBusy(_ value: Bool, message text: String? = nil) {
    busy = value; updateControls()
    if value { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    if let text { message.stringValue = text }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool { !busy }
  func windowWillClose(_ notification: Notification) {
    timer?.invalidate(); timer = nil
    previewWindow?.close(); previewWindow = nil
  }
  @objc private func closeWindow() { window?.performClose(nil) }

  private func pauseCapture(_ reason: String) {
    saved.enabled = false; draft.enabled = false; master.state = .off
    onSave(saved)
    message.stringValue = reason + "；采集已关闭，操作后不会自动恢复。"
    refreshStatus()
  }

  @objc private func masterChanged() {
    draft.enabled = master.state == .on
    if draft.enabled { message.stringValue = "尚未启用：保存时会检查文件夹与容量。" }
    else { pauseCapture("已关闭采集") }
  }

  @objc private func save() {
    guard !busy else { return }
    guard let bytes = JevTrainingPreferencesValidation.maximumBytes(maximum.stringValue) else {
      message.stringValue = "容量请输入 1–102400 MB 之间的有效数字。"; return
    }
    draft.maximumBytes = bytes; draft.includeContext = context.state == .on; draft.includeModels = models.state == .on
    draft.enabled = master.state == .on
    let candidate = draft
    setBusy(true, message: "正在检查设置…")
    worker.async { [weak self] in
      let error = candidate.enabled ? JevTrainingPreferencesValidation.writableDirectory(candidate.directory, createDefaultDirectory: true) : nil
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.setBusy(false)
        if let error {
          self.pauseCapture("无法启用")
          self.message.stringValue = error
          return
        }
        self.saved = candidate; self.onSave(candidate); self.refreshStatus()
        self.message.stringValue = candidate.enabled ? "已保存并启用。" : "已保存，采集保持关闭。"
        if candidate.scope == "selected", candidate.includedApps.isEmpty {
          self.message.stringValue += " 包含名单为空，不能采集。"
        }
      }
    }
  }

  private func folderPanel(_ prompt: String) -> NSOpenPanel {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.canCreateDirectories = true; panel.allowsMultipleSelection = false; panel.prompt = prompt
    return panel
  }

  @objc private func chooseDirectory() {
    guard !busy, let window else { return }
    let panel = folderPanel("选择采集文件夹")
    panel.directoryURL = JevTrainingPreferencesValidation.directoryURL(draft.directory)
    setBusy(true)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else { self.setBusy(false); return }
      self.draft.directory = url.path; self.directory.stringValue = url.path
      self.message.stringValue = "正在检查所选文件夹…"
      self.worker.async { [weak self] in
        let error = JevTrainingPreferencesValidation.writableDirectory(url.path)
        DispatchQueue.main.async { [weak self] in
          self?.setBusy(false, message: error ?? "文件夹可写；保存后生效。")
        }
      }
    }
  }

  @objc private func revealDirectory() {
    guard let url = JevTrainingPreferencesValidation.directoryURL(draft.directory),
          NSWorkspace.shared.open(url) else { message.stringValue = "无法打开该文件夹，请检查路径。"; return }
  }

  @objc private func chooseTokenizer() {
    guard !busy, let window else { return }
    let panel = folderPanel("选择本地分词器")
    panel.canCreateDirectories = false
    if let path = draft.tokenizerDirectory { panel.directoryURL = JevTrainingPreferencesValidation.directoryURL(path) }
    setBusy(true)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      if response == .OK, let url = panel.url {
        self.draft.tokenizerDirectory = url.path; self.tokenizer.stringValue = url.path
        self.message.stringValue = "已选择本地分词器，保存后用于导出。"
      }
      self.setBusy(false)
    }
  }
  @objc private func clearTokenizer() {
    draft.tokenizerDirectory = nil; tokenizer.stringValue = "未配置（仍可导出 records / sft）"
    message.stringValue = "已清除分词器选择，保存后生效。"
  }
  @objc private func scopeChanged() {
    draft.scope = scope.indexOfSelectedItem == 1 ? "allExceptExcluded" : "selected"
    apps.deselectAll(nil); apps.reloadData(); refreshScopeHint(); updateControls()
    message.stringValue = "应用范围已修改，保存后生效。"
  }
  private func addApps(_ identifiers: [String]) {
    var values = listedApps
    for identifier in identifiers where !identifier.isEmpty && !values.contains(identifier) { values.append(identifier) }
    listedApps = values; apps.reloadData(); refreshScopeHint(); updateControls()
    message.stringValue = "应用名单已修改，保存后生效。"
  }
  @objc private func addCurrentApp() { addApps([currentApp]) }
  @objc private func removeSelectedApps() {
    let selected = apps.selectedRowIndexes
    listedApps = listedApps.enumerated().filter { !selected.contains($0.offset) }.map(\.element)
    apps.deselectAll(nil); apps.reloadData(); refreshScopeHint(); updateControls()
    message.stringValue = "应用名单已修改，保存后生效。"
  }
  @objc private func chooseApps() {
    guard !busy, let window else { return }
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
    panel.canChooseFiles = true; panel.allowsMultipleSelection = true; panel.treatsFilePackagesAsDirectories = false
    panel.prompt = "添加应用"; panel.directoryURL = URL(fileURLWithPath: "/Applications")
    setBusy(true)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      self.setBusy(false)
      guard response == .OK else { return }
      let identifiers = panel.urls.compactMap { url -> String? in
        guard url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier, !id.isEmpty else { return nil }
        self.appNames[id] = FileManager.default.displayName(atPath: url.path)
        return id
      }
      self.addApps(identifiers)
      if identifiers.count != panel.urls.count { self.message.stringValue = "部分应用没有有效的 Bundle ID，未加入；其余更改请保存。" }
    }
  }
  func numberOfRows(in tableView: NSTableView) -> Int { listedApps.count }
  func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
    guard listedApps.indices.contains(row) else { return nil }
    let identifier = listedApps[row]
    if tableColumn?.identifier.rawValue == "bundle" { return identifier }
    if let name = appNames[identifier] { return name }
    let name = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).first?.localizedName
      ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map { FileManager.default.displayName(atPath: $0.path) }
      ?? "未安装或未知应用"
    appNames[identifier] = name
    return name
  }
  func tableViewSelectionDidChange(_ notification: Notification) { updateControls() }

  private enum ReadStop: Error { case previewLimit }
  @objc private func preview() {
    guard !busy, let directory = JevTrainingPreferencesValidation.directoryURL(saved.directory) else { return }
    pauseCapture("准备预览")
    setBusy(true, message: "正在本机解密预览（最多 20 条）；采集已关闭…")
    worker.async { [weak self] in
      JevTrainingStore.shared.drain()
      var records: [String] = []
      var failed = false
      do {
        try JevTrainingStore.shared.readRecords(in: directory) { data in
          let limit = 32_768
          let text = String(decoding: data.prefix(limit), as: UTF8.self)
          records.append(text + (data.count > limit ? "\n［本条预览已截断］" : ""))
          if records.count == 20 { throw ReadStop.previewLimit }
        }
      } catch ReadStop.previewLimit {} catch { failed = records.count != 20 }
      let content = records.joined(separator: "\n\n")
      let count = records.count, readFailed = failed
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.setBusy(false)
        if readFailed { self.message.stringValue = "预览失败：无法读取或解密采集文件。采集保持关闭。"; return }
        self.showPreview(content.isEmpty ? "暂无可预览的记录。" : content)
        self.message.stringValue = "已预览 \(count) 条；未创建明文文件。采集保持关闭。"
      }
    }
  }

  private func showPreview(_ text: String) {
    previewWindow?.close()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.title = "训练数据预览 · 最多 20 条"; window.isReleasedWhenClosed = false
    window.minSize = NSSize(width: 480, height: 320); window.maxSize = NSSize(width: 1000, height: 800)
    let scroll = NSScrollView(frame: window.contentView!.bounds)
    scroll.autoresizingMask = [.width, .height]; scroll.hasVerticalScroller = true
    let view = NSTextView(frame: scroll.bounds)
    view.isEditable = false; view.isSelectable = true; view.isRichText = false
    view.isAutomaticLinkDetectionEnabled = false
    view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
    view.textContainerInset = NSSize(width: 12, height: 12)
    view.isVerticallyResizable = true; view.isHorizontallyResizable = false
    view.autoresizingMask = [.width]; view.textContainer?.widthTracksTextView = true
    view.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: .greatestFiniteMagnitude)
    view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    view.string = text; view.setAccessibilityLabel("已解密训练记录，只读预览")
    scroll.documentView = view; window.contentView?.addSubview(scroll)
    previewWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
  }

  @objc private func exportRecords() {
    guard !busy, let window else { return }
    pauseCapture("准备导出明文")
    let panel = folderPanel("选择导出位置")
    panel.message = "将在此处新建独立导出文件夹。明文导出请先审阅；采集保持关闭。"
    setBusy(true)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      guard response == .OK, let parent = panel.url else { self.setBusy(false, message: "已取消导出；采集保持关闭。"); return }
      let settings = self.saved, projectRoot = self.projectRoot
      self.message.stringValue = "正在本机导出明文；采集已关闭…"
      self.worker.async { [weak self] in
        let result = Self.runExport(settings: settings, projectRoot: projectRoot, parent: parent)
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.setBusy(false, message: result); self.refreshStatus()
        }
      }
    }
  }

  private static func runExport(settings: JevTrainingSettings, projectRoot: String, parent: URL) -> String {
    JevTrainingStore.shared.drain()
    guard let source = JevTrainingPreferencesValidation.directoryURL(settings.directory),
          JevTrainingPreferencesValidation.writableDirectory(parent.path) == nil else {
      return "导出位置不可写；未导出，采集保持关闭。"
    }
    let root = URL(fileURLWithPath: projectRoot, isDirectory: true)
    let python = root.appendingPathComponent(".venv/bin/python"), script = root.appendingPathComponent("scripts/export_training.py")
    guard FileManager.default.isExecutableFile(atPath: python.path), FileManager.default.fileExists(atPath: script.path) else {
      return "本地导出工具未就绪；请检查项目环境。采集保持关闭。"
    }
    let timestamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let output = parent.appendingPathComponent("Jev-training-\(timestamp)-\(UUID().uuidString)", isDirectory: true)
    let process = Process(), input = Pipe(), result = Pipe()
    process.executableURL = python; process.currentDirectoryURL = root
    process.arguments = [script.path, "--input", "-", "--output", output.path]
    if let tokenizer = settings.tokenizerDirectory, !tokenizer.isEmpty {
      process.arguments! += ["--tokenizer", tokenizer]
    }
    var environment = ProcessInfo.processInfo.environment
    environment["HF_HUB_OFFLINE"] = "1"; environment["TRANSFORMERS_OFFLINE"] = "1"
    environment["HF_DATASETS_OFFLINE"] = "1"; environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
    environment["PYTHONPATH"] = root.appendingPathComponent("src").path
    process.environment = environment
    process.standardInput = input; process.standardOutput = result; process.standardError = FileHandle.nullDevice
    // A failed exporter must become an error, never SIGPIPE in the input-method host.
    guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
      return "无法准备本地导出管道；采集保持关闭。"
    }
    do { try process.run() } catch { return "无法启动本地导出工具；采集保持关闭。" }
    try? input.fileHandleForReading.close(); try? result.fileHandleForWriting.close()
    let drain = DispatchGroup()
    drain.enter()
    DispatchQueue.global(qos: .utility).async {
      // Do not display exporter output: a traceback or library message may contain a record.
      while let chunk = try? result.fileHandleForReading.read(upToCount: 8192), !chunk.isEmpty {}
      try? result.fileHandleForReading.close(); drain.leave()
    }
    var count = 0, failed = false
    do {
      try JevTrainingStore.shared.readRecords(in: source) { record in
        try input.fileHandleForWriting.write(contentsOf: record)
        if record.last != 0x0a { try input.fileHandleForWriting.write(contentsOf: Data([0x0a])) }
        count += 1
      }
    } catch { failed = true }
    try? input.fileHandleForWriting.close()
    if failed, process.isRunning { process.terminate() }
    process.waitUntilExit(); drain.wait()
    guard !failed, process.terminationReason == .exit, process.terminationStatus == 0 else {
      return "导出失败（退出码 \(process.terminationStatus)）；目标位置可能有部分明文文件，请检查。采集保持关闭。"
    }
    var summary = "已传入 \(count) 条记录。"
    if let manifest = try? FileHandle(forReadingFrom: output.appendingPathComponent("manifest.json")) {
      defer { try? manifest.close() }
      if let data = try? manifest.read(upToCount: 65_536),
         let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let exported = object["exported_examples"] as? Int, exported >= 0,
         let conflicts = object["conflicting_examples"] as? Int, conflicts >= 0 {
        summary += " 合格样本 \(exported)，冲突样本 \(conflicts)。"
      }
    }
    return "导出完成（退出码 0）：\(summary)\n\(output.path)\n明文请先审阅；采集保持关闭。"
  }

  @objc private func deleteFiles() {
    guard !busy, let window, let directory = JevTrainingPreferencesValidation.directoryURL(saved.directory) else { return }
    pauseCapture("准备删除采集文件")
    let panel = NSOpenPanel()
    panel.directoryURL = directory; panel.canChooseFiles = true; panel.canChooseDirectories = false
    panel.allowsMultipleSelection = true; panel.resolvesAliases = false
    panel.allowedContentTypes = [UTType(filenameExtension: "rjcapture") ?? .data]
    panel.prompt = "选择待删除文件"; panel.message = "仅接受已保存采集文件夹中的 .rjcapture 文件；下一步确认移到废纸篓。"
    setBusy(true)
    panel.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      guard response == .OK, !panel.urls.isEmpty else { self.setBusy(false, message: "已取消删除；采集保持关闭。"); return }
      let selected = panel.urls
      self.worker.async { [weak self] in
        JevTrainingStore.shared.drain()
        let available = try? JevTrainingStore.shared.listFiles(in: directory)
        let valid = available.map { files in
          selected.allSatisfy { candidate in
            JevTrainingPreferencesValidation.captureFile(candidate, belongsTo: directory) &&
              files.contains { $0.standardizedFileURL.resolvingSymlinksInPath() == candidate.standardizedFileURL.resolvingSymlinksInPath() }
          }
        } ?? false
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          guard valid else { self.setBusy(false, message: "所选文件不在已保存的采集文件夹内，或无法读取；未删除。采集保持关闭。"); return }
          self.confirmTrash(selected, directory: directory)
        }
      }
    }
  }

  private func confirmTrash(_ files: [URL], directory: URL) {
    guard let window else { setBusy(false); return }
    let alert = NSAlert()
    alert.messageText = "将 \(files.count) 个采集文件移到废纸篓？"
    alert.informativeText = "仅处理已保存采集文件夹中的所选文件。可以从 Finder 废纸篓恢复；采集将保持关闭。"
    alert.alertStyle = .warning; alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self else { return }
      guard response == .alertSecondButtonReturn else { self.setBusy(false, message: "已取消删除；采集保持关闭。"); return }
      self.message.stringValue = "正在移到废纸篓；采集保持关闭…"
      self.worker.async { [weak self] in
        JevTrainingStore.shared.drain()
        var succeeded = false
        do {
          guard files.allSatisfy({ JevTrainingPreferencesValidation.captureFile($0, belongsTo: directory) }) else {
            throw CocoaError(.fileReadNoPermission)
          }
          try JevTrainingStore.shared.trashFiles(files, in: directory); succeeded = true
        } catch {}
        let result = succeeded
        DispatchQueue.main.async { [weak self] in
          self?.setBusy(false, message: result ? "已将 \(files.count) 个文件移到废纸篓，可在 Finder 恢复。采集保持关闭。" : "删除未全部完成；请检查原文件夹和废纸篓。采集保持关闭。")
          self?.refreshStatus()
        }
      }
    }
  }
}
