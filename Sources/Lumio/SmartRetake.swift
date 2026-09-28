import SwiftUI
import AVKit
import Carbon

struct RetakeMarker:Codable,Equatable,Identifiable {
    var id=UUID()
    var start:Double
    var retryStart:Double
    var end:Double
    var choice:String? = nil
}

func normalizedRetakes(_ markers:[RetakeMarker],duration:Double)->[RetakeMarker] {
    guard duration.isFinite,duration>0 else{return []}
    var ids=Set<UUID>()
    return markers.prefix(500).compactMap { original in
        guard original.start.isFinite,original.retryStart.isFinite,original.end.isFinite else{return nil}
        var m=original
        m.start=max(0,min(duration,m.start));m.retryStart=max(m.start,min(duration,m.retryStart));m.end=max(m.retryStart,min(duration,m.end))
        guard m.retryStart-m.start>=0.04,m.end-m.retryStart>=0.04 else{return nil}
        if !ids.insert(m.id).inserted {m.id=UUID()}
        if m.choice != "Original" && m.choice != "Retake" {m.choice=nil}
        return m
    }
}

/// Timeline intervals to close, after resolving source time through every clip.
func retakeRemovalRanges(clips:[VideoClip],start:Double,end:Double)->[VideoCut] {
    var result:[VideoCut]=[]
    let cuts=clips.compactMap { c -> VideoCut? in
        let a=max(start,c.sourceStart),b=min(end,c.sourceEnd)
        guard b>a else{return nil}
        return VideoCut(start:c.timelineTime(forSource:a),end:c.timelineTime(forSource:b))
    }.sorted{$0.start<$1.start}
    for cut in cuts {
        if let last=result.last,last.end>=cut.start {result[result.count-1].end=max(last.end,cut.end)}
        else {result.append(cut)}
    }
    return result
}
func retakeRippleTime(_ time:Double,cuts:[VideoCut])->Double {
    time-cuts.reduce(0){$0+max(0,min(time,$1.end)-$1.start)}
}
func retakeRippleClips(_ clips:[VideoClip],cuts:[VideoCut])->[VideoClip] {
    clips.flatMap { clip in
        keptVideoRanges(start:clip.timelineStart,end:clip.timelineStart+clip.duration,cuts:cuts).enumerated().compactMap { index,range in
            guard range.end-range.start>=0.04 else{return nil}
            return VideoClip(id:index==0 ? clip.id:UUID(),sourceStart:clip.sourceTime(forTimeline:range.start),sourceEnd:clip.sourceTime(forTimeline:range.end),timelineStart:retakeRippleTime(range.start,cuts:cuts),speed:clip.speed)
        }
    }
}

