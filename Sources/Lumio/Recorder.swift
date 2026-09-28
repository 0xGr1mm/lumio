import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers
import Carbon

struct RecorderPreferences: Codable {
    var fps = 60
    var retina = true
    var showCursor = true
    var hideLumio = true
    var includeMenuBar = true
    var countdown = 3
    var screenshotCursor = false
    var copyScreenshot = false
    var revealExport = true
    var folderPath = ""
    var hevc: Bool? = nil
    var hideDesktopIcons: Bool? = nil
    var folder: URL { folderPath.isEmpty ? FileManager.default.urls(for:.moviesDirectory,in:.userDomainMask)[0].appendingPathComponent("Lumio") : URL(fileURLWithPath:folderPath) }
    func normalized()->RecorderPreferences {
        var value=self
        if ![30,60].contains(value.fps){value.fps=60}
        if ![0,3,5,10].contains(value.countdown){value.countdown=3}
        value.folderPath=String(value.folderPath.prefix(4_096))
        return value
    }
}

@MainActor final class AppCoordinator: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let studio = Studio()
    var recorder: NSPanel!
    var editor: NSWindow?
    var settings: NSWindow?
    var selection: NSPanel?
    var cameraPanel: NSPanel?
    var statusItem: NSStatusItem?
    var hotKeys: RecordingHotKeys?
    var keyMonitor: Any?
    func applicationDidFinishLaunching(_ notification:Notification) {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify" {
            Task { await verifyLumio(folder:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-effects" {
            Task { await verifyEffectsOnly(folder:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-privacy" {
            Task { await verifyPrivacyOnly(folder:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-transparent" {
            Task { await verifyTransparentExport(video:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-camera" {
            Task { await verifyCameraBackground(video:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify-transcription" {
            Task { await verifyTranscription(audio:URL(fileURLWithPath:CommandLine.arguments[2])) }
            return
        }
        if Bundle.main.bundleURL.pathExtension != "app" {
            NSWorkspace.shared.openApplication(at:URL(fileURLWithPath:"/Applications/Lumio.app"),configuration:NSWorkspace.OpenConfiguration())
            NSApp.terminate(nil);return
        }
        NSApp.setActivationPolicy(.regular)
        if let icon=Bundle.main.url(forResource:"Lumio",withExtension:"icns") { NSApp.applicationIconImage=NSImage(contentsOf:icon) }
        if let data = UserDefaults.standard.data(forKey:"recorder"), let prefs = try? JSONDecoder().decode(RecorderPreferences.self,from:data) { studio.preferences = prefs.normalized() }
        if let data = UserDefaults.standard.data(forKey:"defaultLook"), let look = try? JSONDecoder().decode(Look.self,from:data) { studio.look = look.normalized() }
        studio.onOpenEditor = { [weak self] in self?.showEditor() }
        studio.onShowRecorder = { [weak self] in self?.showRecorder() }
        studio.onShowSettings = { [weak self] in self?.showSettings() }
        studio.onSelectArea = { [weak self] in self?.selectArea() }
        studio.onCameraPreviewChanged = { [weak self] visible in self?.setCameraPreview(visible) }
        recorder = NSPanel(contentRect:NSRect(x:0,y:0,width:1110,height:88),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        recorder.isFloatingPanel = true; recorder.level = .floating; recorder.isOpaque = false; recorder.backgroundColor = .clear
        recorder.hasShadow = true; recorder.isMovableByWindowBackground = true; recorder.hidesOnDeactivate = false
        recorder.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        recorder.contentView = NSHostingView(rootView:RecorderBar(studio:studio))
        recorder.isReleasedWhenClosed = false
        statusItem = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName:"record.circle",accessibilityDescription:"Lumio")
        statusItem?.button?.target = self; statusItem?.button?.action = #selector(statusPressed)
        installMenu()
        installEditorKeys()
        allowScreenCaptureDevices()
        hotKeys = RecordingHotKeys([
            HotKey(id:1,keyCode:UInt32(kVK_ANSI_R),modifiers:UInt32(controlKey|optionKey),name:"⌃⌥R") { [weak self] in self?.studio.toggleRetake() },
            HotKey(id:2,keyCode:UInt32(kVK_ANSI_S),modifiers:UInt32(controlKey|optionKey),name:"⌃⌥S") { [weak self] in Task { await self?.studio.stopRecording() } },
            HotKey(id:3,keyCode:UInt32(kVK_ANSI_P),modifiers:UInt32(controlKey|optionKey),name:"⌃⌥P") { [weak self] in self?.studio.togglePause() }
        ])
        studio.onRecordingStateChanged = { [weak self] enabled in
            guard let self else{return}
            let unavailable = self.hotKeys?.setEnabled(enabled) ?? []
            if enabled && !unavailable.isEmpty { self.studio.message = "Another app already uses \(unavailable.joined(separator:", ")). Use the buttons in the recording bar instead." }
        }
        showRecorder()
    }
    func installMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); menu.addItem(app)
        let submenu = NSMenu(); app.submenu = submenu
        let capture = NSMenuItem(title:"Recording Bar",action:#selector(statusPressed),keyEquivalent:"r"); capture.target = self; submenu.addItem(capture)
        let setting = NSMenuItem(title:"Settings…",action:#selector(settingsPressed),keyEquivalent:","); setting.target = self; submenu.addItem(setting)
        submenu.addItem(.separator()); submenu.addItem(withTitle:"Quit Lumio",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        // Text fields need a real Edit menu for copy, paste, select all and text undo.
        let editItem = NSMenuItem(); menu.addItem(editItem)
        let edit = NSMenu(title:"Edit"); editItem.submenu = edit
        let undo = NSMenuItem(title:"Undo",action:#selector(undoPressed(_:)),keyEquivalent:"z"); undo.target = self; edit.addItem(undo)
        let redo = NSMenuItem(title:"Redo",action:#selector(redoPressed(_:)),keyEquivalent:"z"); redo.keyEquivalentModifierMask = [.command,.shift]; redo.target = self; edit.addItem(redo)
        edit.addItem(.separator())
        // Cut, Copy, Paste and Duplicate act on text while editing a field, otherwise on the selected timeline item.
        let cut = NSMenuItem(title:"Cut",action:#selector(cutPressed(_:)),keyEquivalent:"x"); cut.target = self; edit.addItem(cut)
        let copy = NSMenuItem(title:"Copy",action:#selector(copyPressed(_:)),keyEquivalent:"c"); copy.target = self; edit.addItem(copy)
        let paste = NSMenuItem(title:"Paste",action:#selector(pastePressed(_:)),keyEquivalent:"v"); paste.target = self; edit.addItem(paste)
        let duplicate = NSMenuItem(title:"Duplicate",action:#selector(duplicatePressed(_:)),keyEquivalent:"d"); duplicate.target = self; edit.addItem(duplicate)
        edit.addItem(withTitle:"Select All",action:#selector(NSText.selectAll(_:)),keyEquivalent:"a")
        let windowItem = NSMenuItem(); menu.addItem(windowItem)
        let window = NSMenu(title:"Window"); windowItem.submenu = window
        window.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        window.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        NSApp.mainMenu = menu; NSApp.windowsMenu = window
    }
    var editingText: Bool { NSApp.keyWindow?.firstResponder is NSText }
    @objc func undoPressed(_ sender:Any?) {
        if editingText { NSApp.sendAction(Selector(("undo:")),to:nil,from:sender) } else if NSApp.keyWindow === editor { studio.undoEdit() }
    }
    @objc func redoPressed(_ sender:Any?) {
        if editingText { NSApp.sendAction(Selector(("redo:")),to:nil,from:sender) } else if NSApp.keyWindow === editor { studio.redoEdit() }
    }
    var timelineActive: Bool { NSApp.keyWindow === editor && !editingText }
    @objc func cutPressed(_ sender:Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.cut(_:)),to:nil,from:sender) } else if timelineActive { studio.cutTimelineSelection() }
    }
    @objc func copyPressed(_ sender:Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.copy(_:)),to:nil,from:sender) } else if timelineActive { studio.copyTimelineSelection() }
    }
    @objc func pastePressed(_ sender:Any?) {
        if editingText { NSApp.sendAction(#selector(NSText.paste(_:)),to:nil,from:sender) } else if timelineActive { studio.pasteTimelineItem() }
    }
    @objc func duplicatePressed(_ sender:Any?) { if timelineActive { studio.duplicateTimelineSelection() } }
    /// Single-key editor shortcuts run only when no text field is being edited, so typing a caption never cuts or deletes clips.
    func installEditorKeys() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.consumeEditorKey(event) ?? false }
            return handled ? nil : event
        }
    }
    func consumeEditorKey(_ event:NSEvent) -> Bool {
        guard let editor, event.window === editor, editor.attachedSheet == nil, !(editor.firstResponder is NSText), !studio.busy else { return false }
        let flags = event.modifierFlags.intersection([.command,.option,.control,.shift])
        if flags.isEmpty {
            switch event.keyCode {
            case 49: studio.togglePlay(); return true
            case 51, 117: studio.deleteTimelineSelection(); return true
            case 123: studio.stepFrame(-1); return true
            case 124: studio.stepFrame(1); return true
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "a": studio.timelineTool = "select"
            case "b", "c": studio.timelineTool = "blade"
            case "t": studio.timelineTool = "trim"
            case "p": studio.timelineTool = "position"
            case "m": studio.addMarker()
            case ",": studio.goToMarker(forward:false)
            case ".": studio.goToMarker(forward:true)
            default: return false
            }
            return true
        }
        if flags == [.option] {
            if event.keyCode == 33 { studio.trimSelectedClipToPlayhead(startEdge:true); return true }
            if event.keyCode == 30 { studio.trimSelectedClipToPlayhead(startEdge:false); return true }
        }
        return false
    }
    @objc func statusPressed() { showRecorder() }
    @objc func settingsPressed() { showSettings() }
    func showRecorder() {
        NSApp.unhide(nil)
        studio.player.pause(); studio.playing = false
        if !studio.recording { editor?.orderOut(nil) }
        let frame = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        recorder.setFrameOrigin(NSPoint(x:frame.midX - recorder.frame.width/2,y:frame.minY + 80))
        recorder.orderFrontRegardless()
        if studio.camera { Task { await studio.prepareCameraPreview() } }
    }
    func showEditor() {
        recorder.orderOut(nil)
        if !studio.recording { setCameraPreview(false); studio.cameraRecorder.stopSession() }
        if editor == nil {
            editor = NSWindow(contentRect:NSRect(x:0,y:0,width:1450,height:950),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
            editor?.title = "Lumio"; editor?.titlebarAppearsTransparent = true; editor?.isReleasedWhenClosed = false
            editor?.contentView = NSHostingView(rootView:Editor(studio:studio)); editor?.minSize = NSSize(width:1180,height:840); editor?.center(); editor?.delegate = self
        }
        NSApp.unhide(nil)
        if editor?.isMiniaturized == true { editor?.deminiaturize(nil) }
        editor?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func showSettings() {
        if settings == nil {
            settings = NSWindow(contentRect:NSRect(x:0,y:0,width:790,height:620),styleMask:[.titled,.closable],backing:.buffered,defer:false)
            settings?.title = "Lumio · Settings"; settings?.isReleasedWhenClosed = false
            settings?.contentView = NSHostingView(rootView:PreferencesView(studio:studio)); settings?.center()
        }
        settings?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func setCameraPreview(_ visible:Bool) {
        guard visible else { cameraPanel?.orderOut(nil); return }
        if cameraPanel == nil {
            let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:190,height:190),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isFloatingPanel = true; panel.level = .floating; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.hasShadow = true; panel.isMovableByWindowBackground = true; panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.isReleasedWhenClosed = false
            panel.contentView = CameraPreviewView(session:studio.cameraRecorder.session)
            let frame = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
            panel.setFrameOrigin(NSPoint(x:frame.maxX-230,y:frame.minY+40))
            cameraPanel = panel
        }
        cameraPanel?.orderFrontRegardless()
    }
    func windowWillClose(_ notification:Notification) { if let window = notification.object as? NSWindow, window === editor { studio.player.pause(); studio.playing = false; showRecorder() } }
    /// Opens recordings, images and .lumio projects dropped on the icon, double-clicked in Finder or passed to `open -a Lumio`.
    func application(_ application:NSApplication,open urls:[URL]) {
        guard let url=urls.first,!studio.recording,!studio.busy else { return }
        if url.pathExtension.lowercased() == "lumio" { studio.openProject(url) }
        else if NSImage(contentsOf:url) != nil { studio.loadImage(url) }
        else { Task { await studio.load(url) } }
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool) -> Bool {
        if studio.source != nil && !studio.recording { showEditor() } else { showRecorder() }
        return false
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        if studio.recording || studio.busy || studio.voiceoverRecording { studio.message = "Finish the active recording, voiceover or export first."; if studio.voiceoverRecording {showEditor()} else {showRecorder()}; return .terminateCancel }
        studio.cameraRecorder.stopSession()
        return .terminateNow
    }
    func selectArea() {
        guard let display = studio.displays.first(where: { $0.displayID == studio.displayID }), let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }) else { studio.message = "Choose a display before selecting an area."; return }
        studio.captureSheet = false; recorder.orderOut(nil)
        let overlay = SelectionPanel(contentRect:screen.frame,styleMask:[.borderless],backing:.buffered,defer:false)
        overlay.level = .screenSaver; overlay.isOpaque = false; overlay.backgroundColor = .clear; overlay.isReleasedWhenClosed = false
        let view = AreaSelectionView(frame:NSRect(origin:.zero,size:screen.frame.size))
        view.completed = { [weak self] rect in
            guard let self else { return }
            self.selection?.orderOut(nil); self.selection = nil
            if let rect { self.studio.area = rect; self.studio.mode = "Area" }
            self.showRecorder(); self.studio.captureSheet = true
        }
        overlay.contentView = view; selection = overlay; overlay.makeKeyAndOrderFront(nil); overlay.makeFirstResponder(view); NSApp.activate(ignoringOtherApps:true)
    }
}

extension AppCoordinator: NSMenuItemValidation {
    func validateMenuItem(_ item:NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cutPressed(_:)), #selector(copyPressed(_:)): return editingText || (timelineActive && studio.focusedTimelineItem != nil)
        case #selector(pastePressed(_:)): return editingText || (timelineActive && studio.timelineClipboard != nil)
        case #selector(duplicatePressed(_:)): return timelineActive && studio.focusedTimelineItem != nil
        default: return true
        }
    }
}

final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

final class AreaSelectionView: NSView {
    var start: NSPoint?
    var selectionRect = NSRect.zero
    var completed: ((CGRect?) -> Void)?
    override var acceptsFirstResponder:Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func mouseDown(with event:NSEvent) { start = convert(event.locationInWindow,from:nil) }
    override func mouseDragged(with event:NSEvent) {
        guard let start else { return }; let p = convert(event.locationInWindow,from:nil)
        selectionRect = NSRect(x:min(start.x,p.x),y:min(start.y,p.y),width:abs(start.x-p.x),height:abs(start.y-p.y)).intersection(bounds); needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        mouseDragged(with:event)
        guard selectionRect.width >= 16, selectionRect.height >= 16 else { return }
        completed?(CGRect(x:selectionRect.minX,y:bounds.height-selectionRect.maxY,width:selectionRect.width,height:selectionRect.height))
    }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { completed?(nil) } }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.black.withAlphaComponent(0.38).setFill(); bounds.fill()
        NSColor.clear.setFill(); selectionRect.fill(using:.copy)
        NSColor.systemGreen.setStroke(); let line = NSBezierPath(rect:selectionRect); line.lineWidth = 2; line.stroke()
        let text = selectionRect.width > 0 ? "\(Int(selectionRect.width)) × \(Int(selectionRect.height)) · Cancel: Esc" : "Drag to select the recording area · Cancel: Esc"
        (text as NSString).draw(at:NSPoint(x:bounds.midX-200,y:bounds.midY+100),withAttributes:[.font:NSFont.systemFont(ofSize:18,weight:.medium),.foregroundColor:NSColor.white])
    }
}

struct RecorderBar: View {
    @ObservedObject var studio: Studio
    @State var screenshot = false
    @State var audioDevices = false
    var body:some View {
        HStack(spacing:14) {
            Button { studio.cameraRecorder.stopSession(); studio.onCameraPreviewChanged?(false); NSApp.hide(nil) } label: { Image(systemName:"xmark.circle.fill").foregroundStyle(.gray) }.help("Hide; reopen from the menu bar")
            Divider().frame(height:34)
            if studio.recording || studio.countdownRemaining > 0 {
                Circle().fill(studio.pausedAt == nil ? Color.red : Color.orange).frame(width:10,height:10)
                TimelineView(.periodic(from:.now,by:0.5)) { _ in
                    Text(studio.countdownRemaining > 0 ? "\(studio.countdownRemaining) · Get Ready" : (studio.pausedAt == nil ? "" : "Paused · ") + stamp(studio.recordedElapsed)).monospacedDigit().frame(width:130)
                }
                if !studio.recording {
                    Spacer()
                    Button { studio.countdownCancelled = true } label: { Label("Cancel",systemImage:"xmark") }.help("Cancel before recording starts")
                } else {
                    Text(studio.mode + " Recording").foregroundStyle(.secondary)
                    Spacer()
                    Button { studio.togglePause() } label: { Label(studio.pausedAt == nil ? "Pause" : "Resume",systemImage:studio.pausedAt == nil ? "pause.fill" : "play.fill") }
                        .help("Pause or resume · ⌃⌥P · Paused time is removed from the video").disabled(studio.busy)
                    if !studio.deviceRecording {
                        Picker("Retake",selection:$studio.retakeLookback) { ForEach([5.0,10,20,30],id:\.self) { Text("Last \(Int($0)) s").tag($0) } }.frame(width:130).disabled(studio.activeRetake != nil)
                        Button { studio.toggleRetake() } label: { Label(studio.activeRetake == nil ? "Retake" : "Finish Retake",systemImage:"arrow.triangle.2.circlepath") }
                            .help("Smart Retake · ⌃⌥R · Mark the previous seconds, repeat the action, then press again to finish.").disabled(studio.busy || !studio.recording || studio.pausedAt != nil)
                        Text("\(studio.recordingRetakes.count) takes").font(.caption).foregroundStyle(.secondary)
                    }
                    Menu {
                        Button("Restart Recording") { confirmDiscard(restart:true) }
                        Button("Discard Recording",role:.destructive) { confirmDiscard(restart:false) }
                    } label: { Image(systemName:"trash") }.menuStyle(.borderlessButton).fixedSize().help("Restart or discard this recording").disabled(studio.busy)
                    Button { Task { await studio.stopRecording() } } label: { Label("Stop Recording",systemImage:"stop.fill").padding(8) }.buttonStyle(.borderedProminent).tint(.red).disabled(studio.busy).help("Stop · ⌃⌥S")
                }
            } else {
                modeButton("Screen","display")
                modeButton("Window","macwindow")
                modeButton("Area","viewfinder")
                modeButton("Device","iphone").help("Record an iPhone or iPad connected with a cable")
                Button { screenshot = true; if studio.mode == "Device" { studio.mode = "Screen" }; Task { await studio.prepareCapture() } } label: { tool("Screenshot","camera.viewfinder") }.help("Take a screenshot")
                Divider().frame(height:34)
                audioToggle("System Audio", enabled:$studio.systemAudio, on:"speaker.wave.2.fill", off:"speaker.slash.fill")
                audioToggle("Microphone", enabled:$studio.mic, on:"mic.fill", off:"mic.slash.fill")
                audioToggle("Camera", enabled:cameraBinding, on:"video.fill", off:"video.slash.fill")
                Button { audioDevices = true } label: { Image(systemName:"chevron.down").font(.system(size:11)) }.help("Choose microphone, camera and audio output")
                    .popover(isPresented:$audioDevices) { AudioDevicePanel(studio:studio) }
                Divider().frame(height:34)
                Button { studio.importVideo() } label: { Image(systemName:"folder") }.help("Open video or image")
                Button { studio.onShowSettings?() } label: { Image(systemName:"gearshape") }.help("Settings")
                if studio.source != nil { Button { studio.onOpenEditor?() } label: { Image(systemName:"rectangle.and.pencil.and.ellipsis") }.help("Return to editor") }
            }
        }.buttonStyle(.plain).font(.system(size:13,weight:.medium)).padding(.horizontal,20).frame(height:72)
        .background(RoundedRectangle(cornerRadius:16).fill(Color(white:0.13))).overlay(RoundedRectangle(cornerRadius:16).stroke(.white.opacity(0.12)))
        .padding(8).preferredColorScheme(.dark).tint(accent)
        .popover(isPresented:$studio.captureSheet,arrowEdge:.top) { targetPicker }
        .alert("Lumio",isPresented:Binding(get:{ studio.message != nil },set:{ if !$0 { studio.message = nil } })) { Button("OK") { studio.message = nil } } message: { Text(studio.message ?? "") }
    }
    var cameraBinding: Binding<Bool> {
        Binding(get:{ studio.camera },set:{ value in studio.camera = value; Task { await studio.prepareCameraPreview() } })
    }
    func confirmDiscard(restart:Bool) {
        let alert = NSAlert()
        alert.messageText = restart ? "Restart this recording?" : "Discard this recording?"
        alert.informativeText = "The current recording and its camera, pointer and keyboard data will be moved to the Trash."
        alert.addButton(withTitle:restart ? "Restart" : "Discard"); alert.addButton(withTitle:"Keep Recording")
        if alert.runModal() == .alertFirstButtonReturn { Task { await studio.discardActiveRecording(restart:restart) } }
    }
    func audioToggle(_ title:String, enabled:Binding<Bool>, on:String, off:String) -> some View {
        Button { enabled.wrappedValue.toggle() } label: {
            VStack(spacing:5) {
                Image(systemName:enabled.wrappedValue ? on : off).font(.system(size:18))
                Text(title + (enabled.wrappedValue ? " On" : " Off")).font(.system(size:11))
            }.frame(minWidth:96).padding(.vertical,7)
                .foregroundStyle(enabled.wrappedValue ? accent : Color.gray)
                .background(RoundedRectangle(cornerRadius:9).fill(enabled.wrappedValue ? accent.opacity(0.10) : Color.white.opacity(0.035)))
        }.disabled(studio.busy)
            .accessibilityLabel(title)
            .accessibilityValue(enabled.wrappedValue ? "On" : "Off")
            .help((enabled.wrappedValue ? "Disable " : "Enable ") + title)
    }
    func tool(_ text:String,_ symbol:String) -> some View { VStack(spacing:6) { Image(systemName:symbol).font(.system(size:20)); Text(text).font(.system(size:11)) }.frame(minWidth:48) }
    func modeButton(_ name:String,_ symbol:String) -> some View {
        Button { screenshot = false; studio.mode = name; Task { await studio.prepareCapture() } } label: { tool(name,symbol).foregroundStyle(studio.mode == name ? accent : .white) }.disabled(studio.busy)
    }
    var targetPicker:some View {
        VStack(alignment:.leading,spacing:18) {
            Text(screenshot ? "Screenshot" : "Recording Source").font(.system(size:19,weight:.semibold))
            Picker("Source",selection:$studio.mode) { Text("Screen").tag("Screen"); Text("Window").tag("Window"); Text("Area").tag("Area"); if !screenshot { Text("Device").tag("Device") } }.pickerStyle(.segmented)
                .onChange(of:studio.mode) { if studio.mode == "Device" { Task { await studio.prepareDeviceCapture() } } }
            if studio.mode == "Device" {
                devicePicker
            } else if studio.mode == "Window" {
                Picker("Window",selection:$studio.windowID) {
                    ForEach(studio.windows,id:\.windowID) { window in Text("\(window.owningApplication?.applicationName ?? "Application") · \(window.title ?? "Window")").tag(window.windowID) }
                }
            } else {
                Picker("Screen",selection:$studio.displayID) { ForEach(Array(studio.displays.enumerated()),id:\.element.displayID) { i,display in Text("Screen \(i+1) · \(display.width) × \(display.height)").tag(display.displayID) } }.onChange(of:studio.displayID) { studio.area = nil }
                if studio.mode == "Area" {
                    Button { studio.onSelectArea?() } label: { Label(studio.area == nil ? "Draw Area" : "Select Area Again",systemImage:"viewfinder") }
                    if let rect = studio.area { Text("\(Int(rect.width)) × \(Int(rect.height)) pt").font(.caption).foregroundStyle(.secondary) }
                }
            }
            if !screenshot && studio.mode != "Device" {
                Toggle("Record System Audio",isOn:$studio.systemAudio)
                Toggle("Record Microphone",isOn:$studio.mic)
                Toggle("Record Camera",isOn:cameraBinding)
                if !studio.systemAudio && !studio.mic { Text("The video will be recorded without audio.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("\(studio.preferences.fps) fps · \(studio.preferences.countdown) s countdown · Stop ⌃⌥S · Pause ⌃⌥P").font(.system(size:12)).foregroundStyle(.secondary)
            Button { Task { if screenshot { await studio.takeScreenshot() } else { await studio.startRecording() } } } label: { Text(screenshot ? "Capture" : "Start Recording").frame(maxWidth:.infinity).padding(7).foregroundStyle(.black) }.buttonStyle(.borderedProminent)
                .disabled(studio.busy || (studio.mode == "Area" && studio.area == nil) || (studio.mode == "Window" && studio.windows.isEmpty) || (studio.mode == "Device" ? studio.mobileDevices.isEmpty : studio.displays.isEmpty))
        }.padding(22).frame(width:380).preferredColorScheme(.dark).tint(accent)
    }
    var devicePicker:some View {
        VStack(alignment:.leading,spacing:10) {
            if studio.mobileDevices.isEmpty {
                Text("No iPhone or iPad found. Connect it with a cable, unlock it and choose Trust This Computer.").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("Device",selection:$studio.mobileDeviceID) { ForEach(studio.mobileDevices,id:\.uniqueID) { Text($0.localizedName).tag($0.uniqueID) } }
                Text("The device screen and its sound are recorded. A matching device frame and canvas are applied in the editor.").font(.caption).foregroundStyle(.secondary)
            }
            Button { Task { await studio.prepareDeviceCapture() } } label: { Label("Refresh Devices",systemImage:"arrow.clockwise") }
        }
    }
}

@main struct LumioApp: App {
    @NSApplicationDelegateAdaptor(AppCoordinator.self) var delegate
    var body:some Scene { Settings { EmptyView() } }
}
