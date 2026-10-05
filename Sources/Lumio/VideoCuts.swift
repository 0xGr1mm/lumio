import AppKit
import Foundation
import AVFoundation

/// Kept for opening legacy project files.
struct VideoCut:Codable,Equatable,Identifiable {
    var id=UUID()
    var start:Double
    var end:Double
}

/// Represents a recoverable range in the raw media, placed on the timeline at a playback speed.
struct VideoClip:Codable,Equatable,Identifiable {
    var id:UUID
    var sourceStart:Double
    var sourceEnd:Double
    var timelineStart:Double
    var speed:Double
    /// File this clip plays, when it is not the recording the editor was opened with.
    var source:String? = nil
    /// Seconds of transition across this clip's start, shared with whatever plays before it.
    var transition:Double? = nil
    /// "Dip to Black" or "Cross Dissolve"; older projects kept only the dip.
    var transitionKind:String? = nil
    /// Seconds this clip holds a single frame instead of playing it: a freeze frame. The sound stops with
    /// the picture rather than crawling along with it, which is what a held frame is usually for.
    var hold:Double? = nil
    var isHold:Bool { let value=hold ?? 0;return value.isFinite && value>0.05 }
    var resolvedTransition:Double { let value=transition ?? 0;return value.isFinite ? max(0,min(2,value)):0 }
    var resolvedTransitionKind:String { ["Dip to Black","Cross Dissolve"].contains(transitionKind ?? "") ? transitionKind!:"Dip to Black" }
    var rate:Double { max(0.05,speed.isFinite ? speed:1) }
    var duration:Double { isHold ? min(60,hold ?? 0):max(0,sourceEnd-sourceStart)/rate }
    func timelineTime(forSource time:Double)->Double { isHold ? timelineStart:timelineStart+(time-sourceStart)/rate }
    func sourceTime(forTimeline time:Double)->Double { isHold ? sourceStart:sourceStart+(time-timelineStart)*rate }
    init(id:UUID=UUID(),sourceStart:Double,sourceEnd:Double,timelineStart:Double=0,speed:Double=1,source:String?=nil,transition:Double?=nil,transitionKind:String?=nil,hold:Double?=nil) {
        self.id=id;self.sourceStart=sourceStart;self.sourceEnd=sourceEnd;self.timelineStart=timelineStart;self.speed=speed;self.source=source;self.transition=transition;self.transitionKind=transitionKind;self.hold=hold
    }
    // Every one of these is written down: a clip that plays an added recording, or hands over with a
    // transition, would otherwise come back from a saved project playing the wrong file and cutting flat.
    enum CodingKeys:String,CodingKey {case id,sourceStart,sourceEnd,timelineStart,speed,source,transition,transitionKind,hold}
    init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        id=try values.decodeIfPresent(UUID.self,forKey:.id) ?? UUID()
        sourceStart=try values.decode(Double.self,forKey:.sourceStart)
        sourceEnd=try values.decode(Double.self,forKey:.sourceEnd)
        timelineStart=try values.decodeIfPresent(Double.self,forKey:.timelineStart) ?? 0
        speed=try values.decodeIfPresent(Double.self,forKey:.speed) ?? 1
        source=try values.decodeIfPresent(String.self,forKey:.source)
        transition=try values.decodeIfPresent(Double.self,forKey:.transition)
        transitionKind=try values.decodeIfPresent(String.self,forKey:.transitionKind)
        hold=try values.decodeIfPresent(Double.self,forKey:.hold)
    }
}

struct TimelineSampleCache {
    var generation:Int
    var clips:[VideoClip]
    var crop:CGRect
    var pointer:[PointerSample]
    var keyboard:[KeySample]
}
struct VideoClipPlacement:Identifiable,Equatable {
    var id:UUID { clip.id }
    var clip:VideoClip
    var timelineStart:Double
    var timelineEnd:Double { timelineStart+clip.duration }
}

