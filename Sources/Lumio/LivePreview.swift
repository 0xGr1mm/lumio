import AVFoundation
import Foundation

/// Only changes to media, timing or the audio mix require a new player item.
struct PreviewTimelineKey:Equatable {
    var source:URL?
    var sourceDuration:Double
    var duration:Double
    var clips:[VideoClip]
    var added:[String:Double]
    var camera:String?
    var cameraOffset:Double?
    var microphone:String?
    var microphoneOffset:Double?
    var audio:[AudioTrackEdit]
    var mix:AudioMixSettings
    var duckingRanges:[Double]
    var samples:Int
    var clicks:Bool
    var cuts:Bool
    var fadeIn:Double
    var fadeOut:Double
    var enhanced:String?
    @MainActor init(_ studio:Studio) {
        source=studio.source;sourceDuration=studio.sourceDuration;duration=studio.duration
        clips=studio.videoClips;added=studio.addedSources
        camera=studio.cameraPath;cameraOffset=studio.cameraOffset
        microphone=studio.microphonePath;microphoneOffset=studio.microphoneOffset
        audio=studio.audioTracks;mix=studio.audioSettings
        duckingRanges=studio.audioSettings.ducking ? studio.captions.flatMap{[$0.start,$0.end]}:[]
        samples=studio.motion.clickSound ? studio.sampleGeneration:0;clicks=studio.motion.clickSound;cuts=studio.motion.resolvedCutSound
        fadeIn=studio.look.resolvedFadeIn;fadeOut=studio.look.resolvedFadeOut
        enhanced=studio.readyEnhancedVoiceURL()?.path
    }
}

/// Optional instrumentation for actual compositor completion, rather than just slider assignment.
final class PreviewFrameProbe:@unchecked Sendable {
    struct Sample {var revision:Int;var time:Double;var latency:Double}
    private let lock=NSLock()
    private var frames:[Sample]=[]
    func record(revision:Int,time:Double,sent:Double) {
        lock.lock();defer {lock.unlock()}
        frames.append(Sample(revision:revision,time:time,latency:ProcessInfo.processInfo.systemUptime-sent))
        if frames.count>2000 {frames.removeFirst(1000)}
    }
    var samples:[Sample] {lock.lock();defer {lock.unlock()};return frames}
}

@MainActor extension Studio {
    var previewRenderSize:CGSize {
        let h=Double(previewQuality == 0 ? 480:previewQuality == 1 ? 720:1080)
        return CGSize(width:(h*look.canvas.width/look.canvas.height/2).rounded()*2,height:h)
    }
    var previewFrameRate:Int {previewQuality == 0 ? 30:min(60,exportSettings.resolvedFPS)}

    @discardableResult func updateLivePreview()->Bool {
        guard let item=player.currentItem,item === previewItem,
              let video=item.videoComposition,
              let previous=video.instructions.first as? FrameInstruction,
              let updated=video.mutableCopy() as? AVMutableVideoComposition else {return false}
        let d=previous.design
        let design=makeFrameDesign(size:previewRenderSize,transform:d.transform,sourceAspect:mediaAspect,
            renderDuration:d.duration,cameraID:d.cameraID,secondaryID:d.secondaryID,visibleRanges:d.visibleRanges,
            cursorRanges:d.cursorRanges,dips:d.dips,dissolves:d.dissolves,previous:d)
        previewVisualRevision &+= 1
        updated.renderSize=design.size
        updated.frameDuration=CMTime(value:1,timescale:Int32(previewFrameRate))
        updated.instructions=[FrameInstruction(trackID:previous.trackID,timeRange:previous.timeRange,design:design,
            probe:previewProbe,revision:previewVisualRevision)]
        // A new composition instance re-renders the paused frame without seeking or replacing its media.
        item.videoComposition=updated
        return true
    }

    func refreshComposition() {
        guard let source,stillImage == nil,!busy else {return}
        let key=PreviewTimelineKey(self)
        if previewTimelineKey==key,updateLivePreview() {return}
        // Keep a media build in progress when only its visual settings change; its final design reads
        // the latest values. Repeated slider events must not keep cancelling initial preparation.
        if pendingPreviewTimelineKey==key {return}
        previewTask?.cancel();previewBuildGeneration &+= 1
        let generation=previewBuildGeneration
        pendingPreviewTimelineKey=key
        previewTask=Task { @MainActor in
            defer {
                if previewBuildGeneration==generation {previewTask=nil;pendingPreviewTimelineKey=nil}
            }
            do {
                await Task.yield();try Task.checkCancellation()
                let (edit,composition,audioMix)=try await makeEditingComposition(asset:AVURLAsset(url:source),size:previewRenderSize,fps:previewFrameRate)
                try Task.checkCancellation()
                guard self.source==source,PreviewTimelineKey(self)==key else {return}
                let time=position,wasPlaying=playing
                let item=AVPlayerItem(asset:edit)
                item.videoComposition=composition;item.audioMix=audioMix;item.audioTimePitchAlgorithm = .spectral
                previewItem=item;previewTimelineKey=key
                player.replaceCurrentItem(with:item)
                // Bind the latest render size and diagnostic probe even when quality changed during loading.
                updateLivePreview()
                await player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
                if wasPlaying {player.playImmediately(atRate:Float(previewSpeed))}
            } catch is CancellationError {} catch {message="Preview could not be prepared: \(error.localizedDescription)"}
        }
    }
}
