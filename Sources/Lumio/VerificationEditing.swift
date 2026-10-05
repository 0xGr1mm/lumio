import AVFoundation
import AppKit
import CoreImage
import Foundation

@MainActor func verifyEditing(folder:URL) async throws->[String] {
    var lines:[String]=[]
    func editFailure(_ text:String)->NSError { NSError(domain:"Lumio",code:91,userInfo:[NSLocalizedDescriptionKey:text]) }
    let context=CIContext(options:[.workingColorSpace:NSNull()])

    // A split or a duplicate has to keep the clip it was made from, all of it. These lost which recording
    // the clip played and how it handed over, so an edit on a project with two recordings quietly swapped
    // in the wrong footage.
    let kept=Studio();kept.preferences.revealExport=false
    await kept.load(folder.appendingPathComponent("sample.mp4"))
    let elsewhere="/Users/Shared/lumio-second.mp4"
    kept.addedSources=[elsewhere:3]
    kept.videoClips=[VideoClip(sourceStart:0,sourceEnd:1.4,timelineStart:0),
                     VideoClip(sourceStart:0,sourceEnd:1.6,timelineStart:1.4,source:elsewhere,transition:0.4,transitionKind:"Cross Dissolve")]
    kept.synchronizeVideoSequence(refresh:false)
    kept.position=2.2
    kept.splitVideo()
    guard kept.videoClips.count==3 else { throw editFailure("the split did not happen: \(kept.videoClips.count) clips") }
    let halves=kept.videoClips.filter { $0.timelineStart>1.3 }
    guard halves.count==2,halves.allSatisfy({ $0.source==elsewhere }) else {
        throw editFailure("a split half lost its recording: \(kept.videoClips.map { $0.source ?? "opened" })") }
    guard halves[0].resolvedTransition==0.4,halves[1].resolvedTransition==0 else {
        throw editFailure("the split put a hand-over on its own inside edge: \(halves.map(\.resolvedTransition))") }
    kept.selectedClip=halves[1].id
    kept.duplicateSelectedClip()
    guard let copy=kept.videoClips.last,copy.source==elsewhere,copy.resolvedTransition==0 else {
        throw editFailure("the duplicate lost its recording: \(kept.videoClips.last?.source ?? "opened")") }
    kept.previewTask?.cancel()
    lines.append("PASS a split and a duplicate keep which recording the clip plays")

    // A held frame: the timeline grows by the hold, everything after it moves along, and the picture stops.
    let hold=Studio();hold.preferences.revealExport=false
    await hold.load(folder.appendingPathComponent("sample.mp4"))
    hold.motion.autoZoom=false;hold.motion.showCursor=false
    hold.markers=[TimelineMarker(time:0.5,name:"before"),TimelineMarker(time:2.0,name:"after")]
    let before=hold.duration
    hold.position=1.5
    guard let frozenID=hold.freezeFrame(seconds:2) else { throw editFailure("the frame was not held") }
    guard abs(hold.duration-(before+2))<0.01 else { throw editFailure("the timeline did not grow by the hold: \(before) → \(hold.duration)") }
    guard let frozen=hold.videoClips.first(where:{ $0.id==frozenID }),frozen.isHold,abs(frozen.duration-2)<0.001,
          abs(frozen.sourceTime(forTimeline:1.6)-frozen.sourceTime(forTimeline:3.4))<0.0001 else {
        throw editFailure("the held clip does not hold one frame") }
    guard hold.videoClips.count==3 else { throw editFailure("the clip was not cut around the hold: \(hold.videoClips.count)") }
    guard let early=hold.markers.first(where:{ $0.name=="before" }),abs(early.time-0.5)<0.01,
          let late=hold.markers.first(where:{ $0.name=="after" }),abs(late.time-4.0)<0.01 else {
        throw editFailure("markers did not move with the hold: \(hold.markers.map { ($0.name,$0.time) })") }
    // Rendered: two moments inside the hold are the same picture, while two moments of ordinary play are not.
    let size=CGSize(width:480,height:270)
    let (asset,composition,mix)=try await hold.makeEditingComposition(asset:AVURLAsset(url:hold.source!),size:size,fps:30)
    let generator=AVAssetImageGenerator(asset:asset);generator.videoComposition=composition
    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    func pixels(_ time:Double) async throws->[UInt8] {
        let image=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
        var data=[UInt8](repeating:0,count:Int(size.width*size.height)*4)
        context.render(CIImage(cgImage:image),toBitmap:&data,rowBytes:Int(size.width)*4,
                       bounds:CGRect(origin:.zero,size:size),format:.RGBA8,colorSpace:nil)
        return data
    }
    let held1=try await pixels(1.6),held2=try await pixels(2.5),held3=try await pixels(3.4)
    let playing1=try await pixels(0.3),playing2=try await pixels(1.2)
    let stillness=max(looksDistance(held1,held2),max(looksDistance(held2,held3),looksDistance(held1,held3)))
    let movement=looksDistance(playing1,playing2)
    guard stillness<1 else { throw editFailure("the held frame is not holding: \(stillness)") }
    guard movement>stillness*3 else { throw editFailure("the recording does not move enough to tell a hold from it: \(movement)") }
    // The sound stops with the picture: no audio is laid under the hold.
    if let mix {
        for parameters in mix.inputParameters {
            guard let track=(asset as? AVComposition)?.tracks.first(where:{ $0.trackID==parameters.trackID }),track.mediaType == .audio else { continue }
            for segment in track.segments where !segment.isEmpty {
                let range=segment.timeMapping.target
                let middle=2.5
                guard !(range.start.seconds<middle && CMTimeRangeGetEnd(range).seconds>middle) else {
                    throw editFailure("sound was laid under the held frame") }
            }
        }
    }
    hold.previewTask?.cancel()
    lines.append("PASS a held frame stops the picture, grows the timeline, carries everything after it and stays silent")

    // And it survives being written down and being undone.
    let written=try JSONEncoder().encode(LumioProject(source:hold.source!.path,look:hold.look,start:0,end:hold.duration,videoClips:hold.videoClips))
    let read=try JSONDecoder().decode(LumioProject.self,from:written)
    let reopened=normalizedVideoClips(read.videoClips ?? [],sourceDuration:3)
    guard reopened.contains(where:{ $0.isHold && abs($0.duration-2)<0.001 }) else {
        throw editFailure("a held frame did not survive the project file") }
    let settled=hold.snapshot
    hold.undoStack=[settled]
    hold.videoClips.removeAll { $0.isHold }
    hold.synchronizeVideoSequence(refresh:false)
    hold.undoEdit()
    guard hold.videoClips.contains(where:\.isHold),abs(hold.duration-(before+2))<0.01 else {
        throw editFailure("undo did not bring the held frame back") }
    lines.append("PASS a held frame survives a saved project and comes back on undo")

    // One clip turned down, another muted: each clip's sound is mixed on its own, and a muted clip is
    // simply not laid down. Cutting out a noisy stretch should not mean cutting out its picture too.
    let mixed=Studio();mixed.preferences.revealExport=false
    await mixed.load(folder.appendingPathComponent("sample.mp4"))
    mixed.videoClips=[VideoClip(sourceStart:0,sourceEnd:1,timelineStart:0),
                      VideoClip(sourceStart:1,sourceEnd:2,timelineStart:1,volume:0.3),
                      VideoClip(sourceStart:2,sourceEnd:3,timelineStart:2,volume:0)]
    mixed.synchronizeVideoSequence(refresh:false)
    mixed.audioSettings=AudioMixSettings(systemVolume:1)
    let (mixedAsset,_,mixedMix)=try await mixed.makeEditingComposition(asset:AVURLAsset(url:mixed.source!),size:CGSize(width:320,height:180),fps:30)
    guard let mixedMix else { throw editFailure("the clips produced no audio at all") }
    let audioTracks=(mixedAsset as? AVComposition)?.tracks(withMediaType:.audio) ?? []
    guard audioTracks.count==2 else { throw editFailure("a muted clip still took an audio track: \(audioTracks.count) tracks for two audible clips") }
    var volumes:[Float]=[]
    for parameters in mixedMix.inputParameters where audioTracks.contains(where:{ $0.trackID==parameters.trackID }) {
        var level:Float=0
        parameters.getVolumeRamp(for:.zero,startVolume:&level,endVolume:nil,timeRange:nil)
        volumes.append(level)
    }
    guard volumes.contains(where:{ abs($0-1)<0.02 }),volumes.contains(where:{ abs($0-0.3)<0.02 }) else {
        throw editFailure("the clips are not mixed at their own volumes: \(volumes)") }
    // And it is remembered: a level set on a clip has to come back from the project file.
    let savedMix=try JSONEncoder().encode(LumioProject(source:mixed.source!.path,look:mixed.look,start:0,end:3,videoClips:mixed.videoClips))
    let readMix=try JSONDecoder().decode(LumioProject.self,from:savedMix)
    let restored=normalizedVideoClips(readMix.videoClips ?? [],sourceDuration:3)
    guard restored.count==3,abs(restored[1].resolvedVolume-0.3)<0.001,restored[2].resolvedVolume<0.001,
          restored[0].volume==nil else {
        throw editFailure("clip volumes did not survive the project: \(restored.map(\.resolvedVolume))") }
    mixed.previewTask?.cancel()
    lines.append("PASS each clip plays at its own volume, a muted one is left out, and the levels are remembered")

    // Exporting a selection: the file is as long as the stretch that was chosen, and it is that stretch
    // rather than the opening of the timeline.
    let part=Studio();part.preferences.revealExport=false;part.exportSettings=ExportSettings()
    await part.load(folder.appendingPathComponent("sample.mp4"))
    part.motion.autoZoom=false;part.motion.showCursor=false;part.look.exportHeight=720
    guard part.exportRange==nil else { throw editFailure("a fresh project already has a selection") }
    part.position=1.2;part.setExportIn()
    part.position=2.4;part.setExportOut()
    guard let span=part.exportRange,abs(span.start-1.2)<0.01,abs(span.end-2.4)<0.01,abs(part.exportLength-1.2)<0.01 else {
        throw editFailure("the in and out points did not take: \(String(describing:part.exportRange))") }
    let partial=folder.appendingPathComponent("verified-selection.mp4")
    await part.export(to:partial)
    guard part.message==nil else { throw editFailure(part.message!) }
    let exported=AVURLAsset(url:partial)
    let writtenLength=try await exported.load(.duration).seconds
    guard abs(writtenLength-1.2)<0.25 else { throw editFailure("the selection exported \(writtenLength) s instead of 1.2 s") }
    // It is the right stretch: the first frame of the file matches the timeline at the in point, and the
    // picture moves across the sample, so matching the opening instead would be a different reading.
    let (fullAsset,fullComposition,_)=try await part.makeEditingComposition(asset:AVURLAsset(url:part.source!),size:CGSize(width:480,height:270),fps:30)
    let reference=AVAssetImageGenerator(asset:fullAsset);reference.videoComposition=fullComposition
    reference.requestedTimeToleranceBefore = .zero;reference.requestedTimeToleranceAfter = .zero
    let fileFrames=AVAssetImageGenerator(asset:exported)
    fileFrames.maximumSize=CGSize(width:480,height:270)
    fileFrames.requestedTimeToleranceBefore = .zero;fileFrames.requestedTimeToleranceAfter = .zero
    func sampled(_ generator:AVAssetImageGenerator,_ time:Double) async throws->[UInt8] {
        let image=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
        var data=[UInt8](repeating:0,count:480*270*4)
        context.render(CIImage(cgImage:image),toBitmap:&data,rowBytes:480*4,bounds:CGRect(x:0,y:0,width:480,height:270),format:.RGBA8,colorSpace:nil)
        return data
    }
    let fromFile=try await sampled(fileFrames,0.1)
    let atIn=try await sampled(reference,1.3),atZero=try await sampled(reference,0.1)
    let toIn=looksDistance(fromFile,atIn),toStart=looksDistance(fromFile,atZero)
    guard toIn<toStart else { throw editFailure("the selection exported the wrong stretch: \(toIn) from the in point, \(toStart) from the start") }
    part.clearExportRange()
    guard part.exportRange==nil,abs(part.exportLength-part.duration)<0.01 else { throw editFailure("clearing the selection did not restore the whole timeline") }
    part.previewTask?.cancel()
    lines.append("PASS an in and out point export only that stretch, and clearing them restores the whole timeline")

    // A title card: the recording starts later, the card carries its own text, and the picture is not
    // on screen while it plays.
    let titled=Studio();titled.preferences.revealExport=false
    await titled.load(folder.appendingPathComponent("sample.mp4"))
    titled.motion.autoZoom=false;titled.motion.showCursor=false
    let originalLength=titled.duration
    guard let cardID=titled.addTitleCard(seconds:2,text:"How Lumio works") else { throw editFailure("the title card was not added") }
    guard abs(titled.duration-(originalLength+2))<0.01 else { throw editFailure("the timeline did not grow for the card: \(titled.duration)") }
    guard let firstClip=titled.videoClips.min(by:{ $0.timelineStart<$1.timelineStart }),abs(firstClip.timelineStart-2)<0.01 else {
        throw editFailure("the recording did not move behind the card") }
    guard let card=titled.annotations.first(where:{ $0.id==cardID }),card.kind=="Text",card.text=="How Lumio works",
          card.start==0,abs(card.end-2)<0.01 else { throw editFailure("the card has no title on it") }
    let (cardAsset,cardComposition,_)=try await titled.makeEditingComposition(asset:AVURLAsset(url:titled.source!),size:CGSize(width:480,height:270),fps:30)
    let cardFrames=AVAssetImageGenerator(asset:cardAsset);cardFrames.videoComposition=cardComposition
    cardFrames.requestedTimeToleranceBefore = .zero;cardFrames.requestedTimeToleranceAfter = .zero
    let onCard=try await sampled(cardFrames,1.0),onRecording=try await sampled(cardFrames,3.0)
    guard looksDistance(onCard,onRecording)>18 else {
        throw editFailure("the card looks like the recording: \(looksDistance(onCard,onRecording))") }
    titled.previewTask?.cancel()
    lines.append("PASS a title card opens the timeline, holds its own text and keeps the recording off screen")
    return lines
}

/// Developer-only: the editing checks on their own, for working on them without the whole suite.
@MainActor func verifyEditingOnly(folder:URL) async {
    do { print(try await verifyEditing(folder:folder).joined(separator:"\n")); exit(0) }
    catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}