/// Clips are clamped to the length of the file each one plays: the opened recording, or an added one from `added`.
/// A clip whose file is unknown is dropped, so a project cannot point at footage that is not there.
func normalizedVideoClips(_ clips:[VideoClip],sourceDuration:Double,added:[String:Double]=[:],limit:Int=10_000)->[VideoClip] {
    guard sourceDuration.isFinite,sourceDuration>0 else{return []}
    var result:[VideoClip]=[],ids=Set<UUID>()
    for original in clips.prefix(limit) {
        guard original.sourceStart.isFinite,original.sourceEnd.isFinite,original.timelineStart.isFinite else{continue}
        var length=sourceDuration
        if let path=original.source {
            guard let known=added[path],known.isFinite,known>0 else{continue}
            length=known
        }
        let start=max(0,min(length,original.sourceStart))
        let end=max(0,min(length,original.sourceEnd))
        guard end-start>=0.04 else{continue}
        var id=original.id
        if ids.contains(id){id=UUID()}
        ids.insert(id)
        let speed=original.speed.isFinite ? max(0.25,min(4,original.speed)):1
        let held=original.isHold ? max(0.1,min(30,original.hold ?? 0)):nil
        result.append(VideoClip(id:id,sourceStart:start,sourceEnd:end,timelineStart:max(0,min(86_400,original.timelineStart)),speed:speed,source:original.source,transition:original.resolvedTransition>0 ? original.resolvedTransition:nil,transitionKind:original.resolvedTransition>0 ? original.resolvedTransitionKind:nil,hold:held))
    }
    return result
}

func snappedTimelineStart(_ proposed:Double,moving:VideoClip,clips:[VideoClip],playhead:Double,threshold:Double)->Double {
    let base=max(0,proposed)
    guard threshold>0,threshold.isFinite else{return base}
    var targets=[0.0,max(0,playhead)]
    for clip in clips where clip.id != moving.id {targets.append(clip.timelineStart);targets.append(clip.timelineStart+clip.duration)}
    let candidates=targets.flatMap{[$0,$0-moving.duration]}.map{max(0,$0)}
    guard let nearest=candidates.min(by:{abs($0-base)<abs($1-base)}),abs(nearest-base)<=threshold else{return base}
    return nearest
}

func keptVideoRanges(start:Double,end:Double,cuts:[VideoCut])->[VideoCut] {
    var cursor=start,result:[VideoCut]=[]
    for c in cuts.sorted(by:{$0.start<$1.start}) {
        let a=max(start,c.start),b=min(end,c.end)
        guard b>a else {continue}
        if a>cursor {result.append(VideoCut(start:cursor,end:a))}
        cursor=max(cursor,b)
    }
    if cursor<end {result.append(VideoCut(start:cursor,end:end))}
    return result
}

/// Maps a timeline time across a speed change of the clip spanning [start, oldEnd]: inside it scales, after it shifts.
func speedChangeTime(_ time:Double,start:Double,oldEnd:Double,newEnd:Double)->Double {
    if time<=start {return time}
    if time>=oldEnd {return time+newEnd-oldEnd}
    return start+(time-start)*(newEnd-start)/max(0.000_001,oldEnd-start)
}

@MainActor extension Studio {
    var clipPlacements:[VideoClipPlacement] {
        videoClips.map {VideoClipPlacement(clip:$0,timelineStart:$0.timelineStart)}
    }
    var sequenceDuration:Double { videoClips.map {$0.timelineStart+$0.duration}.max() ?? 0 }
    var selectedVideoClip:VideoClip? { videoClips.first {$0.id == selectedClip} }

    func resetVideoClips() {
        guard sourceDuration > 0 else { videoClips=[];selectedClip=nil;return }
        let clip=VideoClip(sourceStart:0,sourceEnd:sourceDuration,timelineStart:0)
        videoClips=[clip];selectedClip=clip.id
        synchronizeVideoSequence()
    }

    /// `trimItems` is off while undo restores a snapshot: it must come back exactly as it was saved.
    func synchronizeVideoSequence(refresh:Bool=true,trimItems:Bool=true) {
        duration=max(0,sequenceDuration)
        trimStart=0;trimEnd=duration
        position=max(0,min(position,duration))
        if trimItems { trimTimelineItemsToDuration() }
        if selectedClip == nil || !videoClips.contains(where:{$0.id == selectedClip}) { selectedClip=videoClips.first?.id }
        if refresh { refreshComposition() }
    }

