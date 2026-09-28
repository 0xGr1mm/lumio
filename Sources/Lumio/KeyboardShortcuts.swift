import AppKit
import SwiftUI

struct KeySample: Codable, Equatable, Identifiable {
    var id = UUID()
    var time: Double
    var key: String
    var modifiers: [String]
    /// A plain keystroke: only its time is kept, never the character, so typed text and passwords are not saved.
    var typing: Bool? = nil
    var display: String { (modifiers + [key]).joined() }
}

/// Keeps shortcuts (⌘ or ⌃ combinations, Esc, ⌥ with navigation keys) and reduces everything else to an anonymous typing mark.
/// ⌥ alone does not count as a shortcut because many layouts type characters with it (Turkish @ is ⌥Q).
func keySample(time:Double,keyCode:UInt16,flags:NSEvent.ModifierFlags,characters:String?)->KeySample? {
    let flags=flags.intersection([.control,.option,.shift,.command])
    let special:[UInt16:String]=[36:"↩",48:"⇥",49:"Space",51:"⌫",53:"Esc",76:"⌤",117:"⌦",123:"←",124:"→",125:"↓",126:"↑"]
    let shortcut=flags.contains(.command) || flags.contains(.control) || keyCode == 53 || (flags.contains(.option) && special[keyCode] != nil)
    guard shortcut else { return KeySample(time:time,key:"typing",modifiers:[],typing:true) }
    var modifiers:[String]=[]
    if flags.contains(.control) { modifiers.append("⌃") }
    if flags.contains(.option) { modifiers.append("⌥") }
    if flags.contains(.shift) { modifiers.append("⇧") }
    if flags.contains(.command) { modifiers.append("⌘") }
    let raw=special[keyCode] ?? characters?.uppercased() ?? ""
    guard !raw.isEmpty else { return nil }
    return KeySample(time:time,key:raw,modifiers:modifiers)
}

func shiftedKeySamples(_ samples:[KeySample],by offset:Double)->[KeySample] {
    samples.compactMap { sample in
        var copy=sample;copy.time-=offset
        guard copy.time >= -0.05 else{return nil}
        copy.time=max(0,copy.time);return copy
    }
}

struct KeyboardRecording: Codable { var samples: [KeySample] }

func normalizedKeySamples(_ samples:[KeySample],sourceDuration:Double,limit:Int=100_000)->[KeySample] {
    var result:[KeySample]=[],ids=Set<UUID>()
    for original in samples.prefix(limit) {
        guard original.time.isFinite,original.time>=0,original.time<=max(0,sourceDuration) else{continue}
        var value=original
        value.key=String(value.key.prefix(40));value.modifiers=value.modifiers.prefix(8).map{String($0.prefix(8))}
        guard !value.key.isEmpty else{continue}
        if ids.contains(value.id){value.id=UUID()};ids.insert(value.id);result.append(value)
    }
    return result.sorted{$0.time<$1.time}
}

struct KeyboardOverlayStyle: Codable, Equatable {
    var enabled = true
    var style = "Glass"
    var mode = "Symbols"
    var duration = 1.5
    var size = 68.0
    var padding = 32.0
    var opacity = 0.85
    var position = "Bottom"
    var alignment = "Center"
    func normalized()->KeyboardOverlayStyle {var value=self;value.duration=min(5,max(0.3,value.duration.isFinite ? value.duration:1.5));value.size=min(120,max(24,value.size.isFinite ? value.size:68));value.padding=min(64,max(8,value.padding.isFinite ? value.padding:32));value.opacity=min(1,max(0.1,value.opacity.isFinite ? value.opacity:0.85));if !["Flat","Glass"].contains(value.style){value.style="Glass"};if !["Symbols","Keys"].contains(value.mode){value.mode="Symbols"};if !["Top","Bottom"].contains(value.position){value.position="Bottom"};if !["Left","Center","Right"].contains(value.alignment){value.alignment="Center"};return value}
}

@MainActor final class KeyboardCapture {
    private var monitor: Any?
    private var startUptime = ProcessInfo.processInfo.systemUptime
    private(set) var samples: [KeySample] = []

