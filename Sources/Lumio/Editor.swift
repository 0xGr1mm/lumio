import SwiftUI
import AVKit

struct Editor: View {
    @ObservedObject var studio: Studio
    @State var tab = "Background"
    @State var library = false
    @State var presetLabel = "Twilight"
    @State var backgroundTab="wallpaper"
    @State var videoFrameExpanded=false
    @State var videoLogoExpanded=false
    @State var videoGlowExpanded=false
    @State var videoClipExpanded=false
    @State var videoCropExpanded=false
    @State var videoProgressExpanded=false
    @State var videoHandleExpanded=false
    var body:some View {
        VStack(spacing:0) {
            header
            Divider()
            HStack(spacing:0) {
                if library { libraryView.frame(width:185); Divider() }
                VStack(spacing:0) {
                    canvasToolbar
                    CanvasPreview(studio:studio)
                        .aspectRatio(studio.look.canvas.width/studio.look.canvas.height,contentMode:.fit)
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                        .padding(.horizontal,28).padding(.vertical,16)
                        .overlay(alignment:.bottom) { if let toast=studio.toast { ToastView(text:toast) } }
                        .animation(.spring(response:0.32,dampingFraction:0.8),value:studio.toast)
                    transport
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
                Divider()
                VStack(spacing:0) { inspectorNavigation;Divider();inspector }.frame(width:320)
            }
            Divider()
            TimelineEditor(studio:studio,selectZoom:{ tab = "Zoom" },selectCaption:{ tab = "Captions" },selectMarker:{ tab = "Markers" },selectAnnotation:{ tab = "Annotate" })
            Divider()
            HStack(spacing:7) {
                Circle().fill(accent).frame(width:5,height:5)
                Text(studio.exportProgress.map { "Exporting… \(Int($0*100))%" } ?? (studio.busy ? "Processing…" : "Preview ready"))
                Spacer()
                Text("\(Int(studio.look.canvas.width)) × \(Int(studio.look.canvas.height)) · \(studio.stillImage == nil ? "\(studio.exportSettings.resolvedFormat) · \(studio.exportSettings.resolvedFPS) fps" : "PNG")")
            }.font(.system(size:11)).foregroundStyle(.secondary).padding(.horizontal,18).padding(.vertical,9)
        }.background(Color(white:0.055)).preferredColorScheme(.dark).tint(accent)
        .frame(minWidth:1040,minHeight:720)
        .onChange(of:studio.source) {if !studio.retakes.isEmpty {tab="Retakes"}}
        .onAppear { if !studio.retakes.isEmpty {tab="Retakes"};studio.previousSnapshot=studio.snapshot;studio.refreshComposition() }
        .onChange(of:studio.snapshot) { studio.recordEdit() }
        .onChange(of:studio.previewQuality) { studio.refreshComposition() }
        .onChange(of:studio.exportSettings) { studio.exportSettings.store(); studio.refreshComposition() }
        .onChange(of:studio.look.aspect) {
            // A vertical or square canvas fills the frame and follows the cursor by default for landscape recordings.
            guard studio.stillImage == nil else { return }
            let ratio=studio.look.canvas.width/studio.look.canvas.height
            if studio.mediaAspect > 1.2 && ratio < 1.05 { studio.look.autoReframe=true } else if ratio >= 1.3 { studio.look.autoReframe=false }
        }
        .onChange(of:studio.audioSettings) { studio.refreshVoiceEnhancement() }
        .onChange(of:studio.previewSpeed) { if studio.playing { studio.player.playImmediately(atRate:Float(studio.previewSpeed)) } }
        .alert("Lumio",isPresented:Binding(get:{studio.message != nil},set:{if !$0 {studio.message = nil}})) { Button("OK") { studio.message = nil } } message: { Text(studio.message ?? "") }
    }
    var header:some View {
        HStack(spacing:10) {
            if let mark=brandImage("mark",size:26) { Image(nsImage:mark).accessibilityHidden(true) }
            else { Image(systemName:"record.circle").foregroundStyle(accent).font(.system(size:22)) }
            Text("Lumio").font(.system(size:20,weight:.semibold,design:.rounded))
            Divider().frame(height:20).padding(.horizontal,6)
            Button { tab="Versions" } label:{Image(systemName:"square.stack.3d.up")}.help("Version Shelf").accessibilityLabel("Version Shelf")
            Button { library.toggle() } label: { Image(systemName:"sidebar.left") }.help("Library").accessibilityLabel("Library")
            Text(studio.source?.deletingPathExtension().lastPathComponent ?? "New Project").lineLimit(1).foregroundStyle(.secondary).padding(.leading,6)
            Spacer()
            Button { studio.onShowRecorder?() } label: { Label("Record",systemImage:"record.circle") }.help("New Recording").accessibilityLabel("New Recording").disabled(studio.busy)
            if let exported=studio.lastExportURL {
                ShareLink(item:exported) { Image(systemName:"paperplane") }.help("Share \(exported.lastPathComponent) with AirDrop, Messages, Mail and more").accessibilityLabel("Share Last Export")
                Button { NSWorkspace.shared.activateFileViewerSelecting([exported]) } label: { Image(systemName:"folder") }.help("Show the last export in Finder").accessibilityLabel("Show Last Export")
            }
            Menu {
                Button("Open Media…") { studio.importVideo() }
                Button("Add Recording to Timeline…") { studio.chooseRecordingToAdd() }.disabled(studio.source == nil || studio.stillImage != nil)
                Button("Open Project…") { studio.openProject() }
                Button("Save Project…") { studio.saveProject() }
                Button("Save Look as Default") { studio.saveDefaultLook() }
            } label: { Image(systemName:"ellipsis") }.fixedSize().accessibilityLabel("Project menu")
            if let progress=studio.exportProgress {
                ProgressView(value:progress).frame(width:110)
                Text("\(Int(progress*100))%").monospacedDigit().foregroundStyle(.secondary)
                Button("Cancel") { studio.cancelExport() }.disabled(studio.exportTask == nil)
            }
            Button { studio.startExport() } label: { Label(studio.exportRange == nil ? "Export":"Export Selection",systemImage:"square.and.arrow.up") }
                .buttonStyle(.borderedProminent).foregroundStyle(.white).disabled(studio.source == nil || studio.busy).help(exportButtonTitle)
            Menu {
                Menu("Made for…") {
                    ForEach(exportPresets) { preset in
                        Button("\(preset.id)  ·  \(preset.detail)") { studio.applyExportPreset(preset) }
                    }
                }
                Divider()
                Picker("Resolution",selection:$studio.look.exportHeight) { Text("720p").tag(720);Text("1080p").tag(1080);Text("1440p").tag(1440);Text("4K").tag(2160) }
                if studio.stillImage == nil {
                    Picker("Format",selection:exportBinding({$0.resolvedFormat},{$0.format=$1})) { ForEach(["MP4","MOV","GIF"],id:\.self) { Text($0).tag($0) } }
                    Picker("Codec",selection:exportBinding({$0.resolvedCodec},{$0.codec=$1})) {
                        Text("H.264 · Most Compatible").tag("H.264")
                        Text("HEVC · Smaller Files").tag("HEVC")
                        if studio.exportSettings.resolvedFormat == "MOV" { Text("ProRes 4444 · Keeps Transparency").tag("ProRes 4444") }
                    }.disabled(studio.exportSettings.resolvedFormat == "GIF")
                    Picker("Frame Rate",selection:exportBinding({$0.resolvedFPS},{$0.fps=$1})) { Text("24 fps").tag(24);Text("30 fps").tag(30);Text("60 fps").tag(60) }.disabled(studio.exportSettings.resolvedFormat == "GIF")
                    Toggle("Copy File to Clipboard",isOn:exportBinding({$0.copyToClipboard ?? false},{$0.copyToClipboard=$1}))
                    Divider()
                    Button("Export Captions (SRT)…") { studio.exportCaptions() }.disabled(studio.captions.isEmpty)
                Button("Export Chapters (TXT)…") { studio.exportChapters() }.disabled(studio.markers.isEmpty)
                }
                Divider()
                Button(exportButtonTitle) { studio.startExport() }
                if studio.exportRange != nil {
                    Button("Export the Whole Timeline Instead") { studio.clearExportRange() }
                }
                if studio.stillImage == nil {
                    Button("Save This Frame as PNG…") { Task { await studio.exportFrame() } }
                        .disabled(studio.duration <= 0 || studio.busy)
                        .help("The frame under the playhead, for a thumbnail or a post")
                }
            } label: { Image(systemName:"chevron.down") }
                .fixedSize().help("Export Settings").accessibilityLabel("Export Settings").disabled(studio.source == nil || studio.busy)
        }.buttonStyle(.bordered).controlSize(.small).font(.system(size:12)).padding(.horizontal,18).padding(.vertical,12).background(panel)
        .background {
            HStack {
                Button("") { studio.importVideo() }.keyboardShortcut("o")
                Button("") { studio.saveProject() }.keyboardShortcut("s")
                Button("") { studio.startExport() }.keyboardShortcut("e")
            }.hidden().disabled(studio.busy)
        }
    }
    /// Says what pressing export will actually write, because a selection is easy to forget about.
    var exportButtonTitle:String {
        guard studio.stillImage == nil else { return "Export PNG…" }
        guard let span=studio.exportRange else { return "Export \(studio.exportSettings.resolvedFormat)…" }
        return String(format:"Export Selection %.1f–%.1f s…",span.start,span.end)
    }
    var canvasToolbar:some View {
        HStack(spacing:16) {
            Image(systemName:studio.stillImage == nil ? "film":"photo").foregroundStyle(.secondary).help(studio.stillImage == nil ? "Video":"Image")
            Menu {
                Picker("Preview Quality",selection:$studio.previewQuality) { Text("Fast · 480p").tag(0);Text("Balanced · 720p").tag(1);Text("High · 1080p").tag(2) }
                Picker("Playback Speed",selection:$studio.previewSpeed) { ForEach([0.25,0.5,1.0,1.5,2.0],id:\.self) { Text(String(format:"%.2g×",$0)).tag($0) } }
            } label:{Label("Preview",systemImage:"gauge.with.dots.needle.50percent")}.fixedSize().help("Preview Quality and Speed")
            Spacer()
            Picker("Canvas",selection:$studio.look.aspect) { ForEach(["16:9","9:16","1:1","4:3","4:5"],id:\.self) { Text($0).tag($0) } }.labelsHidden().frame(width:92)
            Toggle(isOn:Binding(get:{studio.look.autoReframe ?? false},set:{studio.look.autoReframe=$0})) { Image(systemName:"viewfinder.rectangular") }
                .toggleStyle(.button).help("Auto Reframe · fill the canvas and follow the cursor").accessibilityLabel("Auto Reframe").disabled(studio.stillImage != nil)
            Spacer()
            Menu { Button("Reset Look") { studio.look = Look() }; Button("Save as Default") { studio.saveDefaultLook() } } label: { Image(systemName:"paintbrush.pointed") }.help("Look").fixedSize()
        }.font(.system(size:12)).padding(.horizontal,26).padding(.top,16)
    }
    var inspectorNavigation:some View {
        VStack(spacing:10) {
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:6),count:3),spacing:6) {
                ForEach([("Background","photo.on.rectangle.angled"),("Design","rectangle.on.rectangle"),("Zoom","viewfinder"),("Cursor","cursorarrow"),("Audio","speaker.wave.2"),("Captions","captions.bubble"),("Camera","video"),("Transcript","text.quote"),("Shortcuts","command.square")],id:\.0) { item in
                    Button {tab=item.0} label: {
                        VStack(spacing:5) {Image(systemName:item.1).font(.system(size:16));Text(item.0).font(.system(size:11,weight:.medium))}
                            .frame(maxWidth:.infinity).frame(height:50)
                            .foregroundStyle(tab==item.0 ? accent:.secondary)
                            .background(tab==item.0 ? accent.opacity(0.10):Color.white.opacity(0.035))
                            .clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).accessibilityLabel(item.0).accessibilityValue(tab==item.0 ? "Selected":"")
                }
            }
            Menu {
                ForEach(["Quick","Privacy","Cleanup","Annotate","Markers","Retakes","Versions","Animations","Video"],id:\.self) { name in
                    Button(name) {tab=name}
                }
            } label: {Label("More tools",systemImage:"ellipsis.circle")}.fixedSize().font(.system(size:11)).accessibilityLabel("More tools")
        }.padding(14).background(panel)
    }
    var inspector:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:20) {
                Text(tab).font(.system(size:16,weight:.semibold))
                if tab == "Design" { designControls }
                else if tab == "Quick" { QuickPanel(studio:studio) }
                else if tab == "Privacy" { PrivacyPanel(studio:studio) }
                else if tab == "Background" {
                    Picker("Background",selection:$backgroundTab) {
                        Text("Wallpaper").tag("wallpaper")
                        Text("Gradient").tag("gradient")
                        Text("Color").tag("color")
                        Text("Image").tag("image")
                    }.pickerStyle(.segmented).labelsHidden().onChange(of:backgroundTab) { if backgroundTab == "color" { studio.look.mode="Color" };if backgroundTab == "gradient" { studio.look.mode="Gradient" };if backgroundTab == "image" { studio.look.mode="Image" } }
                    DisclosureGroup("Layout & frame") { designLayoutControls.padding(.top,12) }
                    if backgroundTab == "wallpaper" { WallpaperPanel(studio:studio) } else { backgroundControls }
                }
                else if tab == "Retakes" { RetakePanel(studio:studio) }
                else if tab == "Versions" { VersionShelfPanel(studio:studio) }
                else if tab == "Video" { videoControls }
                else if tab == "Zoom" { AutoZoomPanel(studio:studio) }
                else if tab == "Annotate" { AnnotationPanel(studio:studio) }
                else if tab == "Markers" { MarkerInspector(studio:studio) }
                else if tab == "Cursor" { CursorPanel(studio:studio) }
                else if tab == "Camera" { cameraControls }
                else if tab == "Captions" { CaptionPanel(studio:studio) }
                else if tab == "Transcript" { TranscriptPanel(studio:studio) }
                else if tab == "Cleanup" { SmartCleanupPanel(studio:studio) }
                else if tab == "Animations" { AnimationPanel(studio:studio) }
                else if tab == "Audio" { AudioPanel(studio:studio) }
                else if tab == "Shortcuts" { KeyboardShortcutsPanel(studio:studio) }
                else { KeyboardShortcutsPanel(studio:studio) }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }.background(panel).disabled(studio.busy)
    }
    var backgroundControls:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Styles").font(.system(size:12)).foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:2),spacing:8) {
                ForEach(backgroundStyles) { style in
                    Button { studio.look=style.applied(to:studio.look);studio.refreshComposition() } label: {
                        HStack(spacing:8) {
                            RoundedRectangle(cornerRadius:5).fill(LinearGradient(colors:[RGB(style.first).color,RGB(style.second).color],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:26,height:20)
                            Text(style.id).font(.system(size:11)).lineLimit(1)
                            Spacer(minLength:0)
                        }.padding(.vertical,5).padding(.horizontal,7).frame(maxWidth:.infinity).contentShape(Rectangle())
                            .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:7))
                    }.buttonStyle(.plain).help("Colours, texture and finishing together")
                }
            }
            Divider()
            Picker("Type",selection:$studio.look.mode) { ForEach(["Gradient","Radial","Aurora","Mesh","Color","Image"],id:\.self) { Text($0).tag($0) } }
            if ["Image","görsel"].contains(studio.look.mode) {
                Button { studio.chooseBackground() } label: { Label("Choose Image…",systemImage:"plus") }
                Button("Desktop Wallpaper") { studio.useDesktopBackground() }
                Button("From the Recording") { Task { await studio.useRecordingBackground() } }.help("A blurred frame of this recording, so the background always matches it")
                if let path = studio.look.imagePath, let image = NSImage(contentsOfFile:path) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fill).frame(height:95).clipped().clipShape(RoundedRectangle(cornerRadius:8)) }
                else { Text("Choose an image for the background.").font(.system(size:12)).foregroundStyle(.secondary) }
            } else {
                HStack {
                    Text("Color Presets").foregroundStyle(.secondary)
                    Spacer()
                    Button { Task { await studio.matchBackgroundToRecording() } } label: { Image(systemName:"eyedropper") }.buttonStyle(.plain).help("Take the colours from the recording")
                    Button { if let preset=lookPresets.randomElement(){apply(preset)} } label: { Image(systemName:"shuffle") }.buttonStyle(.plain).help("Random Colors")
                }.font(.system(size:12))
                LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:3),spacing:8) {
                    ForEach(lookPresets) { preset in
                        Button { apply(preset) } label: {
                            RoundedRectangle(cornerRadius:7).fill(LinearGradient(colors:[RGB(preset.a).color,RGB(preset.b).color],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(height:43)
                                .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(studio.look.first == RGB(preset.a) && studio.look.second == RGB(preset.b) ? accent : .white.opacity(0.07),lineWidth:1.5))
                        }.buttonStyle(.plain).help(preset.id).accessibilityLabel(preset.id)
                    }
                }
                ColorPicker("First Color",selection:color($studio.look.first),supportsOpacity:false)
                if !["Color","düz renk"].contains(studio.look.mode) { ColorPicker("Second Color",selection:color($studio.look.second),supportsOpacity:false) }
                if ["Gradient","Aurora","gradyan","aurora"].contains(studio.look.mode) { slider("Gradient Angle",$studio.look.angle,0...360,"°") }
            }
            Divider()
            Picker("Texture",selection:$studio.look.pattern) { ForEach(["None","Dots","Grid","Lines","Waves"],id:\.self) { Text($0).tag($0) } }
            if !["None","yok"].contains(studio.look.pattern) { slider("Texture Opacity",$studio.look.patternOpacity,0...60,"%") }
            slider("Blur",$studio.look.blur,0...80,"")
            slider("Dim",$studio.look.dim,0...85,"%")
            Toggle("Transparent Background",isOn:Binding(get:{studio.look.isTransparent},set:{ on in
                studio.look.transparentBackground = on ? true:nil
                if on { studio.exportSettings.format="MOV";studio.exportSettings.codec="ProRes 4444";studio.exportSettings.store() }
                studio.refreshComposition()
            }))
            if studio.look.isTransparent {
                Text("The background is left out and the export switches to MOV · ProRes 4444, which carries transparency. The preview shows black where the background would be.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            slider("Vignette",Binding(get:{studio.look.resolvedVignette},set:{studio.look.vignette=$0<=0.5 ? nil:$0}),0...100,"%")
            slider("Grain",Binding(get:{studio.look.resolvedGrain},set:{studio.look.grain=$0<=0.5 ? nil:$0}),0...100,"%")
            if !["Image","görsel"].contains(studio.look.mode) {
                Button("Background From the Recording") { Task { await studio.useRecordingBackground() } }
                    .help("Takes the frame at the playhead, blurs it and uses it as the background")
            }
            Divider()
            Button("Save Look as Default") { studio.saveDefaultLook() }.font(.system(size:12))
        }.font(.system(size:13))
    }
    func apply(_ preset:LookPreset) { studio.look.first = RGB(preset.a); studio.look.second = RGB(preset.b); if ["Image","görsel"].contains(studio.look.mode) { studio.look.mode = "Gradient" }; presetLabel = preset.id }
    var videoControls:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Transform").fontWeight(.medium)
            slider("Scale",videoValue(\.scale,1),0.5...2,"×")
            slider("Horizontal Position",videoValue(\.x,0),-1...1,"")
            slider("Vertical Position",videoValue(\.y,0),-1...1,"")
            slider("Opacity",videoValue(\.opacity,1),0...1,"")
            Divider()
            Text("These controls are non-destructive and are applied to preview and export.").font(.caption).foregroundStyle(.secondary)
            Button("Reset Video Transform") { var value=studio.look.videoStyle ?? VideoStyle();value.scale=1;value.x=0;value.y=0;value.opacity=1;studio.look.videoStyle=value }
            Divider()
            DisclosureGroup("Logo",isExpanded:$videoLogoExpanded) { watermarkControls.padding(.top,12) }
            DisclosureGroup("Handle",isExpanded:$videoHandleExpanded) { handleControls.padding(.top,12) }
            DisclosureGroup("Frame & Shadow",isExpanded:$videoFrameExpanded) { frameControls.padding(.top,12) }
            DisclosureGroup("Crop",isExpanded:$videoCropExpanded) { CropPanel(studio:studio).padding(.top,12) }
            DisclosureGroup("Glow",isExpanded:$videoGlowExpanded) { glowControls.padding(.top,12) }
            DisclosureGroup("Progress Bar",isExpanded:$videoProgressExpanded) { progressControls.padding(.top,12) }
            if studio.stillImage == nil {
                DisclosureGroup("Selected Clip",isExpanded:$videoClipExpanded) { trimControls.padding(.top,12) }
            }
        }.font(.system(size:13))
    }
    var handleControls:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Your name in a corner of every frame, so a reposted clip still points back to you.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            TextField("@yourname",text:Binding(get:{studio.look.handleText ?? ""},set:{studio.look.handleText=$0;studio.refreshComposition()}))
                .textFieldStyle(.roundedBorder)
            if !studio.look.resolvedHandleText.isEmpty {
                Picker("Corner",selection:Binding(get:{studio.look.resolvedHandlePosition},set:{studio.look.handlePosition=$0;studio.refreshComposition()})) {
                    ForEach(["Top Left","Top Right","Bottom Left","Bottom Right"],id:\.self) { Text($0).tag($0) }
                }
                Text(String(format:"Size · %.1f%%",studio.look.resolvedHandleSize)).font(.caption)
                Slider(value:Binding(get:{studio.look.resolvedHandleSize},set:{studio.look.handleSize=$0}),in:1.4...9)
                Text(String(format:"Opacity · %.0f%%",studio.look.resolvedHandleOpacity)).font(.caption)
                Slider(value:Binding(get:{studio.look.resolvedHandleOpacity},set:{studio.look.handleOpacity=$0}),in:5...100)
                ColorPicker("Color",selection:Binding(get:{studio.look.resolvedHandleColor.color},set:{studio.look.handleColor=RGB($0);studio.refreshComposition()}),supportsOpacity:false)
            }
        }
    }
    var progressControls:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("A bar across the bottom that fills as the video plays. Short videos keep more viewers with one.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            HStack(spacing:8) {
                ForEach([("None",0.0),("Thin",6.0),("Bold",14.0)],id:\.0) { name,height in
                    Button(name) { studio.look.progressBar=height;studio.refreshComposition() }
                        .buttonStyle(.bordered).tint(abs(studio.look.resolvedProgressBar-height)<0.01 ? accent: nil)
                }
            }.controlSize(.small)
            if studio.look.resolvedProgressBar>0 {
                Text(String(format:"Height · %.0f px",studio.look.resolvedProgressBar)).font(.caption)
                Slider(value:Binding(get:{studio.look.resolvedProgressBar},set:{studio.look.progressBar=$0}),in:2...40)
                ColorPicker("Bar Color",selection:Binding(get:{studio.look.resolvedProgressColor.color},set:{studio.look.progressColor=RGB($0);studio.refreshComposition()}),supportsOpacity:false)
            }
        }
    }
    var watermarkControls:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("A logo drawn over the finished video, in preview and export alike.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(studio.look.watermarkPath == nil ? "Choose Logo…":"Replace Logo…") { studio.chooseWatermark() }
                if studio.look.watermarkPath != nil { Button("Remove") { studio.look.watermarkPath=nil;studio.refreshComposition() } }
            }
            if let path=studio.look.watermarkPath,let image=NSImage(contentsOfFile:path) {
                Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).frame(height:54)
                    .frame(maxWidth:.infinity).padding(8).background(.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:8))
                Picker("Corner",selection:Binding(get:{studio.look.resolvedWatermarkPosition},set:{studio.look.watermarkPosition=$0;studio.refreshComposition()})) {
                    ForEach(["Top Left","Top Right","Bottom Left","Bottom Right"],id:\.self) { Text($0).tag($0) }
                }
                slider("Size",Binding(get:{studio.look.resolvedWatermarkSize},set:{studio.look.watermarkSize=$0}),3...40,"%")
                slider("Opacity",Binding(get:{studio.look.resolvedWatermarkOpacity},set:{studio.look.watermarkOpacity=$0}),5...100,"%")
            }
        }
    }
    var frameControls:some View {
        VStack(alignment:.leading,spacing:20) {
            Text("Device Frame").fontWeight(.medium)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(["None","macOS Window","Browser","iPhone","iPad"],id:\.self) { frame in
                    Button { var value=studio.look.videoStyle ?? VideoStyle();value.frame=frame;studio.look.videoStyle=value } label:{
                        VStack(spacing:7) {Image(systemName:frame == "None" ? "nosign":frame == "Browser" ? "safari":frame == "iPhone" ? "iphone":frame == "iPad" ? "ipad":"macwindow");Text(frame).font(.system(size:10))}.frame(maxWidth:.infinity).frame(height:52).background((studio.look.videoStyle ?? VideoStyle()).frame == frame ? accent.opacity(0.22):Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain)
                }
            }
            let frameStyle=studio.look.videoStyle ?? VideoStyle()
            if frameStyle.frame == "Browser" || frameStyle.frame == "macOS Window" {
                VStack(alignment:.leading,spacing:6) {
                    TextField(frameStyle.frame == "Browser" ? "lumio.studio/tour":"Window title",
                              text:Binding(get:{(studio.look.videoStyle ?? VideoStyle()).frameTitle ?? ""},
                                           set:{var value=studio.look.videoStyle ?? VideoStyle();value.frameTitle=$0.isEmpty ? nil:$0;studio.look.videoStyle=value}))
                        .textFieldStyle(.roundedBorder)
                    Text(frameStyle.frame == "Browser" ? "Shown in the address bar. Leave it empty for a blank bar.":"Shown in the title bar. Leave it empty for a blank bar.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            ColorPicker("Frame Color",selection:Binding(get:{(studio.look.videoStyle ?? VideoStyle()).frameColor.color},set:{var value=studio.look.videoStyle ?? VideoStyle();value.frameColor=RGB($0);studio.look.videoStyle=value}),supportsOpacity:false)
            Divider()
            slider("Padding",$studio.look.padding,0...35,"%")
            slider("Corner Radius",$studio.look.radius,0...80,"")
            Divider()
            Text("Shadow").fontWeight(.medium)
            slider("Opacity",$studio.look.shadow,0...100,"%")
            slider("Softness",$studio.look.shadowBlur,0...100,"")
            slider("Vertical Offset",$studio.look.shadowY,-60...60,"")
            Divider()
            slider("Border Width",$studio.look.border,0...10,"")
            ColorPicker("Border Color",selection:color($studio.look.borderColor),supportsOpacity:false)
        }.font(.system(size:13))
    }
    var glowControls:some View {
        VStack(alignment:.leading,spacing:22) {
            Toggle("Glow",isOn:Binding(get:{studio.look.glow > 0},set:{studio.look.glow = $0 ? 55 : 0}))
            Text("Add a colored light around the video.").font(.system(size:12)).foregroundStyle(.secondary)
            ColorPicker("Glow Color",selection:color($studio.look.glowColor),supportsOpacity:false)
            HStack(spacing:12) {
                ForEach([UInt32(0xA18AFF),0x58D8FF,0xBEEC64,0xFF83C4,0xFFBC70,0xFFFFFF],id:\.self) { hex in
                    Button { studio.look.glowColor = RGB(hex); if studio.look.glow == 0 { studio.look.glow = 55 } } label: { Circle().fill(RGB(hex).color).frame(width:23,height:23) }.buttonStyle(.plain).accessibilityLabel("Glow color \(String(hex,radix:16))")
                }
            }
            slider("Intensity",$studio.look.glow,0...100,"%")
            slider("Spread",$studio.look.glowBlur,1...120,"")
            Divider()
            Button("Match Background Color") { studio.look.glowColor = studio.look.second; studio.look.glow = 60 }
        }.font(.system(size:13))
    }
    var trimControls:some View {
        VStack(alignment:.leading,spacing:22) {
            if studio.stillImage != nil { Text("This project contains an image.").foregroundStyle(.secondary) }
            else if let clip=studio.selectedVideoClip {
                Text("Adjust the selected clip against the raw recording. Trimmed frames are preserved and return when you extend an edge.").foregroundStyle(.secondary)
                slider("Timeline Position",Binding(get:{studio.selectedVideoClip?.timelineStart ?? 0},set:{studio.moveClip(clip.id,toTimelineStart:$0)}),0...max(10,studio.duration+10)," s")
                slider("Source Start",Binding(get:{studio.selectedVideoClip?.sourceStart ?? 0},set:{studio.updateClipEdge(clip.id,startEdge:true,to:$0)}),0...max(0.01,studio.sourceDuration)," s")
                slider("Source End",Binding(get:{studio.selectedVideoClip?.sourceEnd ?? studio.sourceDuration},set:{studio.updateClipEdge(clip.id,startEdge:false,to:$0)}),0...max(0.1,studio.sourceDuration)," s")
                Text(String(format:"Clip duration: %.2f s",studio.selectedVideoClip?.duration ?? 0)).foregroundStyle(accent)
                Picker("Speed",selection:Binding(get:{studio.selectedVideoClip?.speed ?? 1},set:{studio.setClipSpeed(clip.id,to:$0)})) {
                    ForEach([0.25,0.5,0.75,1.0,1.25,1.5,2.0,3.0,4.0],id:\.self) { Text(String(format:"%g×",$0)).tag($0) }
                }
                Text("Later clips, zooms, captions and added audio move with the new length.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Trim Start to Playhead") {studio.trimSelectedClipToPlayhead(startEdge:true)}
                    Button("Trim End to Playhead") {studio.trimSelectedClipToPlayhead(startEdge:false)}
                }
                Button("Restore Raw Bounds") {
                    studio.updateClipEdge(clip.id,startEdge:true,to:0)
                    studio.updateClipEdge(clip.id,startEdge:false,to:studio.sourceDuration)
                }
            } else {
                Text("Select a clip in the timeline.").foregroundStyle(.secondary)
            }
        }.font(.system(size:13))
    }
    var libraryView:some View {
        VStack(alignment:.leading,spacing:16) {
            Label("Library",systemImage:"folder").font(.system(size:13,weight:.semibold))
            Button { studio.importVideo() } label: { Label("Open Media",systemImage:"plus") }
            Button("Open Project…") { studio.openProject() }
            Divider()
            if let source = studio.source { Label(source.lastPathComponent,systemImage:studio.stillImage == nil ? "film" : "photo").font(.system(size:12)).lineLimit(3).foregroundStyle(.secondary) }
            Spacer()
            Button("Save Project…") { studio.saveProject() }
        }.font(.system(size:12)).padding(18).background(panel)
    }
    var cameraControls:some View {
        let style=studio.motion.cameraStyle ?? CameraStyle()
        return VStack(alignment:.leading,spacing:18) {
            HStack {Button("Choose Camera Video…") {studio.chooseCameraVideo()};if studio.cameraPath != nil {Button("Remove") {studio.cameraPath=nil;studio.refreshComposition()}}}
            Toggle("Show Camera",isOn:cameraValue(\.enabled,true)).disabled(studio.cameraPath == nil)
            Picker("Layout",selection:cameraValue(\.layout,"Floating")) {
                ForEach(["Floating","Split Left","Split Right","Camera Full","Screen Only"],id:\.self) {Text($0).tag($0)}
            }
            Text("Layout Templates").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:8) {
                ForEach(["Top Left","Top","Top Right","Left","Center","Right","Bottom Left","Bottom","Bottom Right"],id:\.self) { position in
                    Button {var value=studio.motion.cameraStyle ?? CameraStyle();value.layout="Floating";value.position=position;studio.motion.cameraStyle=value} label:{
                        RoundedRectangle(cornerRadius:7).fill(Color.white.opacity(0.045)).frame(height:44).overlay(alignment:cameraAlignment(position)){Circle().fill(accent).frame(width:13,height:13).padding(5)}.overlay(RoundedRectangle(cornerRadius:7).stroke(style.position == position && style.layout == "Floating" ? accent:.white.opacity(0.1)))
                    }.buttonStyle(.plain).help(position)
                }
            }
            slider("Size",cameraValue(\.size,19),8...55,"%")
            slider("Roundness",cameraValue(\.roundness,36),0...100,"%")
            slider("Margin",cameraValue(\.margin,24),0...100,"")
            slider("Size During Zoom",cameraValue(\.zoomSize,78),25...150,"%")
            Picker("Background",selection:Binding(get:{(studio.motion.cameraStyle ?? CameraStyle()).resolvedBackground},set:{var value=studio.motion.cameraStyle ?? CameraStyle();value.background=$0;studio.motion.cameraStyle=value})) {
                Text("Keep").tag("None");Text("Blur").tag("Blur");Text("Remove").tag("Remove")
            }
            if (studio.motion.cameraStyle ?? CameraStyle()).resolvedBackground == "Blur" {
                slider("Background Blur",Binding(get:{(studio.motion.cameraStyle ?? CameraStyle()).resolvedBackgroundBlur},set:{var value=studio.motion.cameraStyle ?? CameraStyle();value.backgroundBlur=$0;studio.motion.cameraStyle=value}),2...40,"")
            }
            if (studio.motion.cameraStyle ?? CameraStyle()).resolvedBackground != "None" {
                Text("The person is kept and what is behind them is blurred or removed, on device. A frame with nobody in it is left as it is.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Mirror Camera",isOn:cameraValue(\.mirror,false))
            Picker("When the Cursor Goes Under",selection:Binding(get:{(studio.motion.cameraStyle ?? CameraStyle()).resolvedAvoidStyle},set:{
                var value=studio.motion.cameraStyle ?? CameraStyle();value.avoidStyle=$0;value.avoidCursor=$0 != "None";studio.motion.cameraStyle=value
            })) {
                Text("Move Aside").tag("Move");Text("Fade").tag("Fade");Text("Stay").tag("None")
            }
            if studio.cameraPath != nil && studio.cameraOffset != nil { Label("Recorded with the screen · kept in sync automatically",systemImage:"checkmark.circle").font(.caption).foregroundStyle(accent) }
            slider("Border Width",cameraValue(\.borderWidth,3),0...16,"")
            ColorPicker("Border Color",selection:Binding(get:{(studio.motion.cameraStyle ?? CameraStyle()).borderColor.color},set:{var value=studio.motion.cameraStyle ?? CameraStyle();value.borderColor=RGB($0);studio.motion.cameraStyle=value}),supportsOpacity:false)
        }.font(.system(size:13))
    }
    var transport:some View {
        HStack(spacing:18) {
            Text(stamp(studio.position)).monospacedDigit()
            Button { studio.seek(studio.trimStart) } label: { Image(systemName:"backward.end.fill") }.help("Go to Start").accessibilityLabel("Go to Start")
            Button { studio.togglePlay() } label: { Image(systemName:studio.playing ? "pause.fill" : "play.fill").font(.system(size:17)).frame(width:38,height:38).background(.white.opacity(0.07)).clipShape(Circle()) }.help("Play / Pause · Space")
            Button { studio.seek(studio.trimEnd) } label: { Image(systemName:"forward.end.fill") }.help("Go to End").accessibilityLabel("Go to End")
            Text(stamp(studio.duration)).monospacedDigit().foregroundStyle(.secondary)
        }.font(.system(size:12)).buttonStyle(.plain).padding(.bottom,16).disabled(studio.stillImage != nil || studio.busy)
    }
    var timeline:some View {
        VStack(spacing:14) {
            HStack {
                Label("Timeline",systemImage:"rectangle.split.3x1").font(.system(size:12))
                Spacer()
                Button { tab = "Trim" } label: { Label("Trim",systemImage:"scissors") }.disabled(studio.stillImage != nil)
                Text(studio.stillImage == nil ? "1 Video" : "1 Image").font(.system(size:11)).foregroundStyle(.secondary)
            }
            HStack(spacing:12) {
                Text(studio.stillImage == nil ? "Video" : "Image").font(.system(size:11)).foregroundStyle(.secondary).frame(width:45,alignment:.leading)
                VStack(spacing:10) {
                    HStack { ForEach(0..<9) { n in Text(String(format:"%.1f",studio.duration*Double(n)/8)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary); if n < 8 { Spacer() } } }
                    GeometryReader { geo in
                        ZStack(alignment:.leading) {
                            RoundedRectangle(cornerRadius:7).fill(Color(red:0.20,green:0.30,blue:0.65).opacity(0.24))
                            if studio.duration > 0 {
                                RoundedRectangle(cornerRadius:7).fill(LinearGradient(colors:[Color(red:0.22,green:0.32,blue:0.75),Color(red:0.16,green:0.23,blue:0.49)],startPoint:.top,endPoint:.bottom))
                                    .frame(width:max(1,geo.size.width*(studio.trimEnd-studio.trimStart)/studio.duration)).offset(x:geo.size.width*studio.trimStart/studio.duration)
                            }
                            HStack { Image(systemName:studio.stillImage == nil ? "film" : "photo"); Text(studio.source?.lastPathComponent ?? "").lineLimit(1) }.font(.system(size:12)).padding(.horizontal,12)
                            Rectangle().fill(.white).frame(width:2).offset(x:geo.size.width*(studio.duration > 0 ? min(studio.position/studio.duration,1) : 0))
                        }.overlay(RoundedRectangle(cornerRadius:7).strokeBorder(.white.opacity(0.2)))
                    }.frame(height:45)
                    Slider(value:Binding(get:{min(studio.position,studio.duration)},set:{studio.position = $0;studio.seek($0)}),in:0...max(0.01,studio.duration)).disabled(studio.stillImage != nil || studio.busy)
                }
            }
        }.buttonStyle(.borderless).padding(20).frame(height:185).background(panel)
    }
    func color(_ binding:Binding<RGB>) -> Binding<Color> { Binding(get:{binding.wrappedValue.color},set:{binding.wrappedValue = RGB($0)}) }
    func exportBinding<T>(_ get:@escaping (ExportSettings)->T,_ set:@escaping (inout ExportSettings,T)->Void)->Binding<T> {
        Binding(get:{get(studio.exportSettings)},set:{ value in var settings=studio.exportSettings;set(&settings,value);studio.exportSettings=settings })
    }
    func videoValue(_ keyPath:WritableKeyPath<VideoStyle,Double>,_ fallback:Double)->Binding<Double> {Binding(get:{(studio.look.videoStyle ?? VideoStyle())[keyPath:keyPath]},set:{var value=studio.look.videoStyle ?? VideoStyle();value[keyPath:keyPath]=$0;studio.look.videoStyle=value})}
    func cameraValue<T>(_ keyPath:WritableKeyPath<CameraStyle,T>,_ fallback:T)->Binding<T> {Binding(get:{(studio.motion.cameraStyle ?? CameraStyle())[keyPath:keyPath]},set:{var value=studio.motion.cameraStyle ?? CameraStyle();value[keyPath:keyPath]=$0;studio.motion.cameraStyle=value})}
    func cameraAlignment(_ position:String)->Alignment {
        switch position {case "Top Left":return .topLeading;case "Top":return .top;case "Top Right":return .topTrailing;case "Left":return .leading;case "Center":return .center;case "Right":return .trailing;case "Bottom Left":return .bottomLeading;case "Bottom":return .bottom;default:return .bottomTrailing}
    }
    func slider(_ title:String,_ value:Binding<Double>,_ range:ClosedRange<Double>,_ unit:String) -> some View {
        VStack(spacing:9) { HStack { Text(title); Spacer(); Text(unit == " s" ? String(format:"%.1f s",value.wrappedValue) : unit == "×" ? String(format:"%.2f×",value.wrappedValue) : range.lowerBound < 0 || range.upperBound <= 2 ? String(format:"%.2f\(unit)",value.wrappedValue) : "\(Int(value.wrappedValue))\(unit)").foregroundStyle(.secondary).monospacedDigit() }.font(.system(size:12)); Slider(value:value,in:range) }
    }
}