@MainActor extension Studio {
    var retakeElapsed:Double {max(0,ProcessInfo.processInfo.systemUptime-(recordingUptime ?? ProcessInfo.processInfo.systemUptime))}
    func toggleRetake() {
        guard recording,!busy,pausedAt == nil,!deviceRecording else{return}
        if activeRetake != nil {finishActiveRetake()}
        else {
            guard recordingRetakes.count<500 else{message="This recording already has 500 retakes.";return}
            let now=retakeElapsed
            let start=max(recordingRetakes.last?.end ?? 0,now-retakeLookback)
            guard now-start>=0.1 else{return}
            activeRetake=RetakeMarker(start:start,retryStart:now,end:now)
        }
        saveRecordingRetakes()
    }
    func finishActiveRetake() {
        guard var marker=activeRetake else{return}
        marker.end=retakeElapsed
        if marker.end-marker.retryStart>=0.04 {recordingRetakes.append(marker)}
        activeRetake=nil
    }
    func saveRecordingRetakes() {
        guard let url=recordingURL else{return}
        do {try JSONEncoder().encode(recordingRetakes).write(to:url.appendingPathExtension("retakes.json"),options:.atomic)}
        catch {message="Retake markers could not be saved: \(error.localizedDescription)"}
    }
    func loadRetakes(_ url:URL) async {
        retakes=[]
        let sidecar=url.appendingPathExtension("retakes.json")
        guard FileManager.default.fileExists(atPath:sidecar.path) else{return}
        do {
            let data=try await Task.detached(priority:.userInitiated) {try readBoundedData(sidecar)}.value
            retakes=normalizedRetakes(try JSONDecoder().decode([RetakeMarker].self,from:data),duration:sourceDuration)
        }
        catch {message="The video opened, but its retake markers could not be read."}
    }
    func addRetakeAtPlayhead() {
        guard !busy,!recording,!voiceoverRecording,!captionGenerating,retakes.count<500,
              let p=placement(containing:position) else{return}
        let sourceTime=p.clip.sourceTime(forTimeline:position)
        let m=RetakeMarker(start:max(0,sourceTime-10),retryStart:sourceTime,end:min(sourceDuration,sourceTime+10))
        guard !normalizedRetakes([m],duration:sourceDuration).isEmpty else{message="Place the playhead between the original attempt and the retake.";return}
        retakes.append(m)
    }
    func chooseRetake(_ id:UUID,keepRetry:Bool) {
        guard !busy,!recording,!voiceoverRecording,!captionGenerating,
              let marker=retakes.first(where:{$0.id==id}),marker.choice==nil,
              normalizedRetakes([marker],duration:sourceDuration).count==1 else{return}
        let start=keepRetry ? marker.start:marker.retryStart
        let end=keepRetry ? marker.retryStart:marker.end
        let cuts=retakeRemovalRanges(clips:videoClips,start:start,end:end)
        guard !cuts.isEmpty else{message="This attempt is no longer in the timeline. Undo its removal or restore a saved version first.";return}
        let keptStart=keepRetry ? marker.retryStart:marker.start,keptEnd=keepRetry ? marker.end:marker.retryStart
        guard videoClips.contains(where:{min($0.sourceEnd,keptEnd)-max($0.sourceStart,keptStart)>=0.04}) else{message="The chosen attempt is no longer in the timeline. Restore it before choosing this take.";return}
        let clips=retakeRippleClips(videoClips,cuts:cuts)
        guard !clips.isEmpty else{message="At least one clip must remain.";return}
        var edit=snapshot
        edit.clips=clips
        edit.retakes=retakes.map {var m=$0;if m.id==id {m.choice=keepRetry ? "Retake":"Original"};return m}
        edit.zooms=zooms.compactMap {z in
            var copy=z;copy.start=retakeRippleTime(z.start,cuts:cuts);copy.end=retakeRippleTime(z.end,cuts:cuts)
            guard copy.end-copy.start>=0.1 else{return nil};copy.transition=min(copy.transition,(copy.end-copy.start)/2);return copy
        }
        edit.captions=captions.compactMap {cue in
            var copy=cue;copy.start=retakeRippleTime(cue.start,cuts:cuts);copy.end=retakeRippleTime(cue.end,cuts:cuts)
            guard copy.end-copy.start>=0.04 else{return nil}
            copy.words=cue.words.compactMap {word in
                var w=word;w.start=retakeRippleTime(w.start,cuts:cuts);w.end=retakeRippleTime(w.end,cuts:cuts);return w.end-w.start>=0.01 ? w:nil
            }
            if !cue.words.isEmpty {copy.text=copy.words.map(\.text).joined(separator:" ");if copy.words.isEmpty{return nil}}
            return copy
        }
        edit.annotations=remappedAnnotations(annotations) { retakeRippleTime($0,cuts:cuts) }
        invalidateSensitiveScan()
        edit.markers=remappedMarkers(markers) { retakeRippleTime($0,cuts:cuts) }
        edit.audioTracks=audioTracks.flatMap {track in
            keptVideoRanges(start:track.timelineStart,end:track.timelineStart+track.duration,cuts:cuts).enumerated().compactMap {index,range in
                guard range.end-range.start>=0.04 else{return nil}
                var t=track;t.id=index==0 ? track.id:UUID();t.timelineStart=retakeRippleTime(range.start,cuts:cuts)
                t.sourceStart=track.sourceStart+range.start-track.timelineStart;t.sourceEnd=t.sourceStart+range.end-range.start
                return t
            }
        }
        player.pause();playing=false
        let target=retakeRippleTime(position,cuts:cuts)
        undoStack.append(snapshot);if undoStack.count>80{undoStack.removeFirst()};redoStack=[]
        restore(edit);trimTimelineItemsToDuration();seek(target)
    }
}

