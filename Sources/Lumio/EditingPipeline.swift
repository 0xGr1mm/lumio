import AVFoundation
import AppKit

/// Inserts a source range so it fills [timelineStart, timelineEnd], stretching it when the clip plays faster or slower.
func insertScaled(_ destination:AVMutableCompositionTrack,from track:AVAssetTrack,sourceStart:Double,timelineStart:Double,timelineEnd:Double,rate:Double) throws {
    let length = timelineEnd-timelineStart
    guard length > 0.0001 else { return }
    let at = CMTime(seconds:timelineStart,preferredTimescale:60_000)
    let range = CMTimeRange(start:CMTime(seconds:sourceStart,preferredTimescale:60_000),duration:CMTime(seconds:length*rate,preferredTimescale:60_000))
    try destination.insertTimeRange(range,of:track,at:at)
    if abs(rate-1) > 0.0001 { destination.scaleTimeRange(CMTimeRange(start:at,duration:range.duration),toDuration:CMTime(seconds:length,preferredTimescale:60_000)) }
}

@MainActor extension Studio {
    func makeEditingComposition(asset:AVAsset,size:CGSize,fps:Int=60) async throws -> (AVAsset,AVMutableVideoComposition,AVAudioMix?) {
        guard let sourceTrack=try await asset.loadTracks(withMediaType:.video).first else { throw failure("No video track was found") }
        let native=try await sourceTrack.load(.naturalSize)
        let sourceRate=Double(try await sourceTrack.load(.nominalFrameRate))
        let preferred=try await sourceTrack.load(.preferredTransform)
        let extent=CGRect(origin:.zero,size:native).applying(preferred)
        let composition=AVMutableComposition()
        // Clips may come from recordings added to this project; each one plays from its own file.
        // The assets are kept as well: a track whose asset has been released can no longer be inserted.
        var added:[String:(asset:AVURLAsset,video:AVAssetTrack,audio:[AVAssetTrack],fps:Double)]=[:]
        for path in Set(videoClips.compactMap(\.source)) {
            let extra=AVURLAsset(url:URL(fileURLWithPath:path))
            guard let video=try await extra.loadTracks(withMediaType:.video).first else { continue }
            let extraRate=Double(try await video.load(.nominalFrameRate))
            added[path]=(extra,video,try await extra.loadTracks(withMediaType:.audio),extraRate>1 ? extraRate:30)
        }
        let usable=videoClips.filter { $0.source == nil || added[$0.source!] != nil }
        let clips=usable.isEmpty ? [VideoClip(sourceStart:0,sourceEnd:sourceDuration)] : usable
        let boundaries=Array(Set([0.0,duration]+clips.flatMap {[$0.timelineStart,$0.timelineStart+$0.duration]})).filter {$0>=0 && $0<=duration}.sorted()
        let segments=zip(boundaries,boundaries.dropFirst()).filter { $0.1-$0.0 > 0.0001 }
        func activeClip(_ start:Double,_ end:Double)->VideoClip? { let middle=(start+end)/2; return clips.last(where:{$0.timelineStart<=middle && middle<$0.timelineStart+$0.duration}) }
        guard let main=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else {throw failure("The video timeline could not be created")}
        // A cross dissolve needs both clips on screen at once, so the incoming one is laid on a second track,
        // reaching back into the outgoing clip by the length of the dissolve.
        let crossing=clips.filter { $0.resolvedTransition>0 && $0.resolvedTransitionKind=="Cross Dissolve" && $0.timelineStart>0.001 }
        var dissolves:[DissolveSpan]=[]
        var secondaryID=kCMPersistentTrackID_Invalid
        if !crossing.isEmpty,let secondary=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) {
            secondaryID=secondary.trackID
            for clip in crossing {
                let length=min(clip.resolvedTransition,clip.sourceStart/max(0.05,clip.rate))
                guard length>0.02 else { continue }
                let track=clip.source.flatMap { added[$0]?.video } ?? sourceTrack
                let from=clip.timelineStart-length
                do {
                    try insertScaled(secondary,from:track,sourceStart:clip.sourceStart-length*clip.rate,timelineStart:from,timelineEnd:clip.timelineStart+clip.duration,rate:clip.rate)
                    dissolves.append(DissolveSpan(start:from,length:length,incomingOnSecondary:true))
                } catch { continue }
            }
        }
        for (start,end) in segments {
            if let active=activeClip(start,end) {
                let track=active.source.flatMap { added[$0]?.video } ?? sourceTrack
                if active.isHold {
                    // One frame stretched across the whole hold, which is how a freeze is built: the
                    // composition plays a sliver of source very slowly rather than repeating a picture.
                    // The sliver is centred inside a single frame of the source — a window picked by the
                    // clock rather than by the frame grid can straddle two frames, and the hold then
                    // changes picture halfway through, which is exactly what it is there to prevent.
                    let holdRate=active.source.flatMap { added[$0]?.fps } ?? (sourceRate>1 ? sourceRate:30)
                    let frameLength=1/holdRate, window=frameLength*0.3
                    let centre=((active.sourceStart*holdRate).rounded(.down)+0.5)*frameLength
                    try insertScaled(main,from:track,sourceStart:max(0,centre-window/2),timelineStart:start,timelineEnd:end,rate:window/max(window,end-start))
                } else {
                    try insertScaled(main,from:track,sourceStart:active.sourceTime(forTimeline:start),timelineStart:start,timelineEnd:end,rate:active.rate)
                }
            } else {
                var target=start
                while target<end-0.0001 {
                    let piece=min(sourceDuration,end-target)
                    try insertScaled(main,from:sourceTrack,sourceStart:0,timelineStart:target,timelineEnd:target+piece,rate:1)
                    target+=piece
                }
            }
        }
        // Each clip's own sound goes to its own track, so a clip can be turned down or muted on its own.
        var sourceAudioDestinations:[(track:AVMutableCompositionTrack,volume:Double)]=[]
        let enhancedVoice=readyEnhancedVoiceURL()
        var recordingAudio=try await asset.loadTracks(withMediaType:.audio)
        // Without a separate microphone file, voice enhancement processes the recording's own audio and replaces it here.
        if microphonePath == nil,let enhancedVoice,let processed=try await AVURLAsset(url:enhancedVoice).loadTracks(withMediaType:.audio).first { recordingAudio=[processed] }
        for clip in clips where !clip.isHold && clip.resolvedVolume>0.001 {
            for audio in clip.source.flatMap({ added[$0]?.audio }) ?? recordingAudio {
                let available=try await audio.load(.timeRange)
                let availableEnd=CMTimeRangeGetEnd(available).seconds
                let sourceEnd=min(clip.sourceEnd,availableEnd)
                guard sourceEnd-clip.sourceStart>0.001,let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else {continue}
                try insertScaled(destination,from:audio,sourceStart:clip.sourceStart,timelineStart:clip.timelineStart,timelineEnd:clip.timelineTime(forSource:sourceEnd),rate:clip.rate)
                sourceAudioDestinations.append((destination,clip.resolvedVolume))
            }
        }
        let editDuration=CMTime(seconds:max(0.04,duration),preferredTimescale:600)
        var mixEntries:[(track:AVMutableCompositionTrack,volume:Float,kind:String,start:Double,end:Double)]=sourceAudioDestinations.map{($0.track,Float(audioSettings.systemVolume*$0.volume),"System",0,duration)}
        // A microphone recorded with the screen follows the video clips (cuts and speed) through its clock offset.
        if let microphone=microphonePath,FileManager.default.fileExists(atPath:microphone) {
            let micAsset=AVURLAsset(url:enhancedVoice ?? URL(fileURLWithPath:microphone))
            if let micTrack=try await micAsset.loadTracks(withMediaType:.audio).first {
                let available=(try await micAsset.load(.duration)).seconds,offset=microphoneOffset ?? 0
                for clip in clips where clip.source == nil && !clip.isHold {
                    let start=max(clip.sourceStart,offset),end=min(clip.sourceEnd,available+offset)
                    guard end-start>0.001,let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else {continue}
                    try insertScaled(destination,from:micTrack,sourceStart:start-offset,timelineStart:clip.timelineTime(forSource:start),timelineEnd:clip.timelineTime(forSource:end),rate:clip.rate)
                    mixEntries.append((destination,Float(audioSettings.microphoneVolume ?? 1),"Microphone",0,duration))
                }
            }
        }
        for edit in audioTracks where !edit.muted && edit.volume > 0 && edit.timelineStart < duration && FileManager.default.fileExists(atPath:edit.path) {
            let audioAsset=AVURLAsset(url:URL(fileURLWithPath:edit.path))
            guard let sourceAudio=try await audioAsset.loadTracks(withMediaType:.audio).first,
                  let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) else {continue}
            let available=(try await audioAsset.load(.duration)).seconds
            let from=max(0,min(edit.sourceStart,available)),to=max(from,min(edit.sourceEnd,available))
            guard to-from>0.001 else{continue}
            var target=max(0,edit.timelineStart),sourcePosition=from
            let requestedEnd=min(duration,target+edit.duration)
            while target<requestedEnd-0.001 {
                let piece=min(requestedEnd-target,to-sourcePosition)
                guard piece>0.001 else{break}
                try destination.insertTimeRange(CMTimeRange(start:CMTime(seconds:sourcePosition,preferredTimescale:600),duration:CMTime(seconds:piece,preferredTimescale:600)),of:sourceAudio,at:CMTime(seconds:target,preferredTimescale:600))
                target+=piece;sourcePosition+=piece
                if edit.loop && sourcePosition>=to-0.001 {sourcePosition=from} else if sourcePosition>=to-0.001 {break}
            }
            mixEntries.append((destination,Float(edit.volume),edit.kind,max(0,edit.timelineStart),target))
        }
        if motion.clickSound,let clickURL=Bundle.main.url(forResource:"click",withExtension:"wav",subdirectory:"Audio") {
            let clickAsset=AVURLAsset(url:clickURL)
            if let clickSource=try await clickAsset.loadTracks(withMediaType:.audio).first,let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                let length=min(0.09,(try await clickAsset.load(.duration)).seconds)
                var previous=false,lastEnd = -1.0
                for sample in timelinePointerSamples where sample.time<duration {
                    if pointerClick(sample,previous:previous) && sample.time>=lastEnd {try destination.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:length,preferredTimescale:600)),of:clickSource,at:CMTime(seconds:sample.time,preferredTimescale:600));lastEnd=sample.time+length}
                    previous=sample.pressed
                }
                mixEntries.append((destination,0.7,"Click",0,duration))
            }
        }
        // A cut carries better with a short rush under it. It starts a little before the cut, the way it is mixed by hand.
        let cutTimes=videoClips.map(\.timelineStart).filter { $0>0.05 && $0<duration-0.05 }.sorted()
        if motion.resolvedCutSound,!cutTimes.isEmpty,let whooshURL=Bundle.main.url(forResource:"whoosh",withExtension:"wav",subdirectory:"Audio") {
            let whooshAsset=AVURLAsset(url:whooshURL)
            if let whooshSource=try await whooshAsset.loadTracks(withMediaType:.audio).first,
               let destination=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid) {
                let length=(try await whooshAsset.load(.duration)).seconds
                var lastEnd = -1.0
                for cut in cutTimes {
                    let at=max(0,cut-length*0.55)
                    guard at>=lastEnd else { continue }
                    let piece=min(length,duration-at)
                    guard piece>0.02 else { continue }
                    try destination.insertTimeRange(CMTimeRange(start:.zero,duration:CMTime(seconds:piece,preferredTimescale:600)),of:whooshSource,at:CMTime(seconds:at,preferredTimescale:600))
                    lastEnd=at+piece
                }
                mixEntries.append((destination,0.55,"Cut",0,duration))
            }
        }
        let voiceRanges=mixEntries.filter{$0.kind=="Voiceover"}.map{($0.start,$0.end)}
        let audioMix:AVMutableAudioMix? = mixEntries.isEmpty ? nil:AVMutableAudioMix()
        if let audioMix {
            audioMix.inputParameters=mixEntries.map {entry in
                let parameters=AVMutableAudioMixInputParameters(track:entry.track);parameters.setVolume(entry.volume,at:.zero)
                parameters.audioTimePitchAlgorithm = .spectral
                if audioSettings.ducking && entry.kind != "Voiceover" && entry.kind != "Click" && entry.kind != "Microphone" {
                    let detectedSpeech=entry.kind == "System" ? voiceRanges:voiceRanges+captions.map{($0.start,$0.end)}
                    for (start,end) in detectedSpeech {parameters.setVolume(Float(audioSettings.duckLevel)*entry.volume,at:CMTime(seconds:max(0,start-0.08),preferredTimescale:600));parameters.setVolume(entry.volume,at:CMTime(seconds:min(duration,end+0.12),preferredTimescale:600))}
                }
                // The sound dips with the picture at both ends.
                if look.resolvedFadeIn>0 {
                    parameters.setVolumeRamp(fromStartVolume:0,toEndVolume:entry.volume,timeRange:CMTimeRange(start:.zero,duration:CMTime(seconds:min(look.resolvedFadeIn,duration),preferredTimescale:600)))
                }
                if look.resolvedFadeOut>0,duration>look.resolvedFadeOut {
                    parameters.setVolumeRamp(fromStartVolume:entry.volume,toEndVolume:0,timeRange:CMTimeRange(start:CMTime(seconds:duration-look.resolvedFadeOut,preferredTimescale:600),duration:CMTime(seconds:look.resolvedFadeOut,preferredTimescale:600)))
                }
                return parameters
            }
        }
        var cameraID=kCMPersistentTrackID_Invalid
        if let path=cameraPath,FileManager.default.fileExists(atPath:path) {
            let camera=AVURLAsset(url:URL(fileURLWithPath:path))
            if let cam=try await camera.loadTracks(withMediaType:.video).first {
                let available=(try await camera.load(.duration)).seconds
                if available>0,let destination=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) {
                    // A recorded camera follows the screen clock through its offset; an imported camera video loops.
                    let synced=cameraOffset
                    func empty(_ start:Double,_ length:Double) { destination.insertEmptyTimeRange(CMTimeRange(start:CMTime(seconds:start,preferredTimescale:60_000),duration:CMTime(seconds:length,preferredTimescale:60_000))) }
                    for (start,end) in segments {
                        let active=activeClip(start,end)
                        // A recording added to the project has no camera of its own, so its stretch stays empty.
                        if active?.source != nil { empty(start,end-start);continue }
                        let rate=active?.rate ?? 1
                        var screenSource=active.map{$0.sourceTime(forTimeline:start)} ?? 0
                        var target=start
                        while target<end-0.0001 {
                            var cameraTime=synced.map{screenSource-$0} ?? screenSource
                            if synced == nil && cameraTime>=available-0.001 { cameraTime=cameraTime.truncatingRemainder(dividingBy:available) }
                            if cameraTime<0 {
                                let gap=min(end-target,-cameraTime/rate)
                                empty(target,gap);target+=gap;screenSource+=gap*rate;continue
                            }
                            if cameraTime>=available-0.001 { empty(target,end-target);break }
                            let piece=min(end-target,(available-cameraTime)/rate)
                            try insertScaled(destination,from:cam,sourceStart:cameraTime,timelineStart:target,timelineEnd:target+piece,rate:rate)
                            target+=piece;screenSource+=piece*rate
                        }
                    }
                    cameraID=destination.trackID
                }
            }
        }
        let visibleRanges=segments.compactMap {start,end -> RenderTimeRange? in activeClip(start,end) == nil ? nil:RenderTimeRange(start:start,end:end) }
        let cursorRanges=segments.compactMap {start,end -> RenderTimeRange? in activeClip(start,end)?.source == nil ? RenderTimeRange(start:start,end:end):nil }
        let dips=clips.filter { $0.resolvedTransition>0 && $0.resolvedTransitionKind=="Dip to Black" && $0.timelineStart>0.001 }.map { RenderTimeRange(start:$0.timelineStart,end:$0.resolvedTransition) }
        let design=makeFrameDesign(size:size,transform:preferred,sourceAspect:abs(extent.width/extent.height),renderDuration:editDuration.seconds,cameraID:cameraID,secondaryID:secondaryID,visibleRanges:visibleRanges,cursorRanges:cursorRanges,dips:dips,dissolves:dissolves)
        let video=AVMutableVideoComposition();video.customVideoCompositorClass=FrameCompositor.self
        video.renderSize=size;video.frameDuration=CMTime(value:1,timescale:Int32(max(1,fps)))
        // Frame timing comes from frameDuration, not the source track: screen recordings are variable-rate,
        // and the synthesized cursor and zoom motion needs every output frame.
        video.instructions=[FrameInstruction(trackID:main.trackID,timeRange:CMTimeRange(start:.zero,duration:editDuration),design:design)]
        return (composition,video,audioMix)
    }
    /// Reused by export and live preview; visual edits never rebuild the media timeline.
    func makeFrameDesign(size:CGSize,transform:CGAffineTransform,sourceAspect:Double,renderDuration:Double,cameraID:CMPersistentTrackID,secondaryID:CMPersistentTrackID,visibleRanges:[RenderTimeRange],cursorRanges:[RenderTimeRange],dips:[RenderTimeRange],dissolves:[DissolveSpan],previous:FrameDesign?=nil)->FrameDesign {
        let placement=videoPlacement(look:look,canvas:size,mediaAspect:sourceAspect)
        let reframe=look.autoReframe ?? false
        let rect=placement.rect
        let (background,_)=decorationLayers(look:look,size:size,mediaAspect:look.frameAspect(media:sourceAspect,canvas:size))
        let border=CALayer();border.frame=CGRect(origin:.zero,size:size);border.addSublayer(borderLayer(look:look,rect:rect,size:size))
        let mask=CALayer();mask.frame=CGRect(origin:.zero,size:size);mask.backgroundColor=NSColor.black.cgColor
        let hole=CALayer();hole.frame=rect;hole.backgroundColor=NSColor.white.cgColor;hole.cornerRadius=look.radius*min(size.width,size.height)/800;mask.addSublayer(hole)
        var cursors:[String:CGImage]=[:],hotspots:[String:CGPoint]=[:]
        if let previous,previous.settings.style==motion.style,previous.settings.color==motion.color {cursors=previous.cursors;hotspots=previous.hotspots}
        else { for shape in ["arrow","ibeam","hand","crosshair","resizeHorizontal","resizeVertical","openHand","closedHand"] {
            cursors[shape]=cursorArtwork(style:motion.style,color:motion.color.ns,shape:shape)
            hotspots[shape]=cursorHotspot(style:motion.style,shape:shape)
        }
        }
        let sequencedSamples=timelinePointerSamples
        let trackingScale=max(motion.zoom,zooms.filter{$0.follow == true}.map(\.scale).max() ?? 1)
        let paths=motionPaths(viewport:placement.followSize(zoom:trackingScale))
        let samples=paths.cursor
        let keys=timelineKeyboardSamples
        let typing=keys.filter{$0.typing ?? false}.map(\.time)
        let automaticZooms=paths.automatic
        let punches=punchZoomClips(cuts:videoClips.map(\.timelineStart),duration:renderDuration,strength:motion.resolvedPunch,avoiding:zooms+automaticZooms)
        var clicks:[Double]=[],pressed=false
        for s in sequencedSamples { if pointerClick(s,previous:pressed) { clicks.append(s.time) };pressed=s.pressed }
        var watermark:CGImage?=nil
        var watermarkRect:CGRect = .zero
        if let path=look.watermarkPath,let logo=NSImage(contentsOfFile:path),logo.size.width>0,logo.size.height>0,
           let cg=logo.cgImage(forProposedRect:nil,context:nil,hints:nil) {
            watermark=cg
            let width=size.width*look.resolvedWatermarkSize/100
            let height=width*Double(cg.height)/Double(cg.width)
            let margin=size.width*0.035
            let left=look.resolvedWatermarkPosition.hasSuffix("Left")
            // Core Image counts from the bottom, so "Top" is the far edge.
            let bottom=look.resolvedWatermarkPosition.hasPrefix("Bottom")
            watermarkRect=CGRect(x:left ? margin:size.width-margin-width,y:bottom ? margin:size.height-margin-height,width:width,height:height)
        }
        var handle:CGImage?=nil
        var handleRect:CGRect = .zero
        if !look.resolvedHandleText.isEmpty,
           let drawn=handleArtwork(look.resolvedHandleText,fontSize:size.height*look.resolvedHandleSize/100,color:look.resolvedHandleColor) {
            handle=drawn
            let margin=size.width*0.03
            let left=look.resolvedHandlePosition.hasSuffix("Left")
            // Core Image counts from the bottom, so "Top" is the far edge.
            let bottom=look.resolvedHandlePosition.hasPrefix("Bottom")
            handleRect=CGRect(x:left ? margin:size.width-margin-Double(drawn.width),
                              y:bottom ? margin:size.height-margin-Double(drawn.height),
                              width:Double(drawn.width),height:Double(drawn.height))
        }
        // A clip that dips to black hands over at its own start, half the dip on each side of the cut.
        // The pointer belongs to the opened recording, so it is not drawn over footage added to the project.
        let cameraAvoid=cameraAvoidPath(samples:samples,settings:motion,style:motion.cameraStyle ?? CameraStyle(),
            canvas:size,video:rect,placement:placement,manual:zooms,auto:automaticZooms+punches,follow:paths.camera,duration:renderDuration)
        return FrameDesign(size:size,rect:rect,placement:placement,crop:(look.videoStyle ?? VideoStyle()).cropRect,reframe:reframe,transform:transform,background:layerImage(background,size:size),border:layerImage(border,size:size),mask:layerImage(mask,size:size),ripple:previous?.ripple ?? rippleArtwork(),cursors:cursors,hotspots:hotspots,samples:samples,follow:paths.camera,clicks:clicks,manual:zooms,auto:automaticZooms+punches,settings:motion,videoStyle:look.videoStyle ?? VideoStyle(),cameraStyle:motion.cameraStyle ?? CameraStyle(),captionCues:captions,captionStyle:captionStyle,shortcuts:keys.filter{!($0.typing ?? false)},typingTimes:typing,keyboardStyle:keyboardStyle,overlays:(previous?.captionStyle==captionStyle && previous?.keyboardStyle==keyboardStyle && previous?.captionCues==captions && previous?.annotations==annotations && previous?.shortcuts==keys.filter{!($0.typing ?? false)} ? previous!.overlays:OverlayArtCache(captionStyle:captionStyle,keyboardStyle:keyboardStyle)),duration:renderDuration,cameraID:cameraID,transparent:look.isTransparent,visibleRanges:visibleRanges,annotations:annotations,fadeIn:look.resolvedFadeIn,fadeOut:look.resolvedFadeOut,dips:dips,dissolves:dissolves,secondaryID:secondaryID,watermark:watermark,watermarkRect:watermarkRect,watermarkOpacity:look.resolvedWatermarkOpacity/100,personMasks:(motion.cameraStyle ?? CameraStyle()).resolvedBackground == "None" ? nil:PersonMaskMaker(quality:size.height<=720 ? .fast: .balanced),cursorRanges:cursorRanges,cameraAvoid:cameraAvoid,handle:handle,handleRect:handleRect,handleOpacity:look.resolvedHandleOpacity/100,progressHeight:look.resolvedProgressBar*size.height/1080,progressColor:look.resolvedProgressColor)
    }
    func chooseCameraVideo() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.movie]
        if panel.runModal() == .OK,let url=panel.url { cameraPath=url.path;cameraOffset=nil;refreshComposition() }
    }
    func loadPointerData(_ url:URL) {
        let sidecar=url.appendingPathExtension("pointer.json")
        if let data=try? readBoundedData(sidecar),let recording=try? JSONDecoder().decode(PointerRecording.self,from:data) {
            pointerSamples=normalizedPointerSamples(recording.samples,sourceDuration:sourceDuration);cursorEmbedded=recording.cursorEmbedded
        } else { pointerSamples=[];cursorEmbedded=true }
    }
    func loadKeyboardData(_ url:URL) {
        let sidecar=url.appendingPathExtension("keys.json")
        if let data=try? readBoundedData(sidecar),let recording=try? JSONDecoder().decode(KeyboardRecording.self,from:data) {keyboardSamples=normalizedKeySamples(recording.samples,sourceDuration:sourceDuration)}
        else {keyboardSamples=[]}
    }
}
