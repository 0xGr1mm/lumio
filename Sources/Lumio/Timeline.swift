import SwiftUI
import AVFoundation
import AppKit

func timelineTimeForClipX(_ x:Double,clipWidth:Double,timelineStart:Double,clipDuration:Double)->Double {
    timelineStart+max(0,min(1,x/max(0.000_001,clipWidth)))*clipDuration
}

struct TimelineEditor:View {
    @ObservedObject var studio:Studio
    var selectZoom:()->Void
    var selectCaption:()->Void
    var selectMarker:()->Void={}
    var selectAnnotation:()->Void={}
    @State var magnification=1.0
    @State var thumbnails:[String:[NSImage]]=[:]
    @State var showCursor=true
    @State var showZoom=true
    @State var showAudio=true
    @State var showKeys=true
    @State var showAnnotations=true
    @State var showWaveform=true
    /// Where the pointer is over an empty spot of the zoom track, and the zoom being drawn there.
    @State var zoomHover:Double?
    @State var zoomDraft:TimelineRange?
    @State var expanded=true
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                Button { studio.undoEdit() } label:{Image(systemName:"arrow.uturn.backward")}.disabled(studio.undoStack.isEmpty)
                Button { studio.redoEdit() } label:{Image(systemName:"arrow.uturn.forward")}.disabled(studio.redoStack.isEmpty)
                Divider().frame(height:18)
                Button { studio.addZoom();selectZoom() } label:{Image(systemName:"plus.magnifyingglass")}.help("Add zoom")
                Button { studio.addMarker();selectMarker() } label:{Image(systemName:"bookmark")}
                    .help("Add Marker at Playhead · M").accessibilityLabel("Add Marker").disabled(studio.duration <= 0)
                Button { studio.chooseRecordingToAdd() } label:{Image(systemName:"rectangle.stack.badge.plus")}
                    .help("Add Another Recording at the End").accessibilityLabel("Add Recording").disabled(studio.stillImage != nil || studio.source == nil)
                toolButton("select","A","cursorarrow")
                toolButton("blade","C","scissors")
                toolButton("trim","T","arrow.left.and.right")
                toolButton("position","P","move.3d")
                Button { studio.splitVideo() } label:{Image(systemName:"scissors")}.disabled(studio.duration <= 0).help("Split at Playhead · ⌘B")
                Button { studio.setExportIn() } label:{Image(systemName:"arrow.right.to.line")}.disabled(studio.duration <= 0)
                    .help("Export In at Playhead · I").accessibilityLabel("Export In")
                Button { studio.setExportOut() } label:{Image(systemName:"arrow.left.to.line")}.disabled(studio.duration <= 0)
                    .help("Export Out at Playhead · O").accessibilityLabel("Export Out")
                if studio.exportRange != nil {
                    Button { studio.clearExportRange() } label:{Image(systemName:"xmark.circle")}
                        .help("Export the whole timeline again").accessibilityLabel("Clear Export Range")
                }
                Button { studio.addTitleCard() } label:{Image(systemName:"rectangle.badge.plus")}.disabled(studio.duration <= 0 || studio.stillImage != nil)
                    .help("Add a title card before the recording").accessibilityLabel("Add Title Card")
                Button { studio.freezeFrame() } label:{Image(systemName:"snowflake")}.disabled(studio.duration <= 0 || studio.stillImage != nil)
                    .help("Freeze Frame · F · holds the frame under the playhead for two seconds").accessibilityLabel("Freeze Frame")
                Button { studio.duplicateTimelineSelection() } label:{Image(systemName:"square.on.square")}.disabled(studio.focusedTimelineItem == nil).help("Duplicate Selected Item · ⌘D").accessibilityLabel("Duplicate Selected Item")
                Button { studio.deleteTimelineSelection() } label:{Image(systemName:"trash")}.disabled(studio.focusedTimelineItem == nil).help("Delete Selected Item · ⌫").accessibilityLabel("Delete Selected Item")
                Button { studio.pasteTimelineItem() } label:{Image(systemName:"doc.on.clipboard")}.disabled(studio.timelineClipboard == nil)
                    .help(studio.timelineClipboard.map { "Paste \($0.name) at Playhead · ⌘V" } ?? "Copy a zoom, caption, clip or audio item to paste it at the playhead").accessibilityLabel("Paste at Playhead")
                if let focused=studio.focusedTimelineItem { Text("\(focused.name) selected").font(.caption).foregroundStyle(.secondary) }
                Button { studio.resetVideoClips() } label:{Image(systemName:"arrow.counterclockwise")}.help("Restore Entire Raw Recording").accessibilityLabel("Restore Entire Raw Recording")
                Menu { Toggle("Zoom",isOn:$showZoom);Toggle("Cursor",isOn:$showCursor);Toggle("Audio",isOn:$showAudio);Toggle("Keyboard Shortcuts",isOn:$showKeys);Toggle("Annotations",isOn:$showAnnotations);Toggle("Sound",isOn:$showWaveform) } label:{Image(systemName:"rectangle.split.3x1")}.help("Visible Tracks")
                Menu {
                    Button("Selection Tool        A") {studio.timelineTool="select"}
                    Button("Blade Tool       B / C") {studio.timelineTool="blade"}
                    Button("Trim Tool       T") {studio.timelineTool="trim"}
                    Button("Position Tool        P") {studio.timelineTool="position"}
                    Divider()
                    Button("Split at Playhead    ⌘B") {studio.splitVideo()}
                    Button("Copy Selected Item    ⌘C") {studio.copyTimelineSelection()}
                    Button("Cut Selected Item    ⌘X") {studio.cutTimelineSelection()}
                    Button("Paste at Playhead    ⌘V") {studio.pasteTimelineItem()}
                    Button("Duplicate Selected Item    ⌘D") {studio.duplicateTimelineSelection()}
                    Button("Delete Selected Item         ⌫") {studio.deleteTimelineSelection()}
                    Button("Trim Start to Playhead  ⌥[") {studio.trimSelectedClipToPlayhead(startEdge:true)}
                    Button("Trim End to Playhead  ⌥]") {studio.trimSelectedClipToPlayhead(startEdge:false)}
                    Divider()
                    Text("M: Add Marker · , / .: Previous / Next Marker")
                    Text("Space: Play / Pause · ←/→: One Frame")
                    Text("⌘Z: Undo · ⇧⌘Z: Redo · ⌘E: Export")
                } label:{Image(systemName:"keyboard")}.help("Keyboard Shortcuts")
                if studio.timelineTool == "blade" { Image(systemName:"scissors").foregroundStyle(accent).help("Blade Tool · C/B") }
                Spacer()
                Image(systemName:"minus.magnifyingglass")
                Slider(value:$magnification,in:1...12).frame(width:135)
                Text(String(format:"%.0f%%",magnification*100)).font(.caption).monospacedDigit().frame(width:45)
                Button { expanded.toggle() } label:{Image(systemName:expanded ? "chevron.down":"chevron.up")}
            }.buttonStyle(.plain).padding(12).background(Color(white:0.075))
            if expanded {
                GeometryReader { outer in
                    HStack(spacing:0) {
                        VStack(alignment:.leading,spacing:0) {
                            Text("").frame(height:30)
                            Image(systemName:"captions.bubble").frame(maxWidth:.infinity).frame(height:38).help("Captions")
                            if showKeys {Image(systemName:"command.square").frame(maxWidth:.infinity).frame(height:34).help("Keyboard Shortcuts")}
                            if showZoom { Image(systemName:"viewfinder").frame(maxWidth:.infinity).frame(height:40).help("Zoom") }
                            if annotationRowVisible { Image(systemName:"pencil.tip.crop.circle").frame(maxWidth:.infinity).frame(height:38).help("Annotations") }
                            Image(systemName:"record.circle").frame(maxWidth:.infinity).frame(height:65).help("Video")
                            if showWaveform { Image(systemName:"waveform.path").frame(maxWidth:.infinity).frame(height:34).help("Recorded Sound") }
                            if showAudio {Image(systemName:"waveform").frame(maxWidth:.infinity).frame(height:38).help("Audio")}
                            if showCursor { Image(systemName:"cursorarrow").frame(maxWidth:.infinity).frame(height:35).help("Cursor") }
                            Spacer()
                        }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,10).frame(width:75)
                        ScrollView(.horizontal) {
                            let width=max(100,(outer.size.width-90)*magnification)
                            VStack(spacing:0) {
                                ruler(width:width)
                                captionRow(width:width)
                                if showKeys {shortcutRow(width:width)}
                                if showZoom { zoomRow(width:width) }
                                if annotationRowVisible { annotationRow(width:width) }
                                videoRow(width:width)
                                if showWaveform { waveformRow(width:width) }
                                if showAudio {audioRow(width:width)}
                                if showCursor { cursorRow(width:width) }
                                Spacer(minLength:0)
                            }.frame(width:width)
                            .contextMenu {
                                Button(studio.timelineClipboard.map { "Paste \($0.name) at Playhead" } ?? "Paste at Playhead") { studio.pasteTimelineItem() }.disabled(studio.timelineClipboard == nil)
                            }
                            .overlay(alignment:.topLeading) {
                                Rectangle().fill(.white.opacity(0.85)).frame(width:1).overlay(alignment:.top){Circle().fill(.white).frame(width:10,height:10)}.offset(x:width*studio.position/max(0.01,studio.duration)).allowsHitTesting(false)
                            }
                            // What the next export will cover, when it is not the whole timeline.
                            .overlay(alignment:.topLeading) {
                                if let span=studio.exportRange {
                                    let scale=width/max(0.01,studio.duration)
                                    HStack(spacing:0) {
                                        Rectangle().fill(.black.opacity(0.52)).frame(width:max(0,span.start*scale))
                                        Rectangle().fill(accent.opacity(0.10)).frame(width:max(0,(span.end-span.start)*scale))
                                            .overlay(Rectangle().stroke(accent.opacity(0.8),lineWidth:2))
                                        Rectangle().fill(.black.opacity(0.52)).frame(width:max(0,(studio.duration-span.end)*scale))
                                    }.frame(height:350).allowsHitTesting(false)
                                }
                            }
                        }.background(Color(white:0.035))
                    }
                }.frame(height:350)
            }
        }.background(Color(white:0.045))
        .task(id:studio.source) { await makeThumbs() }
        .background(shortcuts.hidden())
    }
    func toolButton(_ tool:String,_ key:String,_ icon:String)->some View {
        Button {studio.timelineTool=tool} label:{
            HStack(spacing:5) {Image(systemName:icon);Text(key).font(.system(size:9,weight:.bold,design:.monospaced))}
                .foregroundStyle(studio.timelineTool == tool ? .black:.primary).padding(.horizontal,7).padding(.vertical,5)
                .background(studio.timelineTool == tool ? accent:Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:6))
        }.help(tool == "blade" ? "Blade Tool · C or B":tool.capitalized)
    }
    /// Single-key tools, Space, Delete, arrows and undo are handled by AppCoordinator so they never fire while a text field is being edited.
    var shortcuts:some View {
        HStack {
            Button("") {studio.splitVideo()}.keyboardShortcut("b",modifiers:.command)
        }
    }
    func ruler(width:Double)->some View {
        let count=max(8,Int(10*magnification))
        return HStack(spacing:0) { ForEach(0..<count,id:\.self) { n in VStack(alignment:.leading,spacing:2) { Text(String(format:"%.2f",studio.duration*Double(n)/Double(count))).font(.system(size:9,design:.monospaced));Rectangle().frame(width:1,height:5) }.frame(width:width/Double(count),alignment:.leading) } }
            .foregroundStyle(.gray).frame(height:30).contentShape(Rectangle()).gesture(seekGesture(width:width))
            .overlay(alignment:.leading) { markerPins(width:width) }
    }
    /// Marker flags on the ruler: click to jump, drag to move, right-click to rename or delete.
    func markerPins(width:Double)->some View {
        ForEach(studio.markers) { marker in
            MarkerPin(studio:studio,markerID:marker.id,width:width,select:selectMarker)
        }
    }
    func zoomRow(width:Double)->some View {
        let automatic=autoZoomClips(samples:studio.timelinePointerSamples,settings:studio.motion,duration:studio.duration,typing:studio.timelineTypingTimes)
        return ZStack(alignment:.leading) {
            Rectangle().fill(Color.purple.opacity(0.025)).frame(width:width,height:40).contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point)=phase { zoomHover=point.x } else { zoomHover=nil }
                }
                .gesture(zoomDrawGesture(width:width))
            if let preview=zoomDraft ?? zoomHover.map({ studio.draftZoomRange(at:timelineTime($0,width:width)) }),studio.duration>0 {
                let length=max(0.1,studio.duration)
                RoundedRectangle(cornerRadius:7)
                    .fill(Color.purple.opacity(zoomDraft == nil ? 0.16:0.42))
                    .overlay(RoundedRectangle(cornerRadius:7).strokeBorder(style:StrokeStyle(lineWidth:1,dash:zoomDraft == nil ? [4,3]:[]))
                        .foregroundStyle(.white.opacity(zoomDraft == nil ? 0.5:0.85)))
                    .overlay(Label(zoomDraft == nil ? "Add zoom":String(format:"%.2f – %.2f s",preview.start,preview.end),systemImage:"plus.magnifyingglass")
                        .font(.system(size:9,weight:.medium).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7).padding(.horizontal,6))
                    .frame(width:max(20,width*preview.length/length),height:30)
                    .offset(x:width*preview.start/length)
                    .allowsHitTesting(false)
            }
            ForEach(automatic) { z in
                TimelineRangeBlock(range:TimelineRange(start:z.start,end:z.end),width:width,duration:studio.duration,fill:Color.purple.opacity(0.45),selectOnDrag:false,
                    bounds:{ timelineNeighbourBounds(automatic.filter { $0.id != z.id }.map { TimelineRange(start:$0.start,end:$0.end) }+studio.zooms.map { TimelineRange(start:$0.start,end:$0.end) },around:TimelineRange(start:z.start,end:z.end),duration:studio.duration) },
                    snapTargets:{ studio.timelineSnapTargets(excluding:nil) },
                    onSelect:{ studio.selectAutomaticZoom(z);selectZoom() },
                    onCommit:{ range in
                        // Dragging an automatic zoom turns the automatic zooms into editable ones, then applies the drag.
                        studio.selectAutomaticZoom(z);selectZoom()
                        if let id=studio.selectedZoom { studio.setZoomRange(id,to:range) }
                    }) { range,dragging in zoomLabel(scale:z.scale,range:range,dragging:dragging) }
                .accessibilityLabel("Automatic Zoom")
                .accessibilityValue(String(format:"%.2f to %.2f seconds",z.start,z.end))
                .help("Click to customize this zoom in the inspector, or drag it or its edges")
                .contextMenu {
                    Button("Edit Zoom") { studio.selectAutomaticZoom(z); selectZoom() }
                    Button("Copy") { studio.selectAutomaticZoom(z); studio.copyTimelineSelection() }
                    Button("Duplicate") { studio.selectAutomaticZoom(z); studio.duplicateTimelineSelection() }
                    Divider()
                    Button("Delete",role:.destructive) { studio.selectAutomaticZoom(z); studio.deleteTimelineSelection() }
                }
            }
            ForEach(studio.zooms) { z in
                TimelineRangeBlock(range:TimelineRange(start:z.start,end:z.end),width:width,duration:studio.duration,
                    fill:studio.selectedZoom == z.id ? Color.purple:Color.purple.opacity(0.55),selected:studio.selectedZoom == z.id,
                    bounds:{ timelineNeighbourBounds(studio.zooms.filter { $0.id != z.id }.map { TimelineRange(start:$0.start,end:$0.end) },around:TimelineRange(start:z.start,end:z.end),duration:studio.duration) },
                    snapTargets:{ studio.timelineSnapTargets(excluding:z.id) },
                    onSelect:{
                        studio.focusTimeline(.zoom,id:z.id)
                        if !(studio.position>=z.start && studio.position<=z.end) { studio.position=z.start+min(z.transition,(z.end-z.start)/2);studio.seek(studio.position) }
                        selectZoom()
                    },
                    onCommit:{ studio.setZoomRange(z.id,to:$0) }) { range,dragging in zoomLabel(scale:z.scale,range:range,dragging:dragging) }
                .accessibilityLabel("Zoom")
                .accessibilityValue(String(format:"%.2f to %.2f seconds",z.start,z.end))
                .contextMenu { TimelineItemMenu(studio:studio,kind:.zoom,id:z.id) }
            }
        }.frame(height:40)
    }
    func timelineTime(_ x:Double,width:Double)->Double { max(0,min(studio.duration,x/max(1,width)*studio.duration)) }
    /// Click or drag on an empty spot of the zoom track to add a zoom there: a click adds a short slice, a drag adds what was drawn.
    func zoomDrawGesture(width:Double)->some Gesture {
        DragGesture(minimumDistance:0).onChanged { value in
            guard studio.duration>0,studio.stillImage == nil else { return }
            let from=timelineTime(value.startLocation.x,width:width),to=timelineTime(value.location.x,width:width)
            zoomHover=value.location.x
            zoomDraft = abs(to-from)<0.06 ? studio.draftZoomRange(at:from):TimelineRange(start:min(from,to),end:max(from,to))
        }.onEnded { _ in
            defer { zoomDraft=nil }
            guard let draft=zoomDraft,studio.duration>0,studio.stillImage == nil else { return }
            let snapped=snappedTimelineEdges(draft,snapTargets:NSEvent.modifierFlags.contains(.command) ? []:studio.timelineSnapTargets(excluding:nil),
                                             threshold:8/max(1,width)*studio.duration,minLength:0.1)
            if studio.addZoom(over:snapped) != nil { selectZoom() }
        }
    }
    var annotationRowVisible:Bool { showAnnotations && (!studio.annotations.isEmpty || studio.annotationEditing) }
    func annotationRow(width:Double)->some View {
        ZStack(alignment:.leading) {
            Rectangle().fill(Color.pink.opacity(0.025)).frame(width:width,height:38).contentShape(Rectangle()).gesture(seekGesture(width:width))
            ForEach(studio.annotations) { item in
                TimelineRangeBlock(range:TimelineRange(start:item.start,end:item.end),width:width,duration:studio.duration,height:28,cornerRadius:6,
                    fill:Color.pink.opacity(studio.selectedAnnotation == item.id ? 0.75:0.42),selected:studio.selectedAnnotation == item.id,
                    bounds:{ (0,studio.duration) },
                    snapTargets:{ studio.timelineSnapTargets(excluding:item.id)+studio.annotations.filter { $0.id != item.id }.flatMap { [$0.start,$0.end] } },
                    onSelect:{
                        studio.focusTimeline(.annotation,id:item.id)
                        if !(studio.position>=item.start && studio.position<=item.end) { studio.position=item.start+min(0.3,(item.end-item.start)/2);studio.seek(studio.position) }
                        selectAnnotation()
                    },
                    onCommit:{ studio.setAnnotationRange(item.id,to:$0) }) { range,dragging in
                    HStack(spacing:4) {
                        Image(systemName:item.symbol)
                        Text(dragging ? String(format:"%.2f – %.2f s",range.start,range.end):item.kind == "Text" ? item.text:item.kind).lineLimit(1)
                    }.font(.system(size:9,weight:.medium).monospacedDigit()).frame(maxWidth:.infinity,alignment:.leading)
                }
                .accessibilityLabel(item.kind)
                .contextMenu { TimelineItemMenu(studio:studio,kind:.annotation,id:item.id) }
            }
        }.frame(height:38)
    }
    func zoomLabel(scale:Double,range:TimelineRange,dragging:Bool)->some View {
        Text(dragging ? String(format:"%.2f – %.2f s",range.start,range.end):String(format:"%.1f×",scale))
            .font(.system(size:10,weight:dragging ? .semibold:.regular).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.6)
    }
    func captionRow(width:Double)->some View {
        ZStack(alignment:.leading) {
            Rectangle().fill(Color.orange.opacity(0.025))
            ForEach(studio.captions) { cue in
                TimelineRangeBlock(range:TimelineRange(start:cue.start,end:cue.end),width:width,duration:studio.duration,height:28,minLength:0.2,cornerRadius:6,
                    fill:studio.selectedCaption == cue.id ? Color.orange.opacity(0.72):Color.orange.opacity(0.38),selected:studio.selectedCaption == cue.id,
                    bounds:{ timelineNeighbourBounds(studio.captions.filter { $0.id != cue.id }.map { TimelineRange(start:$0.start,end:$0.end) },around:TimelineRange(start:cue.start,end:cue.end),duration:studio.duration) },
                    snapTargets:{ studio.timelineSnapTargets(excluding:cue.id) },
                    onSelect:{
                        studio.focusTimeline(.caption,id:cue.id)
                        if !(studio.position>=cue.start && studio.position<=cue.end) { studio.position=cue.start;studio.seek(cue.start) }
                        selectCaption()
                    },
                    onCommit:{ studio.setCaptionRange(cue.id,to:$0) }) { range,dragging in
                    Text(dragging ? String(format:"%.2f – %.2f s",range.start,range.end):cue.text)
                        .font(.system(size:9,weight:.medium).monospacedDigit()).lineLimit(1).frame(maxWidth:.infinity,alignment:.leading)
                }
                .contextMenu {TimelineItemMenu(studio:studio,kind:.caption,id:cue.id)}
            }
        }.frame(height:38)
    }
    func shortcutRow(width:Double)->some View {
        ZStack(alignment:.leading) {Rectangle().fill(Color.cyan.opacity(0.025));ForEach(studio.timelineKeyboardSamples.filter{!($0.typing ?? false)}){sample in RoundedRectangle(cornerRadius:4).fill(Color.cyan.opacity(0.62)).overlay(Text(sample.display).font(.system(size:9,weight:.semibold))).frame(width:max(24,width*studio.keyboardStyle.duration/max(0.1,studio.duration)),height:24).offset(x:width*sample.time/max(0.1,studio.duration))}}
            .frame(height:34).contentShape(Rectangle()).gesture(seekGesture(width:width))
    }
    func audioRow(width:Double)->some View {
        ZStack(alignment:.leading) {
            Rectangle().fill(Color.green.opacity(0.025)).frame(width:width,height:38).contentShape(Rectangle()).gesture(seekGesture(width:width))
            ForEach(studio.audioTracks) { track in
                let length=min(track.duration,max(0,studio.duration-track.timelineStart))
                TimelineRangeBlock(range:TimelineRange(start:track.timelineStart,end:track.timelineStart+length),width:width,duration:studio.duration,height:28,resizable:false,cornerRadius:5,
                    fill:track.muted ? Color.gray.opacity(0.3):Color.green.opacity(studio.selectedAudioTrack == track.id ? 0.72:0.42),selected:studio.selectedAudioTrack == track.id,
                    bounds:{ (0,max(studio.duration,track.timelineStart+length)) },
                    snapTargets:{ studio.timelineSnapTargets(excluding:nil) },
                    onSelect:{ studio.focusTimeline(.audio,id:track.id) },
                    onCommit:{ studio.moveAudioTrack(track.id,toTimelineStart:$0.start) }) { _,_ in
                    Image(systemName:track.kind == "Voiceover" ? "mic.fill":"waveform")
                }
                .help("\(track.name) · drag to move it on the timeline")
                .contextMenu{TimelineItemMenu(studio:studio,kind:.audio,id:track.id)}
            }
        }.frame(height:38)
    }
    func videoRow(width:Double)->some View {
        ZStack(alignment:.leading) {
            ForEach(studio.clipPlacements) { placement in
                VideoClipBlock(studio:studio,clipID:placement.id,timelineStart:placement.timelineStart,totalWidth:width,thumbnail:thumbnail(at:source:))
            }
        }.frame(width:width,height:65,alignment:.leading)
            .background(TimelineCursorArea(blade:studio.timelineTool == "blade"))
            .help("Select a clip, drag its edges to trim or restore frames, and drag its body to move it. C activates the Blade tool.")
    }
    /// The recording's own loudness on the timeline clock, so cuts can be placed on what is heard.
    func waveformRow(width:Double)->some View {
        Canvas { context,size in
            let duration=max(0.1,studio.duration)
            for placement in studio.clipPlacements {
                let from=max(0,width*placement.timelineStart/duration),to=min(width,width*placement.timelineEnd/duration)
                guard to>from else { continue }
                var path=Path()
                var x=from.rounded(.down)
                while x<to {
                    let level=Double(studio.waveformLevel(at:x/width*duration,clip:placement.clip))
                    let height=max(1,level*(size.height-8))
                    path.move(to:CGPoint(x:x+0.5,y:size.height/2-height/2))
                    path.addLine(to:CGPoint(x:x+0.5,y:size.height/2+height/2))
                    x+=1
                }
                context.stroke(path,with:.color(.teal.opacity(0.85)),lineWidth:1)
            }
        }
        .frame(height:34).background(Color.teal.opacity(0.03)).contentShape(Rectangle()).gesture(seekGesture(width:width))
        .help("The recording's sound. Louder moments are taller; silent stretches are flat.")
    }
    func cursorRow(width:Double)->some View {
        Canvas { context,size in
            var path=Path()
            let samples=studio.timelinePointerSamples
            let strideBy=max(1,samples.count/1000)
            for i in stride(from:0,to:samples.count,by:strideBy) {
                let p=samples[i],point=CGPoint(x:width*p.time/max(0.1,studio.duration),y:5+p.y*23)
                if i==0 { path.move(to:point) } else { path.addLine(to:point) }
                if p.pressed { context.fill(Path(ellipseIn:CGRect(x:point.x-2,y:13,width:4,height:4)),with:.color(.yellow)) }
            }
            context.stroke(path,with:.color(.green.opacity(0.7)),lineWidth:1)
        }.frame(height:35).background(Color.green.opacity(0.03)).contentShape(Rectangle()).gesture(seekGesture(width:width))
    }
    func seekGesture(width:Double)->some Gesture { DragGesture(minimumDistance:0).onChanged { v in studio.position=max(0,min(studio.duration,v.location.x/width*studio.duration));studio.seek(studio.position) } }
    /// Twelve frames for the opened recording and for every recording added to the project, keyed by file path.
    func makeThumbs() async {
        thumbnails=[:];guard let source=studio.source,studio.stillImage == nil else{return}
        var files:[(key:String,url:URL,length:Double)]=[("",source,studio.sourceDuration)]
        files+=studio.addedSources.map { (key:$0.key,url:URL(fileURLWithPath:$0.key),length:$0.value) }
        for file in files {
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:file.url));generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:200,height:120)
            var frames:[NSImage]=[]
            for i in 0..<12 {
                if Task.isCancelled{return}
                if let result=try? await generator.image(at:CMTime(seconds:file.length*Double(i)/12,preferredTimescale:600)) { frames.append(NSImage(cgImage:result.image,size:.zero)) }
            }
            thumbnails[file.key]=frames
            if Task.isCancelled{return}
        }
    }
    /// The thumbnail nearest a source time in the file a clip plays, so a clip shows a filmstrip of what it contains.
    func thumbnail(at sourceTime:Double,source:String?)->NSImage? {
        let frames=thumbnails[source ?? ""] ?? []
        let length=source.flatMap { studio.addedSources[$0] } ?? studio.sourceDuration
        guard !frames.isEmpty,length>0 else{return nil}
        let index=max(0,min(frames.count-1,Int(sourceTime/length*Double(frames.count))))
        return frames[index]
    }
}

