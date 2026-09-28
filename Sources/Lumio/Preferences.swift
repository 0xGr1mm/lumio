import SwiftUI
import AVFoundation

struct PreferencesView: View {
    @ObservedObject var studio: Studio
    @State var section = "General"
    let sections = [("General","gearshape"),("Recording","record.circle"),("Screenshot","camera.viewfinder"),("Export","film"),("Editor","slider.horizontal.3"),("Keyboard","keyboard")]
    var body:some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:7) {
                Text("Lumio").font(.system(size:23,weight:.semibold,design:.rounded)).padding(.bottom,22)
                ForEach(sections,id:\.0) { item in
                    Button { section = item.0 } label: { Label(item.0,systemImage:item.1).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(section == item.0 ? .white.opacity(0.12) : .clear).clipShape(RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain)
                }
                Spacer()
                Text("Version 0.13.0 · Local").font(.system(size:12)).foregroundStyle(.secondary)
            }.padding(18).frame(width:170).background(Color(white:0.14))
            Divider()
            ScrollView {
                VStack(alignment:.leading,spacing:25) {
                    Text(section).font(.system(size:22,weight:.semibold))
                    if section == "General" {
                        box("Startup") { Text("Lumio opens with the floating recording bar. Finished recordings open directly in the editor.").foregroundStyle(.secondary) }
                        box("Local Processing") { Text("Videos and images are processed on your Mac. No account, telemetry or cloud connection is used.").foregroundStyle(.secondary) }
                        Button("Show Recording Bar") { studio.onShowRecorder?() }
                    } else if section == "Recording" {
                        box("Video") {
                            Picker("Frame Rate",selection:$studio.preferences.fps) { Text("30 fps").tag(30); Text("60 fps").tag(60) }
                            Toggle("Retina Resolution",isOn:$studio.preferences.retina)
                            Toggle("HEVC · Smaller Files",isOn:Binding(get:{studio.preferences.hevc ?? false},set:{studio.preferences.hevc=$0}))
                            Text("Captures wider than 4096 pixels always use HEVC, because H.264 cannot encode them.").font(.caption).foregroundStyle(.secondary)
                            Toggle("Show Cursor in New Recordings",isOn:$studio.preferences.showCursor)
                            Toggle("Hide Lumio from Recording",isOn:$studio.preferences.hideLumio)
                            Toggle("Hide Desktop Icons",isOn:Binding(get:{studio.preferences.hideDesktopIcons ?? false},set:{studio.preferences.hideDesktopIcons=$0}))
                            Toggle("Include Menu Bar",isOn:$studio.preferences.includeMenuBar)
                        }
                        box("Start") {
                            Picker("Countdown",selection:$studio.preferences.countdown) { Text("None").tag(0); Text("3 seconds").tag(3); Text("5 seconds").tag(5); Text("10 seconds").tag(10) }
                        }
                        box("Audio & Camera") {
                            Toggle("System Audio",isOn:$studio.systemAudio); Toggle("Microphone",isOn:$studio.mic); Toggle("Camera",isOn:$studio.camera)
                            Text("The camera is recorded to its own file next to the screen recording, so its position, size and shape stay editable.").font(.caption).foregroundStyle(.secondary)
                        }
                    } else if section == "Screenshot" {
                        box("Capture") { Toggle("Show Cursor",isOn:$studio.preferences.screenshotCursor); Toggle("Copy Raw Image to Clipboard",isOn:$studio.preferences.copyScreenshot) }
                        box("After Capture") { Text("The PNG is saved to the output folder and opened in the editor. You can add a background and glow before exporting a new PNG.").foregroundStyle(.secondary) }
                    } else if section == "Export" {
                        box("Recording Folder") {
                            Text(studio.preferences.folder.path).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Choose Folder…") {
                                let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false
                                if picker.runModal() == .OK, let url = picker.url { studio.preferences.folderPath = url.path }
                            }
                        }
                        box("Export") {
                            Toggle("Reveal Output in Finder",isOn:$studio.preferences.revealExport)
                            Text("Video: MP4 or MOV · H.264 or HEVC · 24, 30 or 60 fps\nAnimation: GIF\nCaptions: SRT\nImage: PNG\nNo watermark. Choose these in the editor's Export menu.").foregroundStyle(.secondary).lineSpacing(6)
                        }
                    } else if section == "Editor" {
                        box("Default Look") {
                            Text("Save the current background, frame, video and camera styling for new recordings.").foregroundStyle(.secondary)
                            Button("Save Current Look as Default") { studio.saveDefaultLook() }
                            Button("Reset Default Look") { studio.look = Look(); studio.saveDefaultLook() }
                        }
                        box("Projects") { Text("Save Project stores the look, timeline, zoom, cursor and camera settings in a .lumio file. Keep the raw media in its original location.").foregroundStyle(.secondary) }
                    } else {
                        box("Shortcuts") {
                            shortcut("Play / Pause","Space")
                            shortcut("Selection Tool","A")
                            shortcut("Blade Tool","B / C")
                            shortcut("Trim Tool","T")
                            shortcut("Position Tool","P")
                            shortcut("Split at Playhead","⌘ B")
                            shortcut("Copy / Cut Selected Timeline Item","⌘ C / ⌘ X")
                            shortcut("Paste at Playhead","⌘ V")
                            shortcut("Duplicate Selected Item","⌘ D")
                            shortcut("Delete Selected Item","Delete")
                            shortcut("Trim Start to Playhead","⌥ [")
                            shortcut("Trim End to Playhead","⌥ ]")
                            shortcut("Previous / Next Frame","← / →")
                            shortcut("Undo","⌘ Z")
                            shortcut("Redo","⇧ ⌘ Z")
                            shortcut("Open Media","⌘ O")
                            shortcut("Save Project","⌘ S")
                            shortcut("Export","⌘ E")
                            shortcut("Recording Bar","⌘ R")
                            shortcut("Start / Finish Retake (while recording)","⌃ ⌥ R")
                            shortcut("Pause / Resume Recording","⌃ ⌥ P")
                            shortcut("Stop Recording","⌃ ⌥ S")
                            shortcut("Settings","⌘ ,")
                            shortcut("Cancel Area Selection","Esc")
                        }
                        Text("Shortcuts work while Lumio is active.").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(28).frame(maxWidth:.infinity,alignment:.leading)
            }
        }.font(.system(size:14)).background(Color(white:0.10)).preferredColorScheme(.dark).tint(accent)
        .onChange(of:studio.preferences.fps) { persist() }
        .onReceive(studio.$preferences) { prefs in if let data = try? JSONEncoder().encode(prefs) { UserDefaults.standard.set(data,forKey:"recorder") } }
        .disabled(studio.recording || studio.busy)
    }
    func persist() { if let data = try? JSONEncoder().encode(studio.preferences) { UserDefaults.standard.set(data,forKey:"recorder") } }
    func box<Content:View>(_ title:String,@ViewBuilder content:() -> Content) -> some View {
        VStack(alignment:.leading,spacing:14) { Text(title).fontWeight(.semibold); VStack(alignment:.leading,spacing:16,content:content).frame(maxWidth:.infinity,alignment:.leading).padding(16).background(.white.opacity(0.045)).clipShape(RoundedRectangle(cornerRadius:10)) }
    }
    func shortcut(_ name:String,_ key:String) -> some View { HStack { Text(name); Spacer(); Text(key).foregroundStyle(.secondary).monospaced() } }
}

