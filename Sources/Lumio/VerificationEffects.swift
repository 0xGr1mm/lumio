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