struct HotKey {
    var id:UInt32
    var keyCode:UInt32
    var modifiers:UInt32
    var name:String
    var action:()->Void
}

/// Carbon hot keys work while another app is focused, without monitoring typed text.
@MainActor final class RecordingHotKeys {
    private var refs:[UInt32:EventHotKeyRef]=[:]
    private var handler:EventHandlerRef?
    private var keys:[UInt32:HotKey]=[:]
    init(_ list:[HotKey]) {
        for key in list {keys[key.id]=key}
        var type=EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        let context=Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(),{_,event,context in
            guard let context,let event else{return OSStatus(eventNotHandledErr)}
            var pressed=EventHotKeyID()
            let status=GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&pressed)
            guard status==noErr else{return status}
            let owner=Unmanaged<RecordingHotKeys>.fromOpaque(context).takeUnretainedValue()
            let id=pressed.id
            Task { @MainActor in owner.run(id) }
            return noErr
        },1,&type,context,&handler)
    }
    func run(_ id:UInt32) { keys[id]?.action() }
    /// Registers or releases every shortcut; returns the names that another app already owns.
    @discardableResult func setEnabled(_ enabled:Bool)->[String] {
        for ref in refs.values {UnregisterEventHotKey(ref)}
        refs=[:]
        guard enabled else{return []}
        guard handler != nil else{return keys.values.map(\.name)}
        var unavailable:[String]=[]
        for key in keys.values.sorted(by:{$0.id<$1.id}) {
            var ref:EventHotKeyRef?
            if RegisterEventHotKey(key.keyCode,key.modifiers,EventHotKeyID(signature:0x4C554D52,id:key.id),GetApplicationEventTarget(),0,&ref)==noErr,let ref {refs[key.id]=ref}
            else {unavailable.append(key.name)}
        }
        return unavailable
    }
    deinit {for ref in refs.values {UnregisterEventHotKey(ref)};if let handler {RemoveEventHandler(handler)}}
}

@MainActor extension Studio {
    /// Paused ranges are written on the recording clock and cut automatically when the recording opens.
    func saveRecordingPauses() {
        guard let url=recordingURL else{return}
        try? JSONEncoder().encode(recordingPauses).write(to:url.appendingPathExtension("pauses.json"),options:.atomic)
    }
    func loadRecordingPauses(_ url:URL)->[VideoCut] {
        guard let data=try? readBoundedData(url.appendingPathExtension("pauses.json"),maxBytes:2_000_000),
              let cuts=try? JSONDecoder().decode([VideoCut].self,from:data) else{return []}
        return cuts.prefix(2_000).filter{$0.start.isFinite && $0.end.isFinite && $0.start>=0 && $0.end-$0.start>=0.05}
    }
}