struct LumioProject: Codable {
    var version = 1
    var source: String
    var look: Look
    var start: Double
    var end: Double
    var cuts:[VideoCut]? = nil
    var splits:[Double]? = nil
    var videoClips:[VideoClip]? = nil
    var zooms: [ZoomClip]? = nil
    var motion: MotionSettings? = nil
    var pointerSamples: [PointerSample]? = nil
    var cameraPath: String? = nil
    var cameraOffset: Double? = nil
    var captions: [CaptionCue]? = nil
    var captionStyle: CaptionStyle? = nil
    var audioTracks: [AudioTrackEdit]? = nil
    var audioSettings: AudioMixSettings? = nil
    var keyboardSamples: [KeySample]? = nil
    var keyboardStyle: KeyboardOverlayStyle? = nil
    var savedVersions:[SavedEditVersion]? = nil
    var retakes:[RetakeMarker]? = nil
    var annotations:[Annotation]? = nil
    var addedSources:[String:Double]? = nil
    var markers:[TimelineMarker]? = nil
}
@MainActor extension Studio {
    func saveDefaultLook() { if let data = try? JSONEncoder().encode(look) { UserDefaults.standard.set(data,forKey:"defaultLook") } }
    func saveProject() {
        guard let source else { return }
        let picker = NSSavePanel(); picker.nameFieldStringValue = "\(source.deletingPathExtension().lastPathComponent).lumio"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        if url.standardizedFileURL == source.standardizedFileURL { message = "Save the project to a file different from the raw media."; return }
        do {
            let data=try JSONEncoder().encode(LumioProject(source:source.path,look:look,start:trimStart,end:trimEnd,videoClips:videoClips,zooms:zooms,motion:motion,pointerSamples:pointerSamples,cameraPath:cameraPath,cameraOffset:cameraOffset,captions:captions,captionStyle:captionStyle,audioTracks:audioTracks,audioSettings:audioSettings,keyboardSamples:keyboardSamples,keyboardStyle:keyboardStyle,savedVersions:savedVersions,retakes:retakes,annotations:annotations,addedSources:addedSources.isEmpty ? nil:addedSources,markers:markers.isEmpty ? nil:markers))
            guard data.count<=20_000_000 else{throw failure("This project exceeds the 20 MB limit. Remove saved versions before saving again.")}
            try data.write(to:url,options:.atomic)
        } catch { message = error.localizedDescription }
    }
    func openProject(_ chosen:URL?=nil) {
        var selected=chosen
        if selected == nil {
            let picker = NSOpenPanel(); picker.allowsMultipleSelection = false
            guard picker.runModal() == .OK, let url = picker.url else { return }
            selected=url
        }
        guard let url=selected else { return }
        Task {
            do {
                let project = try JSONDecoder().decode(LumioProject.self,from:readBoundedData(url))
                guard project.version == 1 else { throw failure("This project version is not supported.") }
                let media = URL(fileURLWithPath:project.source)
                guard FileManager.default.fileExists(atPath:media.path) else { throw failure("The raw media for this project was not found: \(media.lastPathComponent)") }
                if NSImage(contentsOf:media) != nil { loadImage(media) } else { await load(media) }
                look = project.look.normalized()
                // Added recordings are kept only while their files are still there.
                addedSources=(project.addedSources ?? [:]).filter { FileManager.default.fileExists(atPath:$0.key) }
                if let clips=project.videoClips,!clips.isEmpty {
                    let restored=normalizedVideoClips(clips,sourceDuration:sourceDuration,added:addedSources)
                    if restored.count<clips.count,clips.contains(where:{ $0.source != nil }) { message="Some added recordings were not found, so their clips were left out." }
                    if restored.isEmpty {resetVideoClips()} else {videoClips=restored;selectedClip=restored.first?.id;synchronizeVideoSequence()}
                } else {
                    migrateLegacyVideoEdits(start:project.start,end:project.end,cuts:Array((project.cuts ?? []).prefix(10_000)))
                }
                zooms=normalizedZoomClips(project.zooms ?? [],duration:duration);selectedZoom=nil
                annotations=normalizedAnnotations(project.annotations ?? [],duration:duration);selectedAnnotation=nil
                markers=normalizedMarkers(project.markers ?? [],duration:duration);selectedMarker=nil
                motion=(project.motion ?? MotionSettings()).normalized();pointerSamples=normalizedPointerSamples(project.pointerSamples ?? pointerSamples,sourceDuration:sourceDuration)
                if let path=project.cameraPath,FileManager.default.fileExists(atPath:path),!(try await AVURLAsset(url:URL(fileURLWithPath:path)).loadTracks(withMediaType:.video)).isEmpty{cameraPath=path}else{cameraPath=nil};cameraOffset=cameraPath == nil ? nil:project.cameraOffset
                captions=normalizedCaptionCues(project.captions ?? [],duration:duration);captionStyle=(project.captionStyle ?? CaptionStyle()).normalized();selectedCaption=captions.first?.id
                audioTracks=normalizedAudioTracks(project.audioTracks ?? []);audioSettings=(project.audioSettings ?? AudioMixSettings()).normalized();selectedAudioTrack=audioTracks.first?.id
                keyboardSamples=normalizedKeySamples(project.keyboardSamples ?? keyboardSamples,sourceDuration:sourceDuration);keyboardStyle=(project.keyboardStyle ?? KeyboardOverlayStyle()).normalized()
                retakes=normalizedRetakes(project.retakes ?? retakes,duration:sourceDuration)
                var versionIDs=Set<UUID>()
                savedVersions=Array((project.savedVersions ?? []).prefix(24)).map{ original in
                    var item=original.normalized(sourceDuration:sourceDuration,added:addedSources)
                    if !versionIDs.insert(item.id).inserted {item.id=UUID()}
                    return item
                }
                refreshComposition()
                trimStart=0;trimEnd=duration;seek(0)
            } catch { message = error.localizedDescription }
        }
    }
    func exportImage(to requested: URL? = nil) {
        guard let image = stillImage else { return }
        let destination: URL
        if let requested { destination = requested }
        else {
            let save = NSSavePanel(); save.nameFieldStringValue = "Lumio-image.png"; save.allowedContentTypes = [.png]
            guard save.runModal() == .OK, let selected = save.url else { return }
            destination = selected
        }
        guard destination.standardizedFileURL != source?.standardizedFileURL else { message = "Choose a different file name to preserve the raw image."; return }
        let size = look.canvas
        let (root,rect) = decorationLayers(look:look,size:size,mediaAspect:look.contentAspect(media:mediaAspect))
        let media = CALayer(); media.frame = rect; media.contents = image.cgImage(forProposedRect:nil,context:nil,hints:nil)
        media.contentsRect = layerContentsRect((look.videoStyle ?? VideoStyle()).cropRect)
        media.cornerRadius = look.radius*min(size.width,size.height)/800; media.masksToBounds = true; root.addSublayer(media)
        root.addSublayer(borderLayer(look:look,rect:rect,size:size))
        guard let context = CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { message = "The image could not be created."; return }
        root.render(in:context)
        guard let output = context.makeImage(), let data = NSBitmapImageRep(cgImage:output).representation(using:.png,properties:[:]) else { message = "The PNG could not be created."; return }
        do { try data.write(to:destination,options:.atomic); lastExportURL = destination; if preferences.revealExport { NSWorkspace.shared.activateFileViewerSelecting([destination]) } } catch { message = error.localizedDescription }
    }
}