struct VideoClipBlock:View {
    @ObservedObject var studio:Studio
    let clipID:UUID
    let timelineStart:Double
    let totalWidth:Double
    let thumbnail:(Double,String?)->NSImage?
    @State private var dragOffset=0.0
    @State private var edgeOriginal:VideoClip?
    @State private var edgeDuration=0.0

    var body:some View {
        if let clip=studio.videoClips.first(where:{$0.id == clipID}) {
            let clipWidth=max(12,totalWidth*clip.duration/max(0.01,studio.duration))
            ZStack(alignment:.leading) {
                RoundedRectangle(cornerRadius:6).fill((clip.isHold ? Color.teal:Color.blue).opacity(studio.selectedClip == clipID ? 0.66:0.38))
                filmstrip(clip:clip,clipWidth:clipWidth)
                RoundedRectangle(cornerRadius:6).stroke(studio.selectedClip == clipID ? accent:Color.blue.opacity(0.9),lineWidth:studio.selectedClip == clipID ? 2:1)
                VStack(alignment:.leading,spacing:2) {
                    HStack(spacing:4) {
                        if clip.isHold { Image(systemName:"snowflake").font(.system(size:9)) }
                        Text(clip.isHold ? "Held Frame":"Clip \((studio.videoClips.firstIndex(where:{$0.id == clipID}) ?? 0)+1)").fontWeight(.semibold)
                    }
                    Text(clip.isHold ? String(format:"%.1f s · from %.2f s",clip.duration,clip.sourceStart)
                                     : String(format:"Source %.2f–%.2f · Position %.2f",clip.sourceStart,clip.sourceEnd,clip.timelineStart)+(abs(clip.speed-1)>0.001 ? String(format:" · %g×",clip.speed):"")).foregroundStyle(.white.opacity(0.75))
                }.font(.system(size:9)).padding(.horizontal,10).allowsHitTesting(false)
                Rectangle().fill(Color.white.opacity(0.001))
                    .frame(width:max(1,clipWidth-28),height:54).offset(x:14)
                    .contentShape(Rectangle()).highPriorityGesture(clipGesture(clip:clip,clipWidth:clipWidth))
                if studio.selectedClip == clipID {
                    edgeHandle(start:true,clip:clip)
                    edgeHandle(start:false,clip:clip).offset(x:clipWidth-14)
                }
            }
            .frame(width:clipWidth,height:54)
            .offset(x:totalWidth*timelineStart/max(0.01,studio.duration)+dragOffset)
            .contentShape(Rectangle()).coordinateSpace(name:"clip-\(clipID.uuidString)")
            .zIndex(studio.selectedClip == clipID ? 10:Double(studio.videoClips.firstIndex(where:{$0.id == clipID}) ?? 0))
            .contextMenu {
                Button("Split at Playhead") {studio.splitVideo()}
                Menu("Freeze Frame Here") {
                    ForEach([1.0,2.0,3.0,5.0],id:\.self) { length in
                        Button(String(format:"%g seconds",length)) { studio.freezeFrame(seconds:length) }
                    }
                }.disabled(studio.videoClips.first(where:{ $0.id == clipID })?.isHold ?? false)
                Menu("Transition at This Cut") {
                    Button("None") { studio.setClipTransition(clipID,to:0) }
                    Divider()
                    ForEach([0.3,0.5,1.0],id:\.self) { length in
                        Button(String(format:"Cross Dissolve · %.1f s",length)) { studio.setClipTransition(clipID,to:length,kind:"Cross Dissolve") }
                    }
                    Divider()
                    ForEach([0.3,0.5,1.0],id:\.self) { length in
                        Button(String(format:"Dip to Black · %.1f s",length)) { studio.setClipTransition(clipID,to:length,kind:"Dip to Black") }
                    }
                }.disabled(studio.videoClips.first(where:{ $0.id == clipID })?.timelineStart ?? 0 <= 0.001)
                Menu("Speed") {
                    ForEach([0.25,0.5,1.0,1.5,2.0,3.0,4.0],id:\.self) { value in
                        Button(String(format:"%g×",value)) {studio.setClipSpeed(clipID,to:value)}
                    }
                }
                Divider()
                TimelineItemMenu(studio:studio,kind:.clip,id:clipID)
            }
        }
    }