    /// Keeps zooms, captions, annotations and markers inside the timeline after clips are cut, moved or removed.
    /// An item reaching past the end is shortened; one left entirely beyond it goes, and undo brings it back with its clip.
    func trimTimelineItemsToDuration() {
        guard duration>0 else { return }
        let limit=duration
        zooms=zooms.compactMap { zoom in
            guard zoom.start<limit-0.05 else { return nil }
            var copy=zoom;copy.end=min(zoom.end,limit)
            guard copy.end-copy.start>=0.1 else { return nil }
            copy.transition=min(copy.transition,(copy.end-copy.start)/2)
            return copy
        }
        captions=captions.compactMap { cue in
            guard cue.start<limit-0.02 else { return nil }
            var copy=cue;copy.end=min(cue.end,limit)
            copy.words=cue.words.compactMap { word in
                guard word.start<copy.end else { return nil }
                var value=word;value.end=min(word.end,copy.end);return value
            }
            return copy.end-copy.start>=0.04 ? copy:nil
        }
        annotations=annotations.compactMap { item in
            guard item.start<limit-0.05 else { return nil }
            var copy=item;copy.end=min(item.end,limit)
            return copy.end-copy.start>=0.1 ? copy:nil
        }
        markers=markers.filter { $0.time<=limit+0.001 }
        if !zooms.contains(where:{$0.id == selectedZoom}) { selectedZoom=nil }
        if !captions.contains(where:{$0.id == selectedCaption}) { selectedCaption=captions.first?.id }
        if !annotations.contains(where:{$0.id == selectedAnnotation}) { selectedAnnotation=nil }
        if !markers.contains(where:{$0.id == selectedMarker}) { selectedMarker=nil }
    }

    func placement(containing time:Double)->VideoClipPlacement? {
        let t=max(0,min(time,max(0,duration-0.000_001)))
        return clipPlacements.last {$0.timelineStart <= t && t < $0.timelineEnd}
    }

    func splitVideo(at requested:Double?=nil) {
        let t=requested ?? position
        guard let placement=placement(containing:t) else {return}
        let clip=placement.clip
        let sourceTime=clip.sourceTime(forTimeline:t)
        guard sourceTime>clip.sourceStart+0.04,sourceTime<clip.sourceEnd-0.04,
              let index=videoClips.firstIndex(where:{$0.id == placement.id}) else {return}
        player.pause();playing=false
        // Both halves are copies of the clip, so whichever recording it played and however it was set up
        // survives the cut; only the new inside edge is plain, because a split is not a hand-over.
        var left=clip; left.id=UUID(); left.sourceEnd=sourceTime
        var right=clip; right.id=UUID(); right.sourceStart=sourceTime
        right.timelineStart=clip.timelineTime(forSource:sourceTime); right.transition=nil; right.transitionKind=nil
        videoClips.replaceSubrange(index...index,with:[left,right])
        selectedClip=right.id;position=t
        synchronizeVideoSequence()
    }

    func deleteSelectedClip() {
        guard videoClips.count>1,let id=selectedClip,let index=videoClips.firstIndex(where:{$0.id == id}) else {
            if videoClips.count == 1 {message="At least one clip must remain in the timeline."};return
        }
        player.pause();playing=false
        let removed=videoClips[index]
        videoClips.remove(at:index)
        // The timeline closes over a deleted clip instead of leaving an empty stretch of background where it was.
        let stillCovered=videoClips.contains { $0.timelineStart < removed.timelineStart+removed.duration-0.001 && $0.timelineStart+$0.duration > removed.timelineStart+0.001 }
        if !stillCovered { closeTimelineGap(from:removed.timelineStart,length:removed.duration) }
        selectedClip=videoClips[min(index,videoClips.count-1)].id
        synchronizeVideoSequence()
        flash("Clip removed · the timeline closed over it")
        position=max(0,min(duration,position));seek(position)
    }

    func duplicateSelectedClip() {
        guard let clip=selectedVideoClip else{return}
        player.pause();playing=false
        var copy=clip; copy.id=UUID(); copy.timelineStart=clip.timelineStart+clip.duration
        copy.transition=nil; copy.transitionKind=nil
        videoClips.append(copy);selectedClip=copy.id;position=copy.timelineStart
        synchronizeVideoSequence();seek(position)
    }