    func start() {
        stopMonitoring(); samples = []; startUptime = ProcessInfo.processInfo.systemUptime
        if !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // event.timestamp shares the system uptime clock, so the key time is exact even if the main thread is busy.
            let time = event.timestamp, code = event.keyCode, flags = event.modifierFlags, characters = event.charactersIgnoringModifiers
            Task { @MainActor in
                guard let self, let sample = keySample(time: max(0, time - self.startUptime), keyCode: code, flags: flags, characters: characters) else { return }
                self.samples.append(sample)
            }
        }
    }
    func stop() -> [KeySample] { stopMonitoring(); return samples }
    private func stopMonitoring() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

func shortcutArtwork(sample: KeySample, style: KeyboardOverlayStyle) -> CGImage {
    let text = style.mode == "Symbols" ? sample.display : (sample.modifiers + [sample.key]).joined(separator: " + ")
    let font = NSFont.systemFont(ofSize: style.size, weight: .semibold)
    let measured = (text as NSString).size(withAttributes: [.font:font])
    let width = max(120, Int(measured.width + style.padding * 2)), height = max(80, Int(style.size + style.padding * 1.55))
    let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x:0,y:CGFloat(height)); context.scaleBy(x:1,y:-1)
    let graphics = NSGraphicsContext(cgContext:context,flipped:true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=graphics
    let rect=NSRect(x:2,y:2,width:width-4,height:height-4)
    let path=NSBezierPath(roundedRect:rect,xRadius:style.style == "Glass" ? 20:12,yRadius:style.style == "Glass" ? 20:12)
    (style.style == "Glass" ? NSColor.black.withAlphaComponent(0.62):NSColor.black.withAlphaComponent(0.90)).setFill(); path.fill()
    if style.style == "Glass" { NSColor.white.withAlphaComponent(0.28).setStroke();path.lineWidth=1.5;path.stroke() }
    let paragraph=NSMutableParagraphStyle();paragraph.alignment = .center
    (text as NSString).draw(in:NSRect(x:0,y:(CGFloat(height)-measured.height)/2-2,width:CGFloat(width),height:measured.height+8),withAttributes:[.font:font,.foregroundColor:NSColor.white,.paragraphStyle:paragraph])
    NSGraphicsContext.restoreGraphicsState(); return context.makeImage()!
}

struct KeyboardShortcutsPanel: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Toggle("Show Keyboard Shortcuts",isOn:$studio.keyboardStyle.enabled)
            Picker("Style",selection:$studio.keyboardStyle.style) { Image(systemName:"rectangle.fill").tag("Flat");Image(systemName:"sparkles.rectangle.stack").tag("Glass") }.pickerStyle(.segmented)
            Picker("Mode",selection:$studio.keyboardStyle.mode) { Image(systemName:"command").tag("Symbols");Image(systemName:"keyboard").tag("Keys") }.pickerStyle(.segmented)
            MotionSlider(title:"Duration",value:$studio.keyboardStyle.duration,range:0.3...5,suffix:" s")
            MotionSlider(title:"Size",value:$studio.keyboardStyle.size,range:24...120,suffix:" pt")
            MotionSlider(title:"Padding",value:$studio.keyboardStyle.padding,range:8...64,suffix:" pt")
            MotionSlider(title:"Opacity",value:$studio.keyboardStyle.opacity,range:0.1...1)
            Picker("Position",selection:$studio.keyboardStyle.position) { Image(systemName:"rectangle.topthird.inset.filled").tag("Top");Image(systemName:"rectangle.bottomthird.inset.filled").tag("Bottom") }.pickerStyle(.segmented)
            Picker("Align",selection:$studio.keyboardStyle.alignment) { Image(systemName:"text.alignleft").tag("Left");Image(systemName:"text.aligncenter").tag("Center");Image(systemName:"text.alignright").tag("Right") }.pickerStyle(.segmented)
            Divider();Text("Log").foregroundStyle(.secondary)
            let shortcuts=studio.keyboardSamples.filter{!($0.typing ?? false)}
            if shortcuts.isEmpty { Text("No keyboard shortcuts recorded.").font(.caption).foregroundStyle(.secondary) }
            else { ForEach(shortcuts.suffix(30).reversed()) { sample in HStack {Text(sample.display).font(.system(.caption,design:.monospaced));Spacer();Text(stamp(sample.time)).foregroundStyle(.secondary)} } }
            Text("Only shortcuts are shown and saved. Ordinary typing is kept as timing alone, never as text.").font(.caption2).foregroundStyle(.secondary)
        }.font(.system(size:12))
    }
}