    /// Frames sampled across the clip's own source range, so cuts and speed changes show what is really in the clip.
    func filmstrip(clip:VideoClip,clipWidth:Double)->some View {
        let count=max(1,min(14,Int(clipWidth/86)))
        let frameWidth=clipWidth/Double(count)
        return HStack(spacing:0) {
            ForEach(0..<count,id:\.self) { index in
                let time=clip.sourceStart+(clip.sourceEnd-clip.sourceStart)*(Double(index)+0.5)/Double(count)
                if let image=thumbnail(time,clip.source) {
                    Image(nsImage:image).resizable().aspectRatio(contentMode:.fill).frame(width:frameWidth,height:54).clipped()
                }
            }
        }.frame(width:clipWidth,height:54,alignment:.leading).clipped().opacity(0.48).allowsHitTesting(false)
    }

    func clipGesture(clip:VideoClip,clipWidth:Double)->some Gesture {
        DragGesture(minimumDistance:0,coordinateSpace:.named("clip-\(clipID.uuidString)")).onChanged { value in
            guard studio.timelineTool == "select" || studio.timelineTool == "position" else {return}
            if abs(value.translation.width)>3 {dragOffset=value.translation.width}
        }.onEnded { value in
            defer {dragOffset=0}
            studio.focusTimeline(.clip,id:clipID)
            let local=max(0,min(clipWidth,value.location.x))
            if studio.timelineTool == "blade" {
                studio.splitVideo(at:timelineTimeForClipX(local,clipWidth:clipWidth,timelineStart:timelineStart,clipDuration:clip.duration))
            } else if abs(value.translation.width)>8 && (studio.timelineTool == "select" || studio.timelineTool == "position") {
                let delta=Double(value.translation.width)/totalWidth*studio.duration
                studio.moveClip(clipID,toTimelineStart:timelineStart+delta,snapThreshold:max(0.02,studio.duration/totalWidth*8))
            } else {
                studio.position=timelineTimeForClipX(local,clipWidth:clipWidth,timelineStart:timelineStart,clipDuration:clip.duration)
                studio.seek(studio.position)
            }
        }
    }