    func updateClipEdge(_ id:UUID,startEdge:Bool,to sourceTime:Double) {
        guard let index=videoClips.firstIndex(where:{$0.id == id}) else {return}
        let clip=videoClips[index]
        if startEdge {
            // The right edge stays put on the timeline while the left edge reveals or hides source frames.
            var next=max(0,min(clip.sourceEnd-0.04,sourceTime))
            var start=clip.timelineStart+(next-clip.sourceStart)/clip.rate
            if start<0 { next=clip.sourceStart-clip.timelineStart*clip.rate;start=0 }
            let moved=max(0,start)-clip.timelineStart
            videoClips[index].timelineStart=max(0,start)
            videoClips[index].sourceStart=max(0,next)
            // Trimming the head removes that stretch from the timeline. Leaving it behind would put an empty
            // patch of background in front of the clip, which reads as the video having gone black.
            if moved>0.0001 { closeTimelineGap(from:clip.timelineStart,length:moved) }
        } else {
            videoClips[index].sourceEnd=min(sourceDuration,max(clip.sourceStart+0.04,sourceTime))
        }
        selectedClip=id
        synchronizeVideoSequence()
    }

    /// Removes a stretch of the timeline and pulls everything after it back: clips, zooms, captions, annotations,
    /// markers and added audio all move together, so a cut never shifts one against another.
    /// Pushes everything from a moment onwards later, to make room for something new on the timeline.
    func openTimelineGap(at:Double,length:Double) {
        guard length>0.0001 else { return }
        func moved(_ time:Double)->Double { time>=at-0.0001 ? time+length:time }
        for index in videoClips.indices where videoClips[index].timelineStart>=at-0.0001 {
            videoClips[index].timelineStart+=length
        }
        zooms=zooms.map { var copy=$0;copy.start=moved($0.start);copy.end=moved($0.end);return copy }
        captions=captions.map { cue in
            var copy=cue;copy.start=moved(cue.start);copy.end=moved(cue.end)
            copy.words=cue.words.map { var value=$0;value.start=moved($0.start);value.end=moved($0.end);return value }
            return copy
        }
        annotations=remappedAnnotations(annotations,moved)
        invalidateSensitiveScan()
        markers=remappedMarkers(markers,moved)
        audioTracks=audioTracks.map { var copy=$0;copy.timelineStart=moved($0.timelineStart);return copy }
    }

    /// Holds the frame under the playhead for a few seconds, the way a tutorial stops on the result it
    /// just produced. The clip is cut there, everything after it moves along, and the held frame goes in
    /// between; undo takes the whole thing back in one step.
    @discardableResult func freezeFrame(seconds:Double=2) -> UUID? {
        guard stillImage == nil,duration>0,!busy else { return nil }
        let at=max(0,min(duration,position))
        guard let placement=placement(containing:min(at,max(0,duration-0.01))) else { return nil }
        let clip=placement.clip
        guard !clip.isHold else { message="The playhead is already on a held frame.";return nil }
        let length=max(0.2,min(30,seconds.isFinite ? seconds:2))
        let sourceTime=clip.sourceTime(forTimeline:at)
        player.pause();playing=false
        // A cut at the playhead first, so the hold lands between two clean halves.
        if sourceTime>clip.sourceStart+0.05,sourceTime<clip.sourceEnd-0.05 { splitVideo(at:at) }
        openTimelineGap(at:at,length:length)
        let limit=clip.source.flatMap { addedSources[$0] } ?? sourceDuration
        let start=max(0,min(max(0,limit-0.05),sourceTime))
        let frozen=VideoClip(sourceStart:start,sourceEnd:min(limit,start+0.04),timelineStart:at,source:clip.source,hold:length)
        videoClips.append(frozen)
        selectedClip=frozen.id
        synchronizeVideoSequence()
        position=min(duration,at+length);seek(position)
        flash(String(format:"Frame held for %.1f s",length))
        return frozen.id
    }

    func closeTimelineGap(from:Double,length:Double) {
        guard length>0.0001 else { return }
        let cuts=[VideoCut(start:from,end:from+length)]
        func moved(_ time:Double)->Double { retakeRippleTime(time,cuts:cuts) }
        for index in videoClips.indices where videoClips[index].timelineStart>=from-0.0001 {
            videoClips[index].timelineStart=max(0,videoClips[index].timelineStart-length)
        }
        zooms=zooms.compactMap { zoom in
            var copy=zoom;copy.start=moved(zoom.start);copy.end=moved(zoom.end)
            guard copy.end-copy.start>=0.1 else { return nil }
            copy.transition=min(copy.transition,(copy.end-copy.start)/2);return copy
        }
        captions=captions.compactMap { cue in
            var copy=cue;copy.start=moved(cue.start);copy.end=moved(cue.end)
            guard copy.end-copy.start>=0.04 else { return nil }
            copy.words=cue.words.compactMap { word in
                var value=word;value.start=moved(word.start);value.end=moved(word.end)
                return value.end-value.start>=0.01 ? value:nil
            }
            if !cue.words.isEmpty,copy.words.isEmpty { return nil }
            return copy
        }
        annotations=remappedAnnotations(annotations,moved)
        invalidateSensitiveScan()
        markers=remappedMarkers(markers,moved)
        audioTracks=audioTracks.map { track in
            var copy=track;copy.timelineStart=moved(track.timelineStart);return copy
        }
    }

