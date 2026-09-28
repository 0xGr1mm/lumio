import AVFoundation
import AppKit
import CoreImage
import Foundation

/// Developer-only: runs the effect checks alone, which is faster than the whole suite while they are being written.
@MainActor func verifyEffectsOnly(folder:URL) async {
    do { print(try await verifyEffects(folder:folder).joined(separator:"\n")); exit(0) }
    catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}

@MainActor func verifyEffects(folder:URL) async throws->[String] {
    var lines:[String]=[]
    func effectsFailure(_ text:String)->NSError { NSError(domain:"Lumio",code:97,userInfo:[NSLocalizedDescriptionKey:text]) }
    let context=CIContext(options:[.workingColorSpace:NSNull()])
    let width=640,height=360
    /// How different two frames are inside one rectangle, averaged over its channels.
    func patchDistance(_ a:[UInt8],_ b:[UInt8],x:Int,y:Int,size:Int)->Double {
        var total=0.0,count=0.0
        for row in y..<min(height,y+size) { for column in x..<min(width,x+size) {
            let index=(row*width+column)*4
            guard index+2<min(a.count,b.count) else { continue }
            total+=abs(Double(a[index])-Double(b[index]))+abs(Double(a[index+1])-Double(b[index+1]))+abs(Double(a[index+2])-Double(b[index+2]));count+=3
        } }
        return count>0 ? total/count:0
    }

    /// Renders one frame of a studio's timeline and hands back its pixels.
    func framePixels(_ studio:Studio,at time:Double) async throws->[UInt8] {
        let (asset,composition,_)=try await studio.makeEditingComposition(asset:AVURLAsset(url:studio.source!),size:CGSize(width:width,height:height),fps:30)
        let generator=AVAssetImageGenerator(asset:asset);generator.videoComposition=composition
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
        var pixels=[UInt8](repeating:0,count:width*height*4)
        context.render(CIImage(cgImage:image),toBitmap:&pixels,rowBytes:width*4,bounds:CGRect(x:0,y:0,width:width,height:height),format:.RGBA8,colorSpace:nil)
        return pixels
    }

    // The spotlight: the picture stays bright around the pointer and is dimmed away from it.
    let spot=Studio();spot.preferences.revealExport=false
    await spot.load(folder.appendingPathComponent("sample.mp4"))
    spot.look.padding=0;spot.look.radius=0;spot.look.shadow=0;spot.look.glow=0
    spot.motion.showCursor=false;spot.motion.autoZoom=false
    spot.pointerSamples=[PointerSample(time:0,x:0.25,y:0.5,pressed:false),PointerSample(time:3,x:0.25,y:0.5,pressed:false)]
    let plainFrame=try await framePixels(spot,at:1.5)
    let nearPlain=looksPatch(plainFrame,x:150,y:170,size:24,width:width,height:height)
    let farPlain=looksPatch(plainFrame,x:520,y:170,size:24,width:width,height:height)
    spot.motion.spotlight=90;spot.motion.spotlightSize=18
    let litFrame=try await framePixels(spot,at:1.5)
    let nearLit=looksPatch(litFrame,x:150,y:170,size:24,width:width,height:height)
    let farLit=looksPatch(litFrame,x:520,y:170,size:24,width:width,height:height)
    guard farPlain>20 else { throw effectsFailure("the sample is too dark to tell a spotlight from it: \(farPlain)") }
    guard farLit<farPlain*0.6 else { throw effectsFailure("the spotlight did not dim the picture away from the pointer: \(farPlain) → \(farLit)") }
    guard nearLit>nearPlain*0.85 else { throw effectsFailure("the spotlight dimmed the pointer's own circle: \(nearPlain) → \(nearLit)") }
    // Moving the pointer moves the bright circle with it.
    spot.pointerSamples=[PointerSample(time:0,x:0.8,y:0.5,pressed:false),PointerSample(time:3,x:0.8,y:0.5,pressed:false)]
    let movedFrame=try await framePixels(spot,at:1.5)
    let nearMoved=looksPatch(movedFrame,x:150,y:170,size:24,width:width,height:height)
    let farMoved=looksPatch(movedFrame,x:520,y:170,size:24,width:width,height:height)
    guard farMoved>nearMoved else { throw effectsFailure("the spotlight did not follow the pointer: left \(nearMoved) vs right \(farMoved)") }
    spot.previewTask?.cancel()
    lines.append("PASS the spotlight dims the screen away from the pointer, keeps its own circle bright and follows it")

    // The progress bar: it fills as the video plays, and nothing is drawn when it is off.
    let bar=Studio();bar.preferences.revealExport=false
    await bar.load(folder.appendingPathComponent("sample.mp4"))
    bar.motion.showCursor=false;bar.motion.autoZoom=false
    bar.look.progressBar=14;bar.look.progressColor=RGB(0x00FF00)
    func greenRun(_ pixels:[UInt8],row:Int)->Int {
        var count=0
        for column in 0..<width {
            let index=(row*width+column)*4
            guard index+2<pixels.count else { break }
            if pixels[index+1]>140,pixels[index]<110,pixels[index+2]<110 { count+=1 }
        }
        return count
    }
    // The bar sits at the bottom of the canvas, which is the last row of the picture.
    let early=try await framePixels(bar,at:0.4),late=try await framePixels(bar,at:2.7)
    let earlyRun=greenRun(early,row:height-3),lateRun=greenRun(late,row:height-3)
    guard earlyRun>10 else { throw effectsFailure("the progress bar is not drawn: \(earlyRun) pixels at 0.4 s") }
    guard lateRun>earlyRun+width/3 else { throw effectsFailure("the progress bar does not fill with time: \(earlyRun) → \(lateRun)") }
    guard lateRun<=width else { throw effectsFailure("the progress bar ran past the canvas: \(lateRun)") }
    bar.look.progressBar=0
    let none=try await framePixels(bar,at:2.7)
    guard greenRun(none,row:height-3)<10 else { throw effectsFailure("the progress bar is still drawn when it is off") }
    bar.previewTask?.cancel()
    lines.append("PASS the progress bar fills across the bottom as the video plays and leaves no trace when off")

    // A whoosh under every cut: one more audio track, with a piece of sound landing just before each cut.
    let sounded=Studio();sounded.preferences.revealExport=false
    await sounded.load(folder.appendingPathComponent("sample.mp4"))
    sounded.videoClips=[VideoClip(sourceStart:0,sourceEnd:1.5,timelineStart:0),VideoClip(sourceStart:1.5,sourceEnd:3,timelineStart:1.5)]
    sounded.synchronizeVideoSequence(refresh:false)
    let (quietAsset,_,_)=try await sounded.makeEditingComposition(asset:AVURLAsset(url:sounded.source!),size:CGSize(width:320,height:180),fps:30)
    let quietTracks=try await quietAsset.loadTracks(withMediaType:.audio).count
    sounded.motion.cutSound=true
    let (loudAsset,_,loudMix)=try await sounded.makeEditingComposition(asset:AVURLAsset(url:sounded.source!),size:CGSize(width:320,height:180),fps:30)
    let loudTracks=try await loudAsset.loadTracks(withMediaType:.audio)
    guard loudTracks.count==quietTracks+1 else { throw effectsFailure("the cut sound did not get its own track: \(quietTracks) → \(loudTracks.count)") }
    guard let whooshTrack=loudTracks.last else { throw effectsFailure("no cut sound track") }
    let segments=try await whooshTrack.load(.segments).filter { !$0.isEmpty }
    guard let piece=segments.first else { throw effectsFailure("the cut sound track is empty") }
    let landed=piece.timeMapping.target.start.seconds
    guard landed<1.5,landed>1.1 else { throw effectsFailure("the cut sound does not land at the cut: \(landed) s") }
    guard loudMix != nil else { throw effectsFailure("the cut sound is not in the mix") }
    // With one clip there is no cut, so nothing is added: the count is the same with the setting on or off.
    sounded.videoClips=[VideoClip(sourceStart:0,sourceEnd:3,timelineStart:0)];sounded.synchronizeVideoSequence(refresh:false)
    let (singleLoud,_,_)=try await sounded.makeEditingComposition(asset:AVURLAsset(url:sounded.source!),size:CGSize(width:320,height:180),fps:30)
    let singleLoudTracks=try await singleLoud.loadTracks(withMediaType:.audio).count
    sounded.motion.cutSound=false
    let (singleQuiet,_,_)=try await sounded.makeEditingComposition(asset:AVURLAsset(url:sounded.source!),size:CGSize(width:320,height:180),fps:30)
    let singleQuietTracks=try await singleQuiet.loadTracks(withMediaType:.audio).count
    guard singleLoudTracks==singleQuietTracks else { throw effectsFailure("a cut sound was added where there is no cut: \(singleQuietTracks) → \(singleLoudTracks)") }
    sounded.previewTask?.cancel()
    lines.append("PASS a whoosh is mixed in just before every cut, and left out when there is none")

    // The thumbnail: the frame under the playhead, at the export size, with everything the video would carry.
    let thumb=Studio();thumb.preferences.revealExport=false
    await thumb.load(folder.appendingPathComponent("sample.mp4"))
    thumb.look.exportHeight=720;thumb.look.aspect="16:9"
    var thumbSticker=Annotation(kind:"Sticker",start:0,end:3);thumbSticker.text="🚀";thumbSticker.fontSize=200
    thumb.annotations=[thumbSticker]
    thumb.position=1.4
    let thumbURL=folder.appendingPathComponent("verified-frame.png")
    await thumb.exportFrame(to:thumbURL)
    guard thumb.message==nil else { throw effectsFailure("saving the frame failed: \(thumb.message!)") }
    guard let saved=NSImage(contentsOf:thumbURL),saved.size.width>0 else { throw effectsFailure("no PNG was written") }
    guard let savedFrame=saved.cgImage(forProposedRect:nil,context:nil,hints:nil),savedFrame.width==1280,savedFrame.height==720 else {
        throw effectsFailure("the frame was not written at the export size: \(saved.size)") }
    guard thumb.lastExportURL==thumbURL,!thumb.busy else { throw effectsFailure("the frame export did not finish cleanly") }
    thumb.previewTask?.cancel()
    lines.append("PASS the frame under the playhead saves as a PNG at the export size")

    // Everything added here has to survive a saved project and an undo, or it is only a preview trick.
    let kept=Studio();kept.preferences.revealExport=false
    await kept.load(folder.appendingPathComponent("sample.mp4"))
    kept.look.handleText=" @lumio.eth ";kept.look.handlePosition="Top Right";kept.look.handleSize=4.5
    kept.look.progressBar=12;kept.look.progressColor=RGB(0x00AAFF)
    kept.motion.spotlight=70;kept.motion.spotlightSize=30;kept.motion.punchOnCut=55
    var keptSticker=Annotation(kind:"Sticker",start:0.2,end:1.2);keptSticker.text="💎";keptSticker.fontSize=180
    var keptBlock=Annotation(kind:"Hide",start:0,end:2);keptBlock.color=RGB(0x101216)
    kept.annotations=[keptSticker,keptBlock]
    let project=LumioProject(source:kept.source!.path,look:kept.look,start:kept.trimStart,end:kept.trimEnd,videoClips:kept.videoClips,zooms:kept.zooms,motion:kept.motion,annotations:kept.annotations)
    let encoded=try JSONEncoder().encode(project)
    let reopened=try JSONDecoder().decode(LumioProject.self,from:encoded)
    let restoredLook=reopened.look.normalized(),restoredMotion=(reopened.motion ?? MotionSettings()).normalized()
    guard restoredLook.resolvedHandleText=="@lumio.eth",restoredLook.resolvedHandlePosition=="Top Right",abs(restoredLook.resolvedHandleSize-4.5)<0.001 else {
        throw effectsFailure("the handle did not survive the project: \(restoredLook.resolvedHandleText) / \(restoredLook.resolvedHandlePosition)") }
    guard abs(restoredLook.resolvedProgressBar-12)<0.001,restoredLook.resolvedProgressColor==RGB(0x00AAFF) else { throw effectsFailure("the progress bar did not survive the project") }
    guard abs(restoredMotion.resolvedSpotlight-70)<0.001,abs(restoredMotion.resolvedSpotlightSize-30)<0.001,abs(restoredMotion.resolvedPunch-55)<0.001 else {
        throw effectsFailure("the spotlight or the punch did not survive the project") }
    let restoredAnnotations=normalizedAnnotations(reopened.annotations ?? [],duration:3)
    guard restoredAnnotations.count==2,restoredAnnotations.contains(where:{ $0.kind=="Sticker" && $0.text=="💎" && $0.fontSize==180 }),
          restoredAnnotations.contains(where:{ $0.kind=="Hide" }) else {
        throw effectsFailure("stickers and blocks did not survive the project: \(restoredAnnotations.map(\.kind))") }
    // A look nobody touched still equals a fresh one, so normalizing does not invent a bar or a handle.
    guard Look().normalized()==Look(),MotionSettings().normalized()==MotionSettings() else { throw effectsFailure("an untouched look no longer matches a fresh one") }
    // Undo has to take the same settings back.
    kept.previousSnapshot=kept.snapshot
    let before=kept.snapshot
    kept.look.progressBar=0;kept.motion.spotlight=0;kept.annotations=[]
    kept.undoStack=[before];kept.undoEdit()
    guard abs(kept.look.resolvedProgressBar-12)<0.001,abs(kept.motion.resolvedSpotlight-70)<0.001,kept.annotations.count==2 else {
        throw effectsFailure("undo did not bring the new settings back") }
    kept.previewTask?.cancel()
    lines.append("PASS the handle, bar, spotlight, punch, stickers and blocks survive a saved project and come back on undo")

    // The handle: drawn in the corner it was asked for, and nowhere when it is empty.
    let named=Studio();named.preferences.revealExport=false
    await named.load(folder.appendingPathComponent("sample.mp4"))
    named.motion.showCursor=false;named.motion.autoZoom=false
    let unnamed=try await framePixels(named,at:1.5)
    named.look.handleText="@lumio.eth";named.look.handlePosition="Bottom Left";named.look.handleSize=5;named.look.handleOpacity=100
    let bottomLeft=try await framePixels(named,at:1.5)
    named.look.handlePosition="Top Right"
    let topRight=try await framePixels(named,at:1.5)
    // The picture is upright in these pixels, so the first rows are the top of the canvas.
    let lowLeft=patchDistance(unnamed,bottomLeft,x:24,y:height-40,size:30),highRight=patchDistance(unnamed,bottomLeft,x:width-120,y:12,size:30)
    guard lowLeft>4 else { throw effectsFailure("the handle was not drawn in the bottom left: \(lowLeft)") }
    guard highRight<1 else { throw effectsFailure("the handle was drawn in a corner it was not asked for: \(highRight)") }
    guard patchDistance(unnamed,topRight,x:width-120,y:12,size:30)>4 else { throw effectsFailure("the handle did not move to the top right") }
    named.look.handleText=""
    let cleared=try await framePixels(named,at:1.5)
    guard looksDistance(unnamed,cleared)<0.5 else { throw effectsFailure("the handle stayed after it was cleared") }
    guard handleArtwork("",fontSize:40,color:RGB(0xFFFFFF))==nil,handleArtwork("@a",fontSize:40,color:RGB(0xFFFFFF)) != nil else {
        throw effectsFailure("the handle drawing does not handle an empty name") }
    named.previewTask?.cancel()
    lines.append("PASS a handle is drawn in the corner it was given, moves with that choice and leaves no trace when cleared")

    // The punch at a cut: a short snap in, and nothing where a zoom is already running.
    let cuts=[0.0,1.5,2.4]
    let punches=punchZoomClips(cuts:cuts,duration:3,strength:80,avoiding:[])
    guard punches.count==2,let first=punches.first,abs(first.start-1.5)<0.001,first.scale>1.1,first.scale<1.3,first.end<1.9 else {
        throw effectsFailure("the punches are wrong: \(punches.map { ($0.start,$0.scale) })") }
    guard punchZoomClips(cuts:cuts,duration:3,strength:0,avoiding:[]).isEmpty else { throw effectsFailure("a punch was made at zero strength") }
    let busy=[ZoomClip(start:1.2,end:2,scale:2,transition:0.3)]
    guard punchZoomClips(cuts:cuts,duration:3,strength:80,avoiding:busy).count==1 else { throw effectsFailure("a punch was placed inside a zoom") }
    // The pose has to rise at the cut and be back to normal after the punch is over.
    let atCut=motionPose(at:1.62,manual:[],auto:punches,samples:[],settings:MotionSettings())
    let rightAtTheCut=motionPose(at:1.5,manual:[],auto:punches,samples:[],settings:MotionSettings())
    let afterCut=motionPose(at:2.1,manual:[],auto:punches,samples:[],settings:MotionSettings())
    guard atCut.scale>1.1,rightAtTheCut.scale<=1.001,afterCut.scale<=1.001 else {
        throw effectsFailure("the punch does not snap in and back: \(rightAtTheCut.scale) / \(atCut.scale) / \(afterCut.scale)") }
    // And it reaches the picture: the frame right after a cut is not the frame without a punch.
    let punchStudio=Studio();punchStudio.preferences.revealExport=false
    await punchStudio.load(folder.appendingPathComponent("sample.mp4"))
    punchStudio.motion.showCursor=false;punchStudio.motion.autoZoom=false
    punchStudio.videoClips=[VideoClip(sourceStart:0,sourceEnd:1.5,timelineStart:0),VideoClip(sourceStart:1.5,sourceEnd:3,timelineStart:1.5)]
    punchStudio.synchronizeVideoSequence(refresh:false)
    let flat=try await framePixels(punchStudio,at:1.6)
    punchStudio.motion.punchOnCut=90
    let punched=try await framePixels(punchStudio,at:1.6)
    let settledAfter=try await framePixels(punchStudio,at:2.2)
    guard looksDistance(flat,punched)>2 else { throw effectsFailure("the punch did not reach the picture: \(looksDistance(flat,punched))") }
    let quiet=try await framePixels(punchStudio,at:2.2)
    punchStudio.motion.punchOnCut=0
    let quietFlat=try await framePixels(punchStudio,at:2.2)
    guard looksDistance(quiet,quietFlat)<1,looksDistance(settledAfter,quietFlat)<1 else {
        throw effectsFailure("the punch is still there after it should have eased out: \(looksDistance(quiet,quietFlat))") }
    punchStudio.previewTask?.cancel()
    lines.append("PASS a cut punches in and eases back out, and no punch is made where a zoom is already running")

    // The pop: a sticker starts at nothing, overshoots its own size and settles there.
    var sticker=Annotation(kind:"Sticker",start:1,end:3)
    sticker.text="🚀";sticker.fontSize=130
    guard annotationPop(sticker,at:0.9)==0,annotationPop(sticker,at:1)<0.05,annotationPop(sticker,at:1.2)>1.02,
          abs(annotationPop(sticker,at:1.29)-1)<0.05,annotationPop(sticker,at:2)==1 else {
        throw effectsFailure("the pop curve is wrong: \(annotationPop(sticker,at:1)) / \(annotationPop(sticker,at:1.2)) / \(annotationPop(sticker,at:2))") }
    var box=Annotation(kind:"Box",start:1,end:3)
    box.text=""
    guard annotationPop(box,at:1.05)==1 else { throw effectsFailure("a box should not pop") }
    guard let art=annotationArtwork(sticker,frame:CGSize(width:1920,height:1080)),art.image.width>60,art.image.height>60 else {
        throw effectsFailure("the sticker was not drawn") }
    // An emoji carries its own colours, so the drawing has to hold more than one.
    guard let data=NSBitmapImageRep(cgImage:art.image).bitmapData else { throw effectsFailure("the sticker has no pixels") }
    var glyph=[UInt8](repeating:0,count:art.image.width*art.image.height*4)
    for index in 0..<min(glyph.count,art.image.width*art.image.height*4) { glyph[index]=data[index] }
    guard looksColorCount(glyph)>3 else { throw effectsFailure("the sticker was drawn without its colours") }

    // On the video: the sticker is there while it lasts and gone afterwards.
    let overlay=Studio();overlay.preferences.revealExport=false
    await overlay.load(folder.appendingPathComponent("sample.mp4"))
    overlay.look.padding=0;overlay.look.radius=0;overlay.look.shadow=0;overlay.look.glow=0
    overlay.motion.showCursor=false;overlay.motion.autoZoom=false
    let bare=try await framePixels(overlay,at:1.5),bareLate=try await framePixels(overlay,at:2.6)
    var placed=Annotation(kind:"Sticker",start:1,end:2)
    placed.text="🚀";placed.fontSize=220;placed.x=0.44;placed.y=0.4;placed.width=0.12;placed.height=0.2
    overlay.annotations=[placed]
    let withSticker=try await framePixels(overlay,at:1.5)
    let after=try await framePixels(overlay,at:2.6)
    // The glyph covers a small part of the frame, so it is measured where it was put, and against the
    // same moment without it: the recording moves on its own, which would otherwise look like a leftover.
    let changed=patchDistance(bare,withSticker,x:300,y:160,size:30),unchanged=patchDistance(bareLate,after,x:300,y:160,size:30)
    guard changed>12 else { throw effectsFailure("the sticker did not reach the picture: \(changed)") }
    guard unchanged<changed/4 else { throw effectsFailure("the sticker stayed after its range: \(unchanged) vs \(changed)") }
    // The hook line a short video opens with covers the first seconds across the top.
    overlay.annotations=[]
    overlay.addHookText("Watch this")
    guard let hook=overlay.annotations.first,hook.kind=="Text",hook.start==0,hook.end>2,hook.width>0.6,hook.fontSize>60 else {
        throw effectsFailure("the hook line was not added across the top") }
    guard normalizedAnnotations(overlay.annotations,duration:overlay.duration).first?.fontSize==hook.fontSize else {
        throw effectsFailure("the hook line's size was clamped away") }
    overlay.previewTask?.cancel()
    lines.append("PASS stickers pop in with their own colours, leave the picture after their range, and a hook line opens the video")
    return lines
}
