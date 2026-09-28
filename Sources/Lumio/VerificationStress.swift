import AVFoundation
import Foundation

/// A long run of random edits against one recording. Every step has to leave the timeline and everything on it
/// consistent; the seed and the number of steps can be set with LUMIO_STRESS_SEED and LUMIO_STRESS_STEPS so a
/// failure can be repeated exactly.
@MainActor func verifyStress(folder:URL) async throws->[String] {
    var lines:[String]=[]
        var stressSeed:UInt64=UInt64(ProcessInfo.processInfo.environment["LUMIO_STRESS_SEED"].flatMap { UInt64($0) } ?? 0x5EED)
        func stressRandom(_ bound:Int)->Int { stressSeed=stressSeed&*6364136223846793005&+1442695040888963407;return Int((stressSeed>>33)%UInt64(max(1,bound))) }
        let stress=Studio();stress.preferences.revealExport=false
        await stress.load(folder.appendingPathComponent("sample.mp4"))
        var history:[EditSnapshot]=[]
        let stressSteps=Int(ProcessInfo.processInfo.environment["LUMIO_STRESS_STEPS"] ?? "") ?? 120
        for step in 0..<stressSteps {
            let before=stress.snapshot
            let action=stressRandom(16)
            let names=["split","speed","delete clip","add zoom","add annotation","add marker","move clip","paste","undo","delete selection",
                       "redo","transition","music","caption","export preset","crop"]
            switch action {
            case 0: stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.splitVideo()
            case 1: if let id=stress.videoClips.first?.id { stress.setClipSpeed(id,to:[0.25,0.5,2,4][stressRandom(4)]) }
            case 2: if stress.videoClips.count>1,let id=stress.videoClips.last?.id { stress.selectedClip=id;stress.deleteSelectedClip() }
            case 3: stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.addZoom()
            case 4: stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.addAnnotation(Annotation.kinds[stressRandom(Annotation.kinds.count)])
            case 5: stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.addMarker()
            case 6: if let id=stress.videoClips.last?.id { stress.moveClip(id,toTimelineStart:Double(stressRandom(400))/100) }
            case 7: stress.copyTimelineSelection();stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.pasteTimelineItem()
            case 8: stress.undoEdit()
            case 9: stress.deleteTimelineSelection()
            case 10: stress.redoEdit()
            case 11: if stress.videoClips.count>1,let id=stress.videoClips.last?.id {
                stress.setClipTransition(id,to:[0.0,0.3,0.8][stressRandom(3)],kind:["Dip to Black","Cross Dissolve"][stressRandom(2)]) }
            case 12: stress.addBundledMusic(bundledMusic[stressRandom(bundledMusic.count)])
            case 13: stress.position=min(stress.duration,Double(stressRandom(300))/100);stress.addCaption()
            case 14: stress.applyExportPreset(exportPresets[stressRandom(exportPresets.count)])
            default:
                var style=stress.look.videoStyle ?? VideoStyle()
                style.cropLeft=Double(stressRandom(40))/100;style.cropTop=Double(stressRandom(40))/100
                style.cropRight=Double(stressRandom(30))/100;style.cropBottom=Double(stressRandom(30))/100
                stress.look.videoStyle=style
            }
            stress.message=nil
            history.append(before)
            // Anything the timeline holds has to come back the same way from a project file, or a saved
            // project would quietly lose an edit that is on screen.
            if step%25==0 {
                let encoded=try JSONEncoder().encode(stress.snapshot)
                let decoded=try JSONDecoder().decode(EditSnapshot.self,from:encoded)
                guard decoded==stress.snapshot else { throw stress.failure("step \(step) (\(names[action])) made an edit that does not survive being written down") }
            }
            let duration=stress.duration
            guard duration.isFinite,duration>=0,abs(duration-stress.sequenceDuration)<0.001,stress.position>=0,stress.position<=duration+0.001 else{throw stress.failure("step \(step) (\(names[action])) left the timeline at \(duration) s with the playhead at \(stress.position), clips \(stress.videoClips.map{ String(format:"%.2f→%.2f",$0.timelineStart,$0.timelineStart+$0.duration) })")}
            guard stress.audioTracks.allSatisfy({ $0.timelineStart.isFinite && $0.timelineStart>=0 && $0.volume>=0 && $0.volume<=1 }),
                  stress.annotations.allSatisfy({ [$0.x,$0.y,$0.width,$0.height,$0.fontSize,$0.strength].allSatisfy(\.isFinite) }),
                  stress.look.canvas.width>0,stress.look.canvas.height>0,
                  stress.videoClips.allSatisfy({ $0.sourceStart.isFinite && $0.sourceEnd>$0.sourceStart && $0.timelineStart>=0 && $0.rate>0 }),
                  stress.zooms.allSatisfy({ $0.start>=0 && $0.end<=duration+0.001 && $0.end-$0.start>=0 }),
                  stress.annotations.allSatisfy({ $0.start>=0 && $0.end<=duration+0.001 && $0.alpha(at:$0.start).isFinite }),
                  stress.markers.allSatisfy({ $0.time>=0 && $0.time<=duration+0.001 }),
                  stress.captions.allSatisfy({ $0.start>=0 && $0.end<=duration+0.001 }) else{
                let clipTrouble=stress.videoClips.filter { !($0.sourceStart.isFinite && $0.sourceEnd>$0.sourceStart && $0.timelineStart>=0 && $0.rate>0) }
                let zoomTrouble=stress.zooms.filter { !($0.start>=0 && $0.end<=duration+0.001 && $0.end-$0.start>=0) }
                let noteTrouble=stress.annotations.filter { !($0.start>=0 && $0.end<=duration+0.001) }
                let markerTrouble=stress.markers.filter { !($0.time>=0 && $0.time<=duration+0.001) }
                throw stress.failure("step \(step) (\(names[action])) left an item outside the \(duration) s timeline · clips \(clipTrouble) · zooms \(zoomTrouble) · annotations \(noteTrouble) · markers \(markerTrouble)")
            }
        }
        // The edit that came out of all this still renders: a frame is asked for the way an export would.
        let (stressAsset,stressComposition,_)=try await stress.makeEditingComposition(asset:AVURLAsset(url:stress.source!),size:CGSize(width:480,height:270),fps:30)
        let stressGenerator=AVAssetImageGenerator(asset:stressAsset);stressGenerator.videoComposition=stressComposition
        stressGenerator.requestedTimeToleranceBefore = .zero;stressGenerator.requestedTimeToleranceAfter = .zero
        let stressFrame=try await stressGenerator.image(at:CMTime(seconds:min(stress.duration*0.5,max(0,stress.duration-0.05)),preferredTimescale:600)).image
        guard stressFrame.width>0,stressFrame.height>0 else { throw stress.failure("the timeline these edits left behind does not render") }
        // Undoing everything walks back through the same states it came from.
        var undone=0
        while !stress.undoStack.isEmpty,undone<400 { stress.undoEdit();undone+=1 }
        guard stress.videoClips.count>=1,stress.duration>0,stress.duration.isFinite else{throw stress.failure("undoing every step left \(stress.videoClips.count) clips and \(stress.duration) s")}
        stress.previewTask?.cancel()
        lines.append("PASS \(stressSteps) mixed edits keep the timeline, its items and undo consistent")
    // A clip that plays an added recording, or hands over with a dissolve, has to come back from a project
    // file as it was left. Until these were written down, reopening a project played the wrong file and cut flat.
    let elsewhere="/Users/Shared/lumio-second-recording.mp4"
    let mixed=[VideoClip(sourceStart:0,sourceEnd:2,timelineStart:0),
               VideoClip(sourceStart:0,sourceEnd:1.5,timelineStart:2,source:elsewhere,transition:0.4,transitionKind:"Cross Dissolve")]
    let written=try JSONEncoder().encode(LumioProject(source:"/tmp/opened.mp4",look:Look(),start:0,end:3.5,videoClips:mixed))
    let read=try JSONDecoder().decode(LumioProject.self,from:written)
    guard let readClips=read.videoClips,readClips.count==2,readClips[1].source==elsewhere,
          readClips[1].resolvedTransition==0.4,readClips[1].resolvedTransitionKind=="Cross Dissolve" else {
        throw NSError(domain:"Lumio",code:94,userInfo:[NSLocalizedDescriptionKey:"a saved clip lost its recording or its transition: \(read.videoClips?.map { ($0.source ?? "opened",$0.resolvedTransition) } ?? [])"]) }
    let reopened=normalizedVideoClips(readClips,sourceDuration:3,added:[elsewhere:1.5])
    guard reopened.count==2,reopened[1].source==elsewhere,reopened[1].resolvedTransition==0.4 else {
        throw NSError(domain:"Lumio",code:94,userInfo:[NSLocalizedDescriptionKey:"a reopened project dropped the added recording: \(reopened.map { $0.source ?? "opened" })"]) }
    lines.append("PASS a saved project keeps which recording each clip plays and how it hands over")
    return lines
}

/// Developer-only: runs the stress pass alone, for going through many seeds while hunting for a bug.
@MainActor func verifyStressOnly(folder:URL) async {
    do { print(try await verifyStress(folder:folder).joined(separator:"\n")); exit(0) }
    catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}