    func moveClip(_ id:UUID,toTimelineStart proposedStart:Double,snapThreshold:Double=0) {
        guard let index=videoClips.firstIndex(where:{$0.id == id}) else {return}
        videoClips[index].timelineStart=snappedTimelineStart(proposedStart,moving:videoClips[index],clips:videoClips,playhead:position,threshold:snapThreshold)
        let item=videoClips.remove(at:index)
        videoClips.append(item)
        selectedClip=id
        synchronizeVideoSequence()
    }

    func trimSelectedClipToPlayhead(startEdge:Bool) {
        guard let placement=clipPlacements.first(where:{$0.id == selectedClip}) else {return}
        if startEdge {
            guard position>placement.timelineStart+0.04,position<placement.timelineEnd else {return}
        } else {
            guard position>placement.timelineStart,position<placement.timelineEnd-0.04 else {return}
        }
        updateClipEdge(placement.id,startEdge:startEdge,to:placement.clip.sourceTime(forTimeline:position))
    }

    /// Changes a clip's playback speed and keeps later clips, zooms, captions and added audio in step.
    func setClipSpeed(_ id:UUID,to requested:Double) {
        guard let index=videoClips.firstIndex(where:{$0.id == id}),!busy else{return}
        let speed=requested.isFinite ? max(0.25,min(4,requested)):1
        let clip=videoClips[index]
        guard abs(clip.speed-speed)>0.0001 else{return}
        var changed=clip;changed.speed=speed
        let start=clip.timelineStart,oldEnd=start+clip.duration,newEnd=start+changed.duration
        func remap(_ time:Double)->Double {speedChangeTime(time,start:start,oldEnd:oldEnd,newEnd:newEnd)}
        var edit=snapshot
        edit.clips=videoClips.map { other in
            if other.id == id {return changed}
            var copy=other
            if other.timelineStart>=oldEnd-0.000_5 {copy.timelineStart=max(0,other.timelineStart+newEnd-oldEnd)}
            return copy
        }
        edit.zooms=zooms.compactMap { zoom in
            var copy=zoom;copy.start=remap(zoom.start);copy.end=remap(zoom.end)
            guard copy.end-copy.start>=0.1 else{return nil};copy.transition=min(copy.transition,(copy.end-copy.start)/2);return copy
        }
        edit.captions=captions.map { cue in
            var copy=cue;copy.start=remap(cue.start);copy.end=remap(cue.end)
            copy.words=cue.words.map {var word=$0;word.start=remap(word.start);word.end=remap(word.end);return word}
            return copy
        }
        edit.annotations=remappedAnnotations(annotations,remap)
        invalidateSensitiveScan()
        edit.markers=remappedMarkers(markers,remap)
        edit.audioTracks=audioTracks.map {var track=$0;if track.timelineStart>=oldEnd-0.000_5 {track.timelineStart+=newEnd-oldEnd};return track}
        player.pause();playing=false
        let target=remap(position)
        undoStack.append(snapshot);if undoStack.count>80{undoStack.removeFirst()};redoStack=[]
        restore(edit)
        // The edit itself tidies up; restore alone would keep items that now sit past the end, because undo must stay exact.
        trimTimelineItemsToDuration()
        selectedClip=id;position=min(target,duration);seek(position)
    }

    func migrateLegacyVideoEdits(start:Double,end:Double,cuts:[VideoCut]) {
        let kept=keptVideoRanges(start:max(0,start),end:min(sourceDuration,end),cuts:cuts)
        var cursor=0.0
        videoClips=kept.filter{$0.end-$0.start>=0.04}.map {
            let clip=VideoClip(sourceStart:$0.start,sourceEnd:$0.end,timelineStart:cursor)
            cursor+=clip.duration;return clip
        }
        if videoClips.isEmpty {resetVideoClips()} else {selectedClip=videoClips.first?.id;synchronizeVideoSequence()}
    }