    func edgeHandle(start:Bool,clip:VideoClip)->some View {
        RoundedRectangle(cornerRadius:3).fill(accent).frame(width:14,height:54)
            .overlay(Capsule().fill(.black.opacity(0.75)).frame(width:2,height:25))
            .contentShape(Rectangle())
            .highPriorityGesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
                if edgeOriginal == nil {edgeOriginal=clip;edgeDuration=studio.duration;studio.timelineFocus = .clip}
                guard let original=edgeOriginal else{return}
                let delta=Double(value.translation.width)/totalWidth*edgeDuration
                studio.updateClipEdge(clipID,startEdge:start,to:(start ? original.sourceStart:original.sourceEnd)+delta*original.rate)
            }.onEnded {_ in edgeOriginal=nil;edgeDuration=0})
            .help(start ? "Drag the left edge · trimmed frames remain recoverable":"Drag the right edge · extend it to restore frames")
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(start ? "Clip left trim handle":"Clip right trim handle")
    }
}

struct TimelineCursorArea:NSViewRepresentable {
    var blade:Bool
    func makeNSView(context:Context)->TimelineCursorView {let view=TimelineCursorView();view.blade=blade;return view}
    func updateNSView(_ view:TimelineCursorView,context:Context) {view.blade=blade;view.window?.invalidateCursorRects(for:view)}
}