struct RetakePreview:Identifiable {var id=UUID();var title:String;var start:Double;var end:Double}
struct RetakePanel:View {
    @ObservedObject var studio:Studio
    @State private var preview:RetakePreview?
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Smart Retake").font(.headline)
            Text("Make a mistake? Press ⌃⌥R while recording, repeat the action, then press again to finish. Stopping the recording also finishes the retake.").font(.caption).foregroundStyle(.secondary)
            Button {studio.addRetakeAtPlayhead()} label:{Label("Mark at Playhead",systemImage:"plus")}.disabled(studio.stillImage != nil || studio.source == nil)
                .help("For existing videos: place the playhead where the retry begins, then adjust the source times below.")
            if studio.retakes.isEmpty {Text("No retakes yet. Your original recording is always preserved.").font(.caption).foregroundStyle(.secondary)}
            ForEach(Array(studio.retakes.enumerated()),id:\.element.id) {index,marker in
                VStack(alignment:.leading,spacing:10) {
                    Text("Take \(index+1)").fontWeight(.semibold)
                    if let choice=marker.choice {
                        Label("\(choice) kept",systemImage:"checkmark.circle.fill").foregroundStyle(accent)
                        Text("Undo to change this choice, or restore a version. Both attempts remain in the raw recording.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        sourceTime("Original starts",id:marker.id,keyPath:\.start)
                        sourceTime("Retake starts",id:marker.id,keyPath:\.retryStart)
                        sourceTime("Retake ends",id:marker.id,keyPath:\.end)
                    }
                    HStack {
                        Button {show(marker,retry:false)} label:{Label("Original",systemImage:"play.fill")}
                        Button {show(marker,retry:true)} label:{Label("Retake",systemImage:"play.fill")}
                    }.font(.caption).disabled(normalizedRetakes([marker],duration:studio.sourceDuration).isEmpty)
                    if marker.choice==nil {
                        HStack {
                            Button("Keep Original") {studio.chooseRetake(marker.id,keepRetry:false)}
                            Button("Use Retake") {studio.chooseRetake(marker.id,keepRetry:true)}.tint(accent)
                        }.font(.caption).disabled(normalizedRetakes([marker],duration:studio.sourceDuration).isEmpty)
                        Text("Removes the other attempt wherever it appears and closes the gaps across all tracks.").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(12).frame(maxWidth:.infinity,alignment:.leading).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:10))
            }
            Text("Source times are in seconds. Save your .lumio project to keep adjusted markers and choices.").font(.caption2).foregroundStyle(.secondary)
        }.disabled(studio.busy || studio.recording || studio.voiceoverRecording || studio.captionGenerating)
        .sheet(item:$preview) {p in if let url=studio.source {RetakePreviewPlayer(url:url,preview:p)}}
    }
    private func show(_ marker:RetakeMarker,retry:Bool) {
        studio.player.pause();studio.playing=false
        preview=RetakePreview(title:retry ? "Retake":"Original",start:retry ? marker.retryStart:marker.start,end:retry ? marker.end:marker.retryStart)
    }
    private func sourceTime(_ label:String,id:UUID,keyPath:WritableKeyPath<RetakeMarker,Double>)->some View {
        HStack {Text(label).font(.caption);Spacer();TextField(label,value:Binding(get:{studio.retakes.first{$0.id==id}?[keyPath:keyPath] ?? 0},set:{value in
            if value.isFinite,let i=studio.retakes.firstIndex(where:{$0.id==id}) {studio.retakes[i][keyPath:keyPath]=max(0,min(studio.sourceDuration,value))}
        }),format:.number.precision(.fractionLength(2))).frame(width:75).textFieldStyle(.roundedBorder).accessibilityLabel(label)}
    }
}
struct RetakePreviewPlayer:View {
    var url:URL
    var preview:RetakePreview
    @Environment(\.dismiss) private var dismiss
    @State private var player=AVPlayer()
    @State private var boundary:Any?
    var body:some View {
        VStack(spacing:14) {
            HStack {Text(preview.title).font(.headline);Spacer();Button("Done") {dismiss()}}
            RawRetakePlayerView(player:player).frame(width:640,height:360)
            HStack {Text("Raw recording · \(preview.start,format:.number.precision(.fractionLength(2)))–\(preview.end,format:.number.precision(.fractionLength(2))) s").foregroundStyle(.secondary);Spacer();Button("Replay") {play()}}
        }.padding(20).onAppear {
            let item=AVPlayerItem(url:url);item.forwardPlaybackEndTime=CMTime(seconds:preview.end,preferredTimescale:600);item.reversePlaybackEndTime=CMTime(seconds:preview.start,preferredTimescale:600);player.replaceCurrentItem(with:item)
            boundary=player.addBoundaryTimeObserver(forTimes:[NSValue(time:CMTime(seconds:preview.end,preferredTimescale:600))],queue:.main) { [player] in player.pause() }
            play()
        }.onDisappear {player.pause();if let boundary {player.removeTimeObserver(boundary)};boundary=nil;player.replaceCurrentItem(with:nil)}
    }
    private func play() {player.seek(to:CMTime(seconds:preview.start,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero);player.play()}
}

/// Use AppKit directly: the system AVKit SwiftUI bridge can abort during metadata initialization.
struct RawRetakePlayerView:NSViewRepresentable {
    var player:AVPlayer
    func makeNSView(context:Context)->AVPlayerView {
        let view=AVPlayerView();view.player=player;view.controlsStyle = .inline;view.showsFullScreenToggleButton=false;return view
    }
    func updateNSView(_ view:AVPlayerView,context:Context) {if view.player !== player {view.player=player}}
    static func dismantleNSView(_ view:AVPlayerView,coordinator:()) {view.player=nil}
}