    /// Pointer and keyboard samples on the timeline clock. The timeline redraws on every playhead move,
    /// so the mapping is cached until the samples, clips or crop change.
    private var timelineSamples:TimelineSampleCache {
        let crop=(look.videoStyle ?? VideoStyle()).cropRect
        if let cache=timelineSampleCache,cache.generation == sampleGeneration,cache.clips == videoClips,cache.crop == crop { return cache }
        let cropped=crop != CGRect(x:0,y:0,width:1,height:1)
        func mapped(_ sample:PointerSample)->PointerSample {
            guard cropped else {return sample}
            var copy=sample;copy.x=(sample.x-crop.minX)/crop.width;copy.y=(sample.y-crop.minY)/crop.height;return copy
        }
        var pointer:[PointerSample]=[],keyboard:[KeySample]=[]
        if videoClips.isEmpty { pointer=pointerSamples.map(mapped);keyboard=keyboardSamples }
        for placement in clipPlacements where placement.clip.source == nil {
            for sample in pointerSamples where sample.time>=placement.clip.sourceStart && sample.time<placement.clip.sourceEnd {
                var copy=mapped(sample)
                copy.time=placement.clip.timelineTime(forSource:sample.time)
                pointer.append(copy)
            }
            for sample in keyboardSamples where sample.time>=placement.clip.sourceStart && sample.time<placement.clip.sourceEnd {
                var copy=sample;copy.time=placement.clip.timelineTime(forSource:sample.time);keyboard.append(copy)
            }
        }
        let cache=TimelineSampleCache(generation:sampleGeneration,clips:videoClips,crop:crop,pointer:pointer.sorted {$0.time<$1.time},keyboard:keyboard.sorted{$0.time<$1.time})
        timelineSampleCache=cache
        return cache
    }
    /// Pointer samples on the timeline clock, in the coordinates of the cropped video.
    var timelinePointerSamples:[PointerSample] { timelineSamples.pointer }
    var timelineKeyboardSamples:[KeySample] { timelineSamples.keyboard }
    var timelineTypingTimes:[Double] { timelineKeyboardSamples.filter{$0.typing ?? false}.map(\.time) }
}

@MainActor extension Studio {
    /// Adds another recording to the end of the timeline. Its own picture and sound play from its file;
    /// pointer, keyboard, camera and microphone data belong to the recording the editor was opened with.
    func addRecording(_ url:URL) async {
        guard !busy, source != nil, stillImage == nil else { return }
        let asset=AVURLAsset(url:url)
        do {
            let length=try await asset.load(.duration).seconds
            guard length.isFinite,length>0.04,!(try await asset.loadTracks(withMediaType:.video)).isEmpty else {
                message="\(url.lastPathComponent) has no video to add.";return
            }
            let path=url.standardizedFileURL.path
            guard path != source?.standardizedFileURL.path else { message="This recording is already open.";return }
            addedSources[path]=length
            loadWaveforms()
            let clip=VideoClip(sourceStart:0,sourceEnd:length,timelineStart:sequenceDuration,source:path)
            videoClips.append(clip)
            synchronizeVideoSequence()
            selectedClip=clip.id;timelineFocus = .clip
            position=clip.timelineStart;seek(position)
        } catch { message="\(url.lastPathComponent) could not be added: \(error.localizedDescription)" }
    }
    func chooseRecordingToAdd() {
        let picker=NSOpenPanel();picker.allowedContentTypes=[.movie];picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let url=picker.url else { return }
        Task { await addRecording(url) }
    }
}

@MainActor extension Studio {
    /// Sets how this clip hands over from whatever plays before it. A clip at the very beginning has no cut to cross.
    /// A cross dissolve needs material before the clip's start to overlap with, so it falls back to a dip when there is none.
    func setClipTransition(_ id:UUID,to seconds:Double,kind:String="Dip to Black") {
        guard let index=videoClips.firstIndex(where:{ $0.id == id }),videoClips[index].timelineStart>0.001 else { return }
        let length=seconds.isFinite ? max(0,min(2,seconds)):0
        videoClips[index].transition=length>0.01 ? length:nil
        if length>0.01 {
            let clip=videoClips[index]
            let available=clip.sourceStart/max(0.05,clip.rate)
            videoClips[index].transitionKind=(kind=="Cross Dissolve" && available>=length-0.001) ? "Cross Dissolve":"Dip to Black"
        } else { videoClips[index].transitionKind=nil }
        refreshComposition()
    }
}
