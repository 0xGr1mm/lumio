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
    let held1=try await pixels(1.7),held2=try await pixels(3.3)
    let playing1=try await pixels(0.3),playing2=try await pixels(1.2)
    let stillness=looksDistance(held1,held2),movement=looksDistance(playing1,playing2)
    guard stillness<2 else { throw editFailure("the held frame is not holding: \(stillness)") }
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
    return lines
}

/// Developer-only: the editing checks on their own, for working on them without the whole suite.
@MainActor func verifyEditingOnly(folder:URL) async {
    do { print(try await verifyEditing(folder:folder).joined(separator:"\n")); exit(0) }
    catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}