final class TimelineCursorView:NSView {
    var blade=false
    override func resetCursorRects() {
        super.resetCursorRects()
        guard blade,let image=NSImage(systemSymbolName:"scissors",accessibilityDescription:"Cut") else {
            addCursorRect(bounds,cursor:.arrow);return
        }
        image.size=NSSize(width:22,height:22)
        addCursorRect(bounds,cursor:NSCursor(image:image,hotSpot:NSPoint(x:11,y:11)))
    }
}

/// One marker flag on the ruler. The drag is measured in window coordinates and shown from local state,
/// so the flag follows the pointer exactly instead of chasing its own new position.
struct MarkerPin:View {
    @ObservedObject var studio:Studio
    let markerID:UUID
    let width:Double
    var select:()->Void
    @State private var live:Double?
    var body:some View {
        if let marker=studio.markers.first(where:{$0.id == markerID}) {
            let duration=max(0.1,studio.duration)
            let time=live ?? marker.time
            VStack(spacing:0) {
                Image(systemName:"bookmark.fill").font(.system(size:9)).foregroundStyle(marker.color.color)
                Rectangle().fill(marker.color.color.opacity(0.7)).frame(width:1,height:9)
            }
            .frame(width:16,height:26)
            .background(studio.selectedMarker == markerID ? Color.white.opacity(0.14):.clear,in:RoundedRectangle(cornerRadius:4))
            .contentShape(Rectangle())
            .offset(x:width*time/duration-8)
            .help(live == nil ? "\(marker.name) · drag to move it":String(format:"%.2f s",time))
            .accessibilityLabel("Marker \(marker.name)")
            .accessibilityValue(String(format:"%.2f seconds",marker.time))
            .onTapGesture { studio.selectedMarker=markerID;studio.position=marker.time;studio.seek(marker.time);select() }
            .gesture(DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
                if live == nil { studio.selectedMarker=markerID }
                live=max(0,min(studio.duration,marker.time+value.translation.width/width*duration))
            }.onEnded { _ in
                if let live { studio.moveMarker(markerID,to:live) }
                live=nil
            })
            .contextMenu {
                Button("Rename in the Markers Panel") { studio.selectedMarker=markerID;select() }
                Button("Go to Marker") { studio.position=marker.time;studio.seek(marker.time) }
                Divider()
                Button("Delete Marker",role:.destructive) { studio.deleteMarker(markerID) }
            }
        }
    }
}
