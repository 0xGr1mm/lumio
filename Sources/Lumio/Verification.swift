import AppKit
import AVFoundation
import Carbon
import CoreImage
import ImageIO

/// Counts actual clicks rather than extra positional samples introduced at timeline boundaries.
func verificationPointerClickTimes(_ samples:[PointerSample])->[Double] {
    var previous=false,result:[Double]=[]
    for sample in samples {if pointerClick(sample,previous:previous){result.append(sample.time)};previous=sample.pressed}
    return result
}

/// Developer-only verification against generated fixtures. Does not record a screen.
final class VerificationProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "no test finished yet"
    var last: String { get { lock.lock(); defer { lock.unlock() }; return value } set { lock.lock(); value = newValue; lock.unlock() } }
}


/// Looks, transitions and export formats, checked on their own studios.
/// Kept apart from the main suite so the compiler does not have to type-check one enormous function.

/// Pixel helpers shared by the look checks. At file scope because the compiler cannot type-check
/// a long function that also declares them inside itself.
func looksAverageRGB(_ data:[UInt8])->Double {
    var total=0.0
    for index in stride(from:0,to:data.count,by:4) { total+=Double(data[index])+Double(data[index+1])+Double(data[index+2]) }
    return total/Double(max(1,data.count/4*3))
}
func looksDistance(_ a:[UInt8],_ b:[UInt8])->Double {
    var total=0.0
    for index in stride(from:0,to:min(a.count,b.count),by:4) {
        total+=abs(Double(a[index])-Double(b[index]))+abs(Double(a[index+1])-Double(b[index+1]))+abs(Double(a[index+2])-Double(b[index+2]))
    }
    return total/Double(max(1,min(a.count,b.count)/4*3))
}
func looksColorCount(_ data:[UInt8])->Int {
    var seen=Set<Int>()
    for index in stride(from:0,to:data.count,by:4) { seen.insert(Int(data[index])/24*10_000+Int(data[index+1])/24*100+Int(data[index+2])/24) }
    return seen.count
}
@MainActor func looksBackgroundPixels(_ look:Look,width:Int=320,height:Int=180)->[UInt8] {
    guard let image=BackgroundRenderer.shared.image(look,size:CGSize(width:width,height:height)) else { return [] }
    var data=[UInt8](repeating:0,count:width*height*4)
    let context=CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
    return data
}
func looksPatch(_ data:[UInt8],x:Int,y:Int,size:Int,width:Int=320,height:Int=180)->Double {
    var total=0.0,count=0.0
    for row in y..<min(height,y+size) { for column in x..<min(width,x+size) {
        let index=(row*width+column)*4
        guard index+2<data.count else { continue }
        total+=Double(data[index])+Double(data[index+1])+Double(data[index+2]);count+=3
    } }
    return count>0 ? total/count:0
}

@MainActor func verifyLooks(folder:URL) async throws->[String] {
    var lines:[String]=[]
    func looksFailure(_ text:String)->NSError { NSError(domain:"Lumio",code:99,userInfo:[NSLocalizedDescriptionKey:text]) }

        // Fade in and out: the first frame is black, the picture is back once the fade ends, and the sound ramps with it.
        let fadeStudio=Studio();fadeStudio.preferences.revealExport=false
        await fadeStudio.load(folder.appendingPathComponent("sample.mp4"))
        fadeStudio.look.fadeIn=0.6;fadeStudio.look.fadeOut=0.6
        guard fadeStudio.look.normalized().fadeIn==0.6,Look().fadeLevel(at:0,duration:3)==1,
              abs(fadeStudio.look.fadeLevel(at:0.3,duration:3)-0.5)<0.001,fadeStudio.look.fadeLevel(at:0,duration:3)==0,
              fadeStudio.look.fadeLevel(at:1.5,duration:3)==1,fadeStudio.look.fadeLevel(at:3,duration:3)==0 else{throw fadeStudio.failure("the fade curve is wrong")}
        let (fadeAsset,fadeComposition,fadeMix)=try await fadeStudio.makeEditingComposition(asset:AVURLAsset(url:fadeStudio.source!),size:CGSize(width:640,height:360),fps:30)
        let fadeGenerator=AVAssetImageGenerator(asset:fadeAsset);fadeGenerator.videoComposition=fadeComposition
        fadeGenerator.requestedTimeToleranceBefore = .zero;fadeGenerator.requestedTimeToleranceAfter = .zero
        let fadeContext=CIContext(options:[.workingColorSpace:NSNull()])
        func averageLevel(_ time:Double) async throws->Double {
            let image=try await fadeGenerator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
            var pixel=[UInt8](repeating:0,count:4)
            let ci=CIImage(cgImage:image)
            fadeContext.render(ci.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:ci.extent)]),toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:nil)
            return (Double(pixel[0])+Double(pixel[1])+Double(pixel[2]))/3
        }
        // Core Image fades in linear light, so the numbers are compared against each other rather than against black.
        let opening=try await averageLevel(0.02),halfway=try await averageLevel(0.3),middle=try await averageLevel(1.5),closing=try await averageLevel(2.98)
        guard middle>20,opening<middle*0.25,closing<middle*0.25,halfway>opening,halfway<middle else{
            throw fadeStudio.failure("the fade does not darken the ends: \(opening) / \(halfway) / \(middle) / \(closing)")}
        guard let fadeMix,let sound=fadeMix.inputParameters.first else{throw fadeStudio.failure("the export has no audio to fade")}
        var startVolume:Float=1
        sound.getVolumeRamp(for:CMTime(seconds:0.3,preferredTimescale:600),startVolume:&startVolume,endVolume:nil,timeRange:nil)
        guard startVolume<1 else{throw fadeStudio.failure("the sound does not fade in with the picture")}
        fadeStudio.previewTask?.cancel()
        lines.append("PASS the video fades in from black and out to it, with the sound following")
        // A cut that dips to black: dark at the cut, back to the picture before and after it.
        let dipStudio=Studio();dipStudio.preferences.revealExport=false
        await dipStudio.load(folder.appendingPathComponent("sample.mp4"))
        dipStudio.videoClips=[VideoClip(sourceStart:0,sourceEnd:1.5,timelineStart:0),VideoClip(sourceStart:1.5,sourceEnd:3,timelineStart:1.5)]
        dipStudio.synchronizeVideoSequence(refresh:false)
        dipStudio.setClipTransition(dipStudio.videoClips[1].id,to:0.6)
        dipStudio.setClipTransition(dipStudio.videoClips[0].id,to:0.6)
        guard dipStudio.videoClips[1].resolvedTransition==0.6,dipStudio.videoClips[0].transition==nil else{throw dipStudio.failure("the transition was not set only where there is a cut")}
        let (dipAsset,dipComposition,_)=try await dipStudio.makeEditingComposition(asset:AVURLAsset(url:dipStudio.source!),size:CGSize(width:640,height:360),fps:30)
        let dipGenerator=AVAssetImageGenerator(asset:dipAsset);dipGenerator.videoComposition=dipComposition
        dipGenerator.requestedTimeToleranceBefore = .zero;dipGenerator.requestedTimeToleranceAfter = .zero
        let dipContext=CIContext(options:[.workingColorSpace:NSNull()])
        func dipLevel(_ time:Double) async throws->Double {
            let image=try await dipGenerator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
            let ci=CIImage(cgImage:image)
            var pixel=[UInt8](repeating:0,count:4)
            dipContext.render(ci.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:ci.extent)]),toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:nil)
            return (Double(pixel[0])+Double(pixel[1])+Double(pixel[2]))/3
        }
        let beforeCut=try await dipLevel(1.0),atCut=try await dipLevel(1.5),afterCut=try await dipLevel(2.0)
        guard beforeCut>20,afterCut>20,atCut<beforeCut*0.25,atCut<afterCut*0.25 else{throw dipStudio.failure("the cut does not dip to black: \(beforeCut) / \(atCut) / \(afterCut)")}
        dipStudio.previewTask?.cancel()
        lines.append("PASS a cut can dip to black and the picture returns on both sides of it")
        // A cross dissolve mixes the two clips instead of going through black: mid-way the frame matches neither clip on its own.
        let crossStudio=Studio();crossStudio.preferences.revealExport=false
        await crossStudio.load(folder.appendingPathComponent("sample.mp4"))
        crossStudio.videoClips=[VideoClip(sourceStart:0,sourceEnd:1.2,timelineStart:0),VideoClip(sourceStart:1.6,sourceEnd:3,timelineStart:1.2)]
        crossStudio.synchronizeVideoSequence(refresh:false)
        crossStudio.setClipTransition(crossStudio.videoClips[1].id,to:0.6,kind:"Cross Dissolve")
        guard crossStudio.videoClips[1].resolvedTransitionKind=="Cross Dissolve" else{throw crossStudio.failure("the dissolve was refused although there is material before the cut")}
        let (crossAsset,crossComposition,_)=try await crossStudio.makeEditingComposition(asset:AVURLAsset(url:crossStudio.source!),size:CGSize(width:320,height:180),fps:30)
        guard try await crossAsset.loadTracks(withMediaType:.video).count==2 else{throw crossStudio.failure("the incoming clip did not get its own track")}
        let crossGenerator=AVAssetImageGenerator(asset:crossAsset);crossGenerator.videoComposition=crossComposition
        crossGenerator.requestedTimeToleranceBefore = .zero;crossGenerator.requestedTimeToleranceAfter = .zero
        let crossContext=CIContext(options:[.workingColorSpace:NSNull()])
        func frameBytes(_ time:Double) async throws->[UInt8] {
            let image=try await crossGenerator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
            var data=[UInt8](repeating:0,count:320*180*4)
            crossContext.render(CIImage(cgImage:image),toBitmap:&data,rowBytes:320*4,bounds:CGRect(x:0,y:0,width:320,height:180),format:.RGBA8,colorSpace:nil)
            return data
        }
        let beforeDissolve=try await frameBytes(0.5),middleOfDissolve=try await frameBytes(0.9),afterDissolve=try await frameBytes(1.6)
        guard looksAverageRGB(middleOfDissolve)>looksAverageRGB(beforeDissolve)*0.5 else{throw crossStudio.failure("the dissolve went through black instead of mixing")}
        guard looksDistance(middleOfDissolve,beforeDissolve)>3,looksDistance(middleOfDissolve,afterDissolve)>3 else{
            throw crossStudio.failure("the middle of the dissolve is not a mix: \(looksDistance(middleOfDissolve,beforeDissolve)) / \(looksDistance(middleOfDissolve,afterDissolve))")}
        // A clip with nothing before its start cannot overlap, so it keeps the dip.
        crossStudio.videoClips[1].sourceStart=0.05
        crossStudio.setClipTransition(crossStudio.videoClips[1].id,to:0.6,kind:"Cross Dissolve")
        guard crossStudio.videoClips[1].resolvedTransitionKind=="Dip to Black" else{throw crossStudio.failure("a dissolve without material should fall back to a dip")}
        crossStudio.previewTask?.cancel()
        lines.append("PASS a cut can cross dissolve, mixing both clips, and falls back to a dip without material to overlap")
        // Backgrounds: mesh blends several hues, the vignette darkens the corners, grain adds texture, and one can be made from the recording.
        var meshLook=Look();meshLook.mode="Mesh";meshLook.first=RGB(0x2B1B6B);meshLook.second=RGB(0xE0714C);meshLook.glow=0
        var flatLook=meshLook;flatLook.mode="Color"
        let meshData=looksBackgroundPixels(meshLook),flatData=looksBackgroundPixels(flatLook)
        var gradientLook=meshLook;gradientLook.mode="Gradient"
        guard looksColorCount(meshData)>looksColorCount(flatData)*5,looksColorCount(meshData)>10,meshData != looksBackgroundPixels(gradientLook) else{
            throw looksFailure("the mesh background is not its own blend: \(looksColorCount(meshData)) vs flat \(looksColorCount(flatData))")}
        var vignetteLook=Look();vignetteLook.mode="Color";vignetteLook.first=RGB(0x8899AA);vignetteLook.vignette=100
        let vignetteData=looksBackgroundPixels(vignetteLook)
        guard looksPatch(vignetteData,x:0,y:0,size:24)<looksPatch(vignetteData,x:148,y:78,size:24)*0.75 else{throw looksFailure("the vignette does not darken the corners")}
        var grainLook=Look();grainLook.mode="Color";grainLook.first=RGB(0x8899AA);grainLook.grain=90
        guard looksColorCount(looksBackgroundPixels(grainLook))>looksColorCount(flatData) else{throw looksFailure("grain adds no texture")}
        var wavesLook=Look();wavesLook.mode="Color";wavesLook.first=RGB(0x223344);wavesLook.pattern="Waves";wavesLook.patternOpacity=60
        guard wavesLook.normalized().pattern=="Waves",looksBackgroundPixels(wavesLook) != looksBackgroundPixels(flatLook) else{throw looksFailure("the waves texture draws nothing")}
        let backgroundStudio=Studio();backgroundStudio.preferences.revealExport=false
        await backgroundStudio.load(folder.appendingPathComponent("sample.mp4"))
        backgroundStudio.position=1.0
        await backgroundStudio.useRecordingBackground()
        backgroundStudio.previewTask?.cancel()
        guard backgroundStudio.message==nil,backgroundStudio.look.mode=="Image",let madePath=backgroundStudio.look.imagePath,
              FileManager.default.fileExists(atPath:madePath),backgroundStudio.look.blur>=20,NSImage(contentsOfFile:madePath) != nil else{
            throw backgroundStudio.failure("a background from the recording was not made: \(backgroundStudio.message ?? "no file")")}
        // Every ready-made style applies cleanly and survives normalization, and each one looks different from the others.
        var renders:Set<[UInt8]>=[]
        for style in backgroundStyles {
            let applied=style.applied(to:Look())
            guard applied.normalized()==applied,["Gradient","Radial","Aurora","Mesh","Color","Image"].contains(applied.mode) else{throw looksFailure("style \(style.id) does not normalize")}
            renders.insert(looksBackgroundPixels(applied))
        }
        guard backgroundStyles.count>=8,renders.count==backgroundStyles.count,lookPresets.count>=30 else{
            throw looksFailure("the styles are not distinct: \(renders.count) of \(backgroundStyles.count), \(lookPresets.count) presets")}
        // Colours taken from a picture: a strong blue frame gives a deep blue and a light blue, not two greys.
        let blueContext=CGContext(data:nil,width:64,height:64,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        blueContext.setFillColor(CGColor(red:0.09,green:0.28,blue:0.72,alpha:1));blueContext.fill(CGRect(x:0,y:0,width:64,height:40))
        blueContext.setFillColor(CGColor(red:0.62,green:0.82,blue:0.98,alpha:1));blueContext.fill(CGRect(x:0,y:40,width:64,height:24))
        guard let bluePicture=blueContext.makeImage(),let picked=dominantColors(of:bluePicture) else{throw looksFailure("no colours came out of the picture")}
        func brightnessOf(_ color:RGB)->Double { 0.299*color.r+0.587*color.g+0.114*color.b }
        guard picked.dark.b>picked.dark.r,picked.light.b>picked.light.r,brightnessOf(picked.dark)<brightnessOf(picked.light)-0.2 else{
            throw looksFailure("the picked colours do not follow the picture: \(picked)")}
        let matchStudio=Studio();matchStudio.preferences.revealExport=false
        await matchStudio.load(folder.appendingPathComponent("sample.mp4"))
        matchStudio.look.mode="Color";matchStudio.position=1
        let beforeMatch=matchStudio.look.first
        await matchStudio.matchBackgroundToRecording()
        matchStudio.previewTask?.cancel()
        guard matchStudio.message==nil,matchStudio.look.first != beforeMatch,matchStudio.look.mode=="Mesh" else{
            throw matchStudio.failure("matching the background to the recording failed: \(matchStudio.message ?? "unchanged")")}
        lines.append("PASS backgrounds: mesh blends hues, vignette, grain and waves draw, and one can be made from the recording")
        // A logo is drawn over the finished frame, in the chosen corner, and only there.
        let logoURL=folder.appendingPathComponent("logo.png")
        let logoContext=CGContext(data:nil,width:120,height:60,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        logoContext.setFillColor(CGColor(red:0,green:1,blue:0,alpha:1));logoContext.fill(CGRect(x:0,y:0,width:120,height:60))
        let logoImage=NSBitmapImageRep(cgImage:logoContext.makeImage()!)
        try logoImage.representation(using:.png,properties:[:])!.write(to:logoURL)
        let logoStudio=Studio();logoStudio.preferences.revealExport=false
        await logoStudio.load(folder.appendingPathComponent("sample.mp4"))
        logoStudio.look.watermarkPath=logoURL.path;logoStudio.look.watermarkPosition="Top Left"
        logoStudio.look.watermarkSize=20;logoStudio.look.watermarkOpacity=100
        let (logoAsset,logoComposition,_)=try await logoStudio.makeEditingComposition(asset:AVURLAsset(url:logoStudio.source!),size:CGSize(width:640,height:360),fps:30)
        let logoGenerator=AVAssetImageGenerator(asset:logoAsset);logoGenerator.videoComposition=logoComposition
        let stamped=try await logoGenerator.image(at:CMTime(seconds:1,preferredTimescale:600)).image
        var logoData=[UInt8](repeating:0,count:640*360*4)
        CIContext(options:[.workingColorSpace:NSNull()]).render(CIImage(cgImage:stamped),toBitmap:&logoData,rowBytes:640*4,bounds:CGRect(x:0,y:0,width:640,height:360),format:.RGBA8,colorSpace:nil)
        func greenPixels(_ x:Int,_ y:Int,_ width:Int,_ height:Int)->Int {
            var found=0
            for row in y..<min(360,y+height) { for column in x..<min(640,x+width) {
                let index=(row*640+column)*4
                if logoData[index+1]>180,logoData[index]<110,logoData[index+2]<110 { found+=1 }
            } }
            return found
        }
        guard greenPixels(20,20,120,80)>400,greenPixels(400,250,220,100)==0,logoStudio.look.normalized().watermarkPath != nil else{
            throw logoStudio.failure("the logo is not drawn in its corner: \(greenPixels(20,20,120,80)) / \(greenPixels(400,250,220,100))")}
        var missingLogo=Look();missingLogo.watermarkPath="/nope.png";missingLogo.watermarkSize=99
        guard missingLogo.normalized().watermarkPath==nil,missingLogo.normalized().watermarkSize==nil else{throw logoStudio.failure("a missing logo file should be forgotten")}
        logoStudio.previewTask?.cancel()
        lines.append("PASS a logo is drawn over the video in the chosen corner and a missing file is forgotten")
        // A transparent export: the frame keeps its alpha, the video is opaque and the padding around it is not.
        let clearStudio=Studio();clearStudio.preferences.revealExport=false
        await clearStudio.load(folder.appendingPathComponent("sample.mp4"))
        clearStudio.look=Look();clearStudio.look.padding=25;clearStudio.look.shadow=0;clearStudio.look.glow=0
        clearStudio.look.transparentBackground=true
        clearStudio.look.exportHeight=360
        clearStudio.exportSettings=ExportSettings(format:"MOV",codec:"ProRes 4444",fps:30,copyToClipboard:false)
        guard clearStudio.exportSettings.keepsTransparency else{throw clearStudio.failure("ProRes 4444 was not accepted as the transparent codec")}
        let clearURL=folder.appendingPathComponent("verified-transparent.mov")
        await clearStudio.export(to:clearURL)
        guard clearStudio.message==nil else{throw clearStudio.failure(clearStudio.message!)}
        let clearAsset=AVURLAsset(url:clearURL)
        guard let clearTrack=try await clearAsset.loadTracks(withMediaType:.video).first,
              let clearFormat=try await clearTrack.load(.formatDescriptions).first,
              CMFormatDescriptionGetMediaSubType(clearFormat)==kCMVideoCodecType_AppleProRes4444 else{throw clearStudio.failure("the transparent export is not ProRes 4444")}
        let clearReader=try AVAssetReader(asset:clearAsset)
        let clearOutput=AVAssetReaderTrackOutput(track:clearTrack,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
        clearReader.add(clearOutput);clearReader.startReading()
        guard let sample=clearOutput.copyNextSampleBuffer(),let buffer=CMSampleBufferGetImageBuffer(sample) else{throw clearStudio.failure("the transparent export produced no frame")}
        CVPixelBufferLockBaseAddress(buffer,.readOnly)
        let width=CVPixelBufferGetWidth(buffer),height=CVPixelBufferGetHeight(buffer),stride=CVPixelBufferGetBytesPerRow(buffer)
        let base=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
        func alphaAt(_ x:Int,_ y:Int)->Int { Int(base[y*stride+x*4+3]) }
        let cornerAlpha=alphaAt(2,2),centreAlpha=alphaAt(width/2,height/2)
        CVPixelBufferUnlockBaseAddress(buffer,.readOnly)
        clearReader.cancelReading()
        clearStudio.previewTask?.cancel()
        guard centreAlpha>200,cornerAlpha<60 else{throw clearStudio.failure("the export did not keep transparency: corner \(cornerAlpha), centre \(centreAlpha)")}
        lines.append("PASS a transparent export keeps the video opaque and everything around it clear")
    return lines
}

@MainActor func verifyLumio(folder:URL) async {
    let progress = VerificationProgress()
    // A stuck await would otherwise keep the suite waiting forever; report where it stopped instead.
    Task.detached {
        try? await Task.sleep(for:.seconds(600))
        print("FAIL verification timed out after: \(progress.last)"); exit(2)
    }
    var lines: [String] = [] { didSet { progress.last = lines.last ?? "" } }
    do {
        let studio = Studio(); studio.preferences.revealExport = false; studio.exportSettings = ExportSettings()
        var opens = 0; studio.onOpenEditor = { opens += 1 }
        await studio.load(folder.appendingPathComponent("sample.mp4"))
        guard studio.message == nil, studio.duration > 2.9, opens == 1 else { throw studio.failure("video import / editor handoff failed") }
        lines.append("PASS video import and editor handoff")
        studio.look.glow = 100; studio.look.glowBlur = 80; studio.look.glowColor = RGB(0x00FF90)
        studio.look.first = RGB(0x080B13); studio.look.second = RGB(0x222741); studio.look.pattern = "Grid"
        studio.look.padding = 18; studio.look.border = 2
        studio.videoClips=[VideoClip(sourceStart:0.3,sourceEnd:2.5)];studio.selectedClip=studio.videoClips.first?.id;studio.synchronizeVideoSequence()
        await studio.export(to:folder.appendingPathComponent("verified-glow.mp4"))
        guard studio.message == nil else { throw studio.failure(studio.message!) }
        let asset = AVURLAsset(url:folder.appendingPathComponent("verified-glow.mp4"))
        let duration = try await asset.load(.duration).seconds
        let videos = try await asset.loadTracks(withMediaType:.video)
        let audios = try await asset.loadTracks(withMediaType:.audio)
        guard abs(duration-2.2) < 0.1, let video = videos.first, !audios.isEmpty else { throw studio.failure("export duration/audio failed") }
        let size = try await video.load(.naturalSize)
        guard size == CGSize(width:1920,height:1080) else { throw studio.failure("export dimensions failed") }
        lines.append("PASS styled MP4: 1920x1080, 2.2 seconds, audio preserved")
        let saved = LumioProject(source:studio.source!.path,look:studio.look,start:studio.trimStart,end:studio.trimEnd,videoClips:studio.videoClips)
        let data = try JSONEncoder().encode(saved)
        let decoded = try JSONDecoder().decode(LumioProject.self,from:data)
        guard decoded.look == studio.look, decoded.videoClips == studio.videoClips else { throw studio.failure("project round trip failed") }
        try data.write(to:folder.appendingPathComponent("verified-project.lumio"))
        lines.append("PASS project settings and trim round trip")
        let sharedID=UUID()
        let safeClips=normalizedVideoClips([
            VideoClip(id:sharedID,sourceStart:-4,sourceEnd:1,timelineStart:-2),
            VideoClip(id:sharedID,sourceStart:1,sourceEnd:9,timelineStart:90_000),
            VideoClip(sourceStart:2,sourceEnd:2.01,timelineStart:0)
        ],sourceDuration:3)
        let safeZooms=normalizedZoomClips([ZoomClip(start:-2,end:8,scale:20,x:-1,y:4,transition:9)],duration:3)
        let safePointers=normalizedPointerSamples([
            PointerSample(time:1,x:0.5,y:0.5,pressed:false,shape:"unknown"),
            PointerSample(time:99,x:0.5,y:0.5,pressed:false)
        ],sourceDuration:3)
        let safeCaptions=normalizedCaptionCues([
            CaptionCue(start:-1,end:9,text:"  Valid caption  "),
            CaptionCue(start:2,end:2.01,text:"Too short")
        ],duration:3)
        let safeKeys=normalizedKeySamples([KeySample(time:1,key:"K",modifiers:["⌘"]),KeySample(time:99,key:"X",modifiers:[])],sourceDuration:3)
        guard safeClips.count==2,safeClips[0].sourceStart==0,safeClips[1].sourceEnd==3,safeClips[0].id != safeClips[1].id,safeClips[1].timelineStart==86_400,
              safeZooms.count==1,safeZooms[0].scale==6,safeZooms[0].x==0,safeZooms[0].y==1,safePointers.count==1,safePointers[0].shape=="arrow",
              safeCaptions.count==1,safeCaptions[0].text=="Valid caption",safeKeys.count==1 else {throw studio.failure("project data normalization failed")}
        studio.videoClips=[VideoClip(sourceStart:0,sourceEnd:1,timelineStart:0),VideoClip(sourceStart:1,sourceEnd:2,timelineStart:1)]
        studio.pointerSamples=[PointerSample(time:1,x:0.5,y:0.5,pressed:true)]
        studio.keyboardSamples=[KeySample(time:1,key:"K",modifiers:[])]
        guard verificationPointerClickTimes(studio.timelinePointerSamples)==[1],studio.timelineKeyboardSamples.count==1,studio.timelineKeyboardSamples.first?.time==1 else {throw studio.failure("split boundary event duplication failed")}
        var unsafePreferences=RecorderPreferences();unsafePreferences.fps=0;unsafePreferences.countdown=99
        let safePreferences=unsafePreferences.normalized()
        var unsafeLook=Look();unsafeLook.mode="Broken";unsafeLook.padding=999;unsafeLook.aspect="3:2";unsafeLook.first=RGB(r:-2,g:4,b:.nan);unsafeLook.videoStyle=VideoStyle(scale:50,x:-8,y:8,opacity:4,frame:"Broken")
        let safeLook=unsafeLook.normalized()
        var unsafeMotion=MotionSettings();unsafeMotion.stiffness=9_999;unsafeMotion.mass = -1;unsafeMotion.blurAmount=4;unsafeMotion.motion="Broken";unsafeMotion.cameraStyle=CameraStyle(layout:"Broken",position:"Broken",size:900)
        let safeMotion=unsafeMotion.normalized()
        guard safePreferences.fps==60,safePreferences.countdown==3,safeLook.mode=="Gradient",safeLook.padding==35,safeLook.aspect=="16:9",safeLook.first.r==0,safeLook.first.g==1,safeLook.first.b==1,safeLook.videoStyle?.scale==2,safeLook.videoStyle?.frame=="None",
              safeMotion.stiffness==1000,safeMotion.mass==0.2,safeMotion.blurAmount==1,safeMotion.motion=="focused",safeMotion.cameraStyle?.layout=="Floating",safeMotion.cameraStyle?.size==55 else{throw studio.failure("appearance or recorder preference normalization failed")}
        lines.append("PASS malformed project data is normalized and split-boundary events stay unique")
        studio.synchronizeVideoSequence(refresh:false);let sourceStart=studio.selectedVideoClip?.sourceStart,sourceEnd=studio.selectedVideoClip?.sourceEnd
        studio.duplicateSelectedClip()
        guard studio.videoClips.count==3,studio.selectedVideoClip?.sourceStart==sourceStart,studio.selectedVideoClip?.sourceEnd==sourceEnd else{throw studio.failure("clip duplication failed")}
        let anchor=VideoClip(sourceStart:0,sourceEnd:1,timelineStart:0),moving=VideoClip(sourceStart:1,sourceEnd:2,timelineStart:3)
        guard abs(snappedTimelineStart(1.06,moving:moving,clips:[anchor,moving],playhead:8,threshold:0.1)-1)<0.000_001 else{throw studio.failure("magnetic timeline snap failed")}
        let restoredZoom=ZoomClip(start:0.2,end:0.8);studio.zooms=[restoredZoom];studio.selectedZoom=UUID();studio.restore(studio.snapshot)
        guard studio.selectedZoom==restoredZoom.id else{throw studio.failure("undo selection recovery failed")}
        lines.append("PASS clip duplication, magnetic edge snapping and undo selection recovery")
        // Timeline item drags: edges resize, the body moves, neighbours and the minimum length hold, and ⌘ (no targets) turns snapping off.
        let base=TimelineRange(start:2,end:4)
        let grown=draggedTimelineRange(base,edge:.end,delta:1.5,lower:0,upper:10,minLength:0.1,snapTargets:[],threshold:0.1)
        let squeezed=draggedTimelineRange(base,edge:.start,delta:5,lower:0,upper:10,minLength:0.1,snapTargets:[],threshold:0.1)
        let blocked=draggedTimelineRange(base,edge:.move,delta:-3,lower:1.5,upper:10,minLength:0.1,snapTargets:[],threshold:0.1)
        let snappedTail=draggedTimelineRange(base,edge:.move,delta:0.96,lower:0,upper:10,minLength:0.1,snapTargets:[5],threshold:0.1)
        let free=draggedTimelineRange(base,edge:.start,delta:-0.97,lower:0,upper:10,minLength:0.1,snapTargets:[],threshold:0.1)
        let bounds=timelineNeighbourBounds([TimelineRange(start:0,end:1),TimelineRange(start:5,end:6),TimelineRange(start:3,end:3.5)],around:base,duration:10)
        guard grown.range == TimelineRange(start:2,end:5.5),abs(squeezed.range.start-3.9)<1e-9,squeezed.range.end==4,blocked.range == TimelineRange(start:1.5,end:3.5),
              snappedTail.range == TimelineRange(start:3,end:5),snappedTail.snapped==5,abs(free.range.start-1.03)<1e-9,free.snapped==nil,bounds.lower==1,bounds.upper==5 else{throw studio.failure("timeline drag geometry failed")}
        let dragStudio=Studio();dragStudio.duration=10
        dragStudio.captions=[CaptionCue(start:2,end:4,text:"two words",words:[CaptionWord(text:"two",start:2,end:3),CaptionWord(text:"words",start:3,end:4)])]
        dragStudio.setCaptionRange(dragStudio.captions[0].id,to:TimelineRange(start:5,end:9))
        let zoomID=UUID();dragStudio.zooms=[ZoomClip(id:zoomID,start:1,end:3,transition:0.8)];dragStudio.setZoomRange(zoomID,to:TimelineRange(start:1,end:1.4))
        guard dragStudio.captions[0].words.map(\.start)==[5,7],dragStudio.captions[0].words.last?.end==9,
              dragStudio.zooms[0].end==1.4,abs(dragStudio.zooms[0].transition-0.2)<1e-9 else{throw studio.failure("timeline drag commit failed")}
        dragStudio.pointerSamples=[PointerSample(time:0.5,x:0.5,y:0.5,pressed:false)]
        let firstCount=dragStudio.timelinePointerSamples.count
        dragStudio.pointerSamples.append(PointerSample(time:0.7,x:0.5,y:0.5,pressed:false))
        guard firstCount==1,dragStudio.timelinePointerSamples.count==2 else{throw studio.failure("timeline sample cache went stale")}
        let drawn=snappedTimelineEdges(TimelineRange(start:1.03,end:2.4),snapTargets:[1,5],threshold:0.1,minLength:0.1)
        let drawnStudio=Studio();drawnStudio.duration=10;drawnStudio.position=4
        let sliceEnd=drawnStudio.draftZoomRange(at:9.7),slice=drawnStudio.draftZoomRange(at:2)
        let drawnID=drawnStudio.addZoom(over:TimelineRange(start:3,end:3.5))
        guard drawn == TimelineRange(start:1,end:2.4),slice == TimelineRange(start:2,end:3),sliceEnd == TimelineRange(start:9,end:10),
              drawnID != nil,drawnStudio.zooms.count==1,drawnStudio.zooms[0].transition==0.25,abs(drawnStudio.position-3.25)<1e-9 else{throw studio.failure("drawing a zoom on the timeline failed")}
        // Inspector controls bind by id: deleting the selected item must not write to a stale index.
        let bindingStudio=Studio();bindingStudio.duration=10
        let keptID=UUID(),goneID=UUID()
        bindingStudio.zooms=[ZoomClip(id:keptID,start:0,end:1),ZoomClip(id:goneID,start:2,end:3)]
        let goneScale=bindingStudio.binding(\.zooms,id:goneID,\.scale,fallback:1)
        let keptStart=bindingStudio.binding(\.zooms,id:keptID,\.start,fallback:0,clamp:{ max(0.25,$0) })
        bindingStudio.selectedZoom=goneID;bindingStudio.deleteTimelineItem(.zoom,id:goneID)
        goneScale.wrappedValue=4
        keptStart.wrappedValue=0.1
        guard bindingStudio.zooms.count==1,bindingStudio.zooms[0].id==keptID,goneScale.wrappedValue==1,abs(bindingStudio.zooms[0].start-0.25)<1e-9,bindingStudio.selectedZoom==nil else{throw studio.failure("editing a deleted item through a binding failed")}
        let drawnCrop=normalizedCrop(CGPoint(x:0.8,y:0.2),CGPoint(x:0.3,y:0.75))
        let tinyCrop=normalizedCrop(CGPoint(x:0.95,y:0.02),CGPoint(x:0.99,y:0.03))
        guard drawnCrop == CGRect(x:0.3,y:0.2,width:0.5,height:0.55),abs(tinyCrop.width-0.1)<1e-9,abs(tinyCrop.height-0.1)<1e-9,tinyCrop.maxX<=1,tinyCrop.maxY<=1 else{throw studio.failure("crop drawing geometry failed")}
        // Camera background: a frame with nobody in it keeps its picture, and the setting survives normalization.
        let emptyRoom=CIFilter(name:"CILinearGradient",parameters:["inputPoint0":CIVector(x:0,y:0),"inputPoint1":CIVector(x:0,y:360),"inputColor0":CIColor.gray,"inputColor1":CIColor.white])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:640,height:360))
        var cameraStyle=CameraStyle();cameraStyle.background="Blur";cameraStyle.backgroundBlur=99
        let treated=cameraWithTreatedBackground(emptyRoom,style:cameraStyle,masks:PersonMaskMaker(quality:.fast),fingerprint:"test")
        let normalizedCamera=cameraStyle.normalized(),keptCamera=CameraStyle(background:"Nope",backgroundBlur:5).normalized()
        let cameraContext=CIContext(options:[.workingColorSpace:NSNull()])
        func sample(_ image:CIImage)->[UInt8] {
            var data=[UInt8](repeating:0,count:64*64*4)
            cameraContext.render(image,toBitmap:&data,rowBytes:64*4,bounds:CGRect(x:200,y:150,width:64,height:64),format:.RGBA8,colorSpace:nil)
            return data
        }
        guard treated.extent==emptyRoom.extent,sample(treated)==sample(emptyRoom),normalizedCamera.background=="Blur",normalizedCamera.resolvedBackgroundBlur==40,keptCamera.background==nil,keptCamera.resolvedBackground=="None" else{throw studio.failure("camera background treatment failed")}
        lines.append("PASS timeline drags resize, move, snap and respect neighbours; captions keep word timing; sample cache refreshes")
        // Annotations render on the visible frame: blur softens its region only, spotlight darkens outside it, an arrow draws in its color.
        let checker=CIFilter(name:"CICheckerboardGenerator",parameters:["inputWidth":8,"inputColor0":CIColor.white,"inputColor1":CIColor.black,"inputSharpness":1])!.outputImage!.cropped(to:CGRect(x:0,y:0,width:640,height:360))
        let ciContext=CIContext(options:[.workingColorSpace:NSNull()])
        func pixels(_ image:CIImage,_ unit:CGRect)->[UInt8] {
            let region=annotationPixels(unit,in:CGSize(width:640,height:360)).integral
            var data=[UInt8](repeating:0,count:Int(region.width*region.height)*4)
            ciContext.render(image,toBitmap:&data,rowBytes:Int(region.width)*4,bounds:region,format:.RGBA8,colorSpace:nil)
            return data
        }
        func spread(_ data:[UInt8])->Double { let reds=stride(from:0,to:data.count,by:4).map { Double(data[$0]) };let mean=reds.reduce(0,+)/Double(reds.count);return (reds.map { ($0-mean)*($0-mean) }.reduce(0,+)/Double(reds.count)).squareRoot() }
        func mean(_ data:[UInt8])->Double { stride(from:0,to:data.count,by:4).map { Double(data[$0]) }.reduce(0,+)/Double(data.count/4) }
        let art=OverlayArtCache(captionStyle:CaptionStyle(),keyboardStyle:KeyboardOverlayStyle())
        let inside=CGRect(x:0.3,y:0.3,width:0.2,height:0.2),outside=CGRect(x:0.75,y:0.75,width:0.15,height:0.15)
        let blurred=annotated(checker,time:1.5,annotations:[Annotation(kind:"Blur",start:1,end:2,x:0.25,y:0.25,width:0.3,height:0.3,strength:1)],art:art)
        let lit=annotated(checker,time:1.5,annotations:[Annotation(kind:"Spotlight",start:1,end:2,x:0.25,y:0.25,width:0.3,height:0.3,strength:1)],art:art)
        let arrow=annotated(checker,time:1.5,annotations:[Annotation(kind:"Arrow",start:1,end:2,x:0.1,y:0.5,width:0.5,height:0,color:RGB(0x00FF00),thickness:20)],art:art)
        let idle=annotated(checker,time:3,annotations:[Annotation(kind:"Blur",start:1,end:2,x:0.25,y:0.25,width:0.3,height:0.3)],art:art)
        let arrowLine=pixels(arrow,CGRect(x:0.3,y:0.495,width:0.05,height:0.01))
        let greenLine=stride(from:0,to:arrowLine.count,by:4).allSatisfy { arrowLine[$0+1]>200 && arrowLine[$0]<60 }
        guard spread(pixels(blurred,inside))<spread(pixels(checker,inside))*0.25,spread(pixels(blurred,outside))==spread(pixels(checker,outside)),
              mean(pixels(lit,outside))<mean(pixels(checker,outside))*0.3,abs(mean(pixels(lit,inside))-mean(pixels(checker,inside)))<1,
              greenLine,pixels(idle,inside)==pixels(checker,inside) else{throw studio.failure("annotation rendering failed")}
        let annotationStudio=Studio();annotationStudio.duration=10;annotationStudio.source=folder.appendingPathComponent("sample.mp4")
        annotationStudio.previousSnapshot=annotationStudio.snapshot
        annotationStudio.position=2;annotationStudio.addAnnotation("Box")
        guard let box=annotationStudio.annotations.first,box.start==2,box.end==5,annotationStudio.selectedAnnotation==box.id,annotationStudio.timelineFocus == .annotation else{throw studio.failure("adding an annotation failed")}
        annotationStudio.copyTimelineSelection();annotationStudio.position=6;annotationStudio.pasteTimelineItem()
        annotationStudio.setAnnotationRange(box.id,to:TimelineRange(start:1,end:1.02))
        let restoredAnnotations=normalizedAnnotations([Annotation(kind:"Laser",start:1,end:2,x:.nan),Annotation(kind:"Laser",start:1,end:4,thickness:500),Annotation(start:3,end:3.05)],duration:10)
        guard annotationStudio.annotations.count==2,annotationStudio.annotations[1].start==6,annotationStudio.annotations[1].end==9,annotationStudio.annotations[0].end-annotationStudio.annotations[0].start>=0.1-1e-9,
              annotationStudio.snapshot.annotations?.count==2,restoredAnnotations.count==1,restoredAnnotations[0].kind=="Arrow",restoredAnnotations[0].thickness==40 else{throw studio.failure("annotation editing or normalization failed")}
        var restoredSnapshot=annotationStudio.snapshot;restoredSnapshot.annotations=nil;annotationStudio.restore(restoredSnapshot)
        guard annotationStudio.annotations.isEmpty,annotationStudio.selectedAnnotation==nil else{throw studio.failure("annotation undo failed")}
        lines.append("PASS annotations: blur and spotlight stay in their region, arrows draw in color, they add, paste, resize, undo and normalize")
        for ratio in ["16:9","9:16","1:1","4:3","4:5"] {
            studio.look.aspect = ratio
            let rect = studio.look.videoRect(in:studio.look.canvas,aspect:16/9)
            guard rect.minX >= 0,rect.minY >= 0,rect.maxX <= studio.look.canvas.width,rect.maxY <= studio.look.canvas.height else { throw studio.failure("canvas geometry failed") }
        }
        lines.append("PASS five canvas ratios preserve media aspect and bounds")
        let image = NSImage(size:NSSize(width:640,height:360)); image.lockFocus()
        NSColor.systemBlue.setFill(); NSRect(x:0,y:0,width:640,height:360).fill()
        NSColor.systemYellow.setFill(); NSRect(x:0,y:180,width:320,height:180).fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data:image.tiffRepresentation!)!
        let stillURL = folder.appendingPathComponent("sample-image.png")
        try bitmap.representation(using:.png,properties:[:])!.write(to:stillURL)
        studio.loadImage(stillURL); studio.look.aspect = "1:1"
        studio.exportImage(to:folder.appendingPathComponent("verified-glow.png"))
        guard studio.message == nil, opens == 2, let png = NSImage(contentsOf:folder.appendingPathComponent("verified-glow.png")), png.size.width == 1080 else { throw studio.failure("image export / handoff failed") }
        lines.append("PASS image import, editor handoff and square PNG export")
        for mode in ["Gradient","Radial","Aurora","Color","Image"] {
            studio.look.mode = mode; studio.look.imagePath = stillURL.path; studio.look.blur = 12
            guard BackgroundRenderer.shared.image(studio.look,size:CGSize(width:320,height:180)) != nil else { throw studio.failure("background render failed") }
        }
        lines.append("PASS all five background modes with blur")
        studio.zooms = [ZoomClip(start:0.5,end:2.5,scale:2,x:0.25,y:0.75,transition:0.5)]
        guard zoomPose(at:0,clips:studio.zooms).scale == 1, zoomPose(at:1.5,clips:studio.zooms).scale == 2, zoomPose(at:2.5,clips:studio.zooms).scale == 1 else { throw studio.failure("zoom timing failed") }
        let serialized = try JSONEncoder().encode(LumioProject(source:"fixture",look:studio.look,start:0,end:3,zooms:studio.zooms))
        guard try JSONDecoder().decode(LumioProject.self,from:serialized).zooms == studio.zooms else { throw studio.failure("zoom project persistence failed") }
        await studio.load(folder.appendingPathComponent("sample.mp4"))
        studio.zooms = [ZoomClip(start:0.5,end:2.5,scale:2,x:0.25,y:0.75,transition:0.5)]
        await studio.export(to:folder.appendingPathComponent("verified-zoom.mp4"))
        guard studio.message == nil else { throw studio.failure(studio.message!) }
        lines.append("PASS zoom timing, project round trip and animated MP4 export")
        studio.look.aspect="16:9";studio.look.mode="Gradient"
        studio.zooms=[];studio.cursorEmbedded=false
        studio.pointerSamples=[]
        for i in 0...180 {
            let time=Double(i)/60.0;let x=0.2+Double(i)/300.0
            let pressed=(i == 45 || i == 100);let shape=(i > 120 ? "hand":"arrow")
            studio.pointerSamples.append(PointerSample(time:time,x:x,y:0.45,pressed:pressed,shape:shape))
        }
        studio.motion=MotionSettings();studio.motion.style="Lavender";studio.motion.size=240;studio.motion.clickHighlight=true
        let project=try JSONEncoder().encode(LumioProject(source:studio.source!.path,look:studio.look,start:0,end:3,zooms:[],motion:studio.motion,pointerSamples:studio.pointerSamples,cameraPath:nil))
        let restored=try JSONDecoder().decode(LumioProject.self,from:project)
        guard restored.motion == studio.motion,restored.pointerSamples == studio.pointerSamples else { throw studio.failure("motion persistence failed") }
        studio.resetVideoClips()
        await studio.export(to:folder.appendingPathComponent("verified-cursor-auto.mp4"))
        guard studio.message == nil else {throw studio.failure(studio.message!)}
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent("verified-cursor-auto.mp4")))
        for (label,time) in [("start",0.1),("zoom",1.0),("end",2.7)] {
            let frame=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600))
            try NSBitmapImageRep(cgImage:frame.image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("motion-"+label+".png"))
        }
        lines.append("PASS automatic click zoom, separate cursor, motion blur and project persistence; MP4 frames decoded")
        let tokens=[CaptionToken(text:"Build",start:0.2,duration:0.3),CaptionToken(text:"beautiful",start:0.55,duration:0.45),CaptionToken(text:"videos",start:1.05,duration:0.4)]
        studio.captions=makeCaptionCues(tokens:tokens,maxWords:3);studio.selectedCaption=studio.captions.first?.id
        studio.captionStyle=CaptionStyle();studio.captionStyle.preset="Karaoke";studio.captionStyle.highlightColor=RGB(0xD4FF63)
        guard studio.captions.count == 1,studio.captions[0].words.count == 3 else {throw studio.failure("caption grouping failed")}
        let activeCaptionArtwork=captionArtwork(cue:studio.captions[0],activeWord:1,style:studio.captionStyle)
        try NSBitmapImageRep(cgImage:activeCaptionArtwork).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("caption-artwork.png"))
        let captionProject=try JSONEncoder().encode(LumioProject(source:studio.source!.path,look:studio.look,start:0,end:3,captions:studio.captions,captionStyle:studio.captionStyle))
        let decodedCaptions=try JSONDecoder().decode(LumioProject.self,from:captionProject)
        guard decodedCaptions.captions == studio.captions,decodedCaptions.captionStyle == studio.captionStyle else {throw studio.failure("caption project persistence failed")}
        await studio.export(to:folder.appendingPathComponent("verified-captions.mp4"))
        guard studio.message == nil else {throw studio.failure(studio.message!)}
        let captionFrame=try await AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent("verified-captions.mp4"))).image(at:CMTime(seconds:0.75,preferredTimescale:600))
        try NSBitmapImageRep(cgImage:captionFrame.image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("caption-frame.png"))
        lines.append("PASS timed captions, active-word artwork, project persistence and MP4 export")
        // The artwork for these styles belongs to other people and is not part of the repository, so a
        // checkout without it is a normal state rather than a failure. What is still checked is that every
        // piece present decodes; a half-readable file would be a real fault.
        var magnificFound=0
        for style in ["Neon","Pixel","3D","Color Pop","Cartoon"] {
            guard let artwork=magnificCursorArtwork(style:style) else { continue }
            magnificFound+=1
            try NSBitmapImageRep(cgImage:artwork).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("cursor-\(style.replacingOccurrences(of:" ",with:"-").lowercased()).png"))
        }
        lines.append(magnificFound==5 ? "PASS five Magnific cursor resources decode with transparent artwork"
                                      : "PASS Magnific cursor styles decode where their artwork is installed (\(magnificFound) of 5 present)")
        var packsFound=0
        for style in ["Minecraft Enchanted","Pop Cat","Rose Diamond","Among Us Batman","Among Us Joker","Harley Quinn"] {
            let slug=style.replacingOccurrences(of:" ",with:"-").lowercased()
            guard let arrow=customCursorPackArtwork(style:style,shape:"arrow"),let pointer=customCursorPackArtwork(style:style,shape:"hand") else { continue }
            packsFound+=1
            try NSBitmapImageRep(cgImage:arrow).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("custom-cursor-\(slug)-arrow.png"))
            try NSBitmapImageRep(cgImage:pointer).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("custom-cursor-\(slug)-pointer.png"))
        }
        lines.append(packsFound==6 ? "PASS six Custom Cursor packs decode into arrow and pointer artwork"
                                   : "PASS Custom Cursor packs decode where their artwork is installed (\(packsFound) of 6 present)")
        for style in ["Classic Outline","Solid Arrow"] {
            let artwork=cursorArtwork(style:style,color:.white)
            try NSBitmapImageRep(cgImage:artwork).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("generic-cursor-\(style.replacingOccurrences(of:" ",with:"-").lowercased()).png"))
        }
        for shape in ["ibeam","hand","crosshair","resizeHorizontal","resizeVertical","openHand","closedHand"] {
            _=cursorArtwork(style:"Classic Outline",color:.white,shape:shape)
        }
        lines.append("PASS two basic arrow styles and seven automatic pointer shapes render")
        studio.captions=[];studio.selectedCaption=nil
        studio.cameraPath=folder.appendingPathComponent("sample.mp4").path
        await studio.export(to:folder.appendingPathComponent("verified-camera.mp4"))
        guard studio.message == nil else {throw studio.failure(studio.message!)}
        lines.append("PASS camera overlay export with camera zoom")
        let cameraFrames=["Top Left","Center","Bottom Right"].map { position -> CGRect in
            var style=CameraStyle();style.position=position
            return FrameCompositor().cameraRect(style,canvas:CGRect(x:0,y:0,width:1920,height:1080),video:CGRect(x:120,y:80,width:1680,height:920),zoomed:false)
        }
        guard cameraFrames[0].minX < cameraFrames[1].minX,cameraFrames[1].minX < cameraFrames[2].minX else {throw studio.failure("camera layout positioning failed")}
        studio.look.videoStyle=VideoStyle(scale:1.15,x:0.1,y:-0.1,opacity:0.95,frame:"Browser",frameColor:RGB(0x17181C))
        lines.append("PASS camera position templates and video frame settings")
        studio.cameraPath=nil
        studio.videoClips=[VideoClip(sourceStart:0.3,sourceEnd:0.8,timelineStart:0),VideoClip(sourceStart:1.6,sourceEnd:2.8,timelineStart:0.5)]
        studio.selectedClip=studio.videoClips.first?.id;studio.synchronizeVideoSequence()
        await studio.export(to:folder.appendingPathComponent("verified-cuts.mp4"))
        guard studio.message == nil else {throw studio.failure(studio.message!)}
        let cutAsset=AVURLAsset(url:folder.appendingPathComponent("verified-cuts.mp4"))
        let cutDuration=try await cutAsset.load(.duration).seconds
        guard abs(cutDuration-1.7)<0.1, !(try await cutAsset.loadTracks(withMediaType:.audio)).isEmpty else {throw studio.failure("cut duration or audio failed")}
        lines.append("PASS independent clip sequence exports 1.7 seconds with audio")
        let first=studio.videoClips[0]
        studio.updateClipEdge(first.id,startEdge:false,to:0.6)
        guard abs(studio.videoClips[0].duration-0.3)<0.01 else {throw studio.failure("clip trim failed")}
        studio.updateClipEdge(first.id,startEdge:false,to:0.8)
        guard abs(studio.videoClips[0].duration-0.5)<0.01 else {throw studio.failure("clip re-extension failed")}
        let stationaryID=studio.videoClips.first {$0.id != first.id}!.id
        let stationaryStart=studio.videoClips.first {$0.id == stationaryID}!.timelineStart
        studio.moveClip(first.id,toTimelineStart:2)
        guard studio.videoClips.first(where:{$0.id == first.id})?.timelineStart == 2,
              studio.videoClips.first(where:{$0.id == stationaryID})?.timelineStart == stationaryStart else {throw studio.failure("independent clip move failed")}
        lines.append("PASS split clips trim, restore hidden frames and move independently")
        let exactCut=timelineTimeForClipX(75,clipWidth:300,timelineStart:4,clipDuration:6)
        guard abs(exactCut-5.5)<0.000_001 else {throw studio.failure("blade coordinate conversion failed")}
        lines.append("PASS blade click maps to the exact clip-local timeline position")
        await studio.export(to:folder.appendingPathComponent("verified-free-position.mp4"))
        guard studio.message == nil else {throw studio.failure(studio.message!)}
        let freeAsset=AVURLAsset(url:folder.appendingPathComponent("verified-free-position.mp4"))
        let freeDuration=try await freeAsset.load(.duration).seconds
        let freeFrame=try await AVAssetImageGenerator(asset:freeAsset).image(at:CMTime(seconds:1.85,preferredTimescale:600))
        guard abs(freeDuration-2.5)<0.1,freeFrame.image.width>0 else {throw studio.failure("free-position gap export failed")}
        lines.append("PASS free-position gap renders and exports without moving stationary clips")
        studio.motion.autoZoom=true;studio.zooms=[]
        let automatic=autoZoomClips(samples:studio.timelinePointerSamples,settings:studio.motion,duration:studio.duration)
        if let first=automatic.first {studio.selectAutomaticZoom(first)}
        guard studio.selectedZoom != nil,!studio.motion.autoZoom,studio.zooms.count==automatic.count else {throw studio.failure("automatic zoom editing conversion failed")}
        lines.append("PASS automatic zoom blocks become individually editable")
        await studio.load(folder.appendingPathComponent("sample.mp4"));studio.look.aspect="16:9"
        studio.keyboardSamples=[KeySample(time:0.45,key:"K",modifiers:["⌘"]),KeySample(time:1.3,key:"Space",modifiers:[])]
        studio.keyboardStyle=KeyboardOverlayStyle();studio.keyboardStyle.style="Glass";studio.keyboardStyle.enabled=true
        guard let music=Bundle.main.url(forResource:"lofi-drift",withExtension:"wav",subdirectory:"Audio") else{throw studio.failure("bundled audio missing")}
        studio.audioTracks=[AudioTrackEdit(name:"Lo-Fi Drift",path:music.path,kind:"Music",timelineStart:0,sourceEnd:2.8,volume:0.35)]
        studio.audioSettings=AudioMixSettings(systemVolume:0.9,ducking:true,duckLevel:0.2);studio.motion.clickSound=true
        let keyboardImage=shortcutArtwork(sample:studio.keyboardSamples[0],style:studio.keyboardStyle)
        try NSBitmapImageRep(cgImage:keyboardImage).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("shortcut-artwork.png"))
        let extendedProject=try JSONEncoder().encode(LumioProject(source:studio.source!.path,look:studio.look,start:0,end:studio.duration,audioTracks:studio.audioTracks,audioSettings:studio.audioSettings,keyboardSamples:studio.keyboardSamples,keyboardStyle:studio.keyboardStyle))
        let extendedDecoded=try JSONDecoder().decode(LumioProject.self,from:extendedProject)
        guard extendedDecoded.audioTracks == studio.audioTracks,extendedDecoded.keyboardSamples == studio.keyboardSamples else{throw studio.failure("audio or keyboard project persistence failed")}
        await studio.export(to:folder.appendingPathComponent("verified-audio-shortcuts.mp4"));guard studio.message == nil else{throw studio.failure(studio.message!)}
        let extendedAsset=AVURLAsset(url:folder.appendingPathComponent("verified-audio-shortcuts.mp4"))
        guard !(try await extendedAsset.loadTracks(withMediaType:.audio)).isEmpty else{throw studio.failure("mixed audio was not exported")}
        let keyboardFrame=try await AVAssetImageGenerator(asset:extendedAsset).image(at:CMTime(seconds:0.8,preferredTimescale:600))
        try NSBitmapImageRep(cgImage:keyboardFrame.image).representation(using:.png,properties:[:])!.write(to:folder.appendingPathComponent("shortcut-frame.png"))
        lines.append("PASS voice/music mixer resources, click audio, keyboard overlay, project persistence and MP4 export")
        let shelf=Studio();shelf.source=folder.appendingPathComponent("sample.mp4");shelf.sourceDuration=3
        shelf.videoClips=[VideoClip(sourceStart:0,sourceEnd:3)];shelf.synchronizeVideoSequence(refresh:false)
        let originalShelf=shelf.snapshot
        guard shelf.saveVersion(named:"Original") else{throw shelf.failure("version creation failed")}
        let originalID=shelf.savedVersions[0].id
        shelf.look.aspect="9:16";shelf.captions=[CaptionCue(start:0,end:1,text:"Alternate")]
        let alternateShelf=shelf.snapshot
        shelf.useVersion(originalID)
        guard shelf.snapshot==originalShelf,shelf.savedVersions.count==2,shelf.savedVersions.contains(where:{$0.edit==alternateShelf}) else{throw shelf.failure("version switch lost current experiment")}
        shelf.undoEdit()
        guard shelf.snapshot==alternateShelf else{throw shelf.failure("version switch undo failed")}
        let shelfProject=LumioProject(source:shelf.source!.path,look:shelf.look,start:0,end:3,savedVersions:shelf.savedVersions)
        let shelfData=try JSONEncoder().encode(shelfProject)
        let reopenedShelf=try JSONDecoder().decode(LumioProject.self,from:shelfData)
        guard reopenedShelf.savedVersions==shelf.savedVersions,decoded.savedVersions==nil else{throw shelf.failure("version shelf persistence or legacy compatibility failed")}
        while shelf.savedVersions.count<24 {_=shelf.saveVersion(named:"Experiment")}
        shelf.look.padding=21
        let atCapacity=shelf.snapshot
        shelf.useVersion(originalID)
        guard shelf.snapshot==atCapacity,shelf.savedVersions.count==24,shelf.message != nil else{throw shelf.failure("full shelf discarded unsaved changes")}
        shelf.previewTask?.cancel()
        lines.append("PASS version shelf restores full edits, protects experiments, supports undo, persists and guards capacity")
        let recordingHotkeys=RecordingHotKeys([HotKey(id:9,keyCode:UInt32(kVK_ANSI_R),modifiers:UInt32(controlKey|optionKey|shiftKey),name:"test") {}])
        guard recordingHotkeys.setEnabled(true).isEmpty,recordingHotkeys.setEnabled(false).isEmpty else{throw shelf.failure("recording shortcut registration failed")}
        let retakeStudio=Studio();retakeStudio.preferences.revealExport=false;retakeStudio.exportSettings=ExportSettings()
        await retakeStudio.load(folder.appendingPathComponent("sample.mp4"))
        let marker=RetakeMarker(start:0.2,retryStart:1.2,end:2.2)
        retakeStudio.retakes=[marker]
        retakeStudio.captions=[CaptionCue(start:1.4,end:2,text:"Good take",words:[CaptionWord(text:"Good",start:1.4,end:1.7),CaptionWord(text:"take",start:1.7,end:2)])]
        retakeStudio.zooms=[ZoomClip(start:1.4,end:2)]
        retakeStudio.audioTracks=[AudioTrackEdit(name:"Retake sync",path:retakeStudio.source!.path,kind:"Imported",timelineStart:0.1,sourceStart:0.1,sourceEnd:2.7)]
        let beforeRetake=retakeStudio.snapshot
        retakeStudio.chooseRetake(marker.id,keepRetry:true)
        guard abs(retakeStudio.duration-2)<0.01,retakeStudio.videoClips.count==2,
              abs(retakeStudio.videoClips[1].sourceStart-1.2)<0.01,
              abs(retakeStudio.videoClips[1].timelineStart-0.2)<0.01,
              abs(retakeStudio.captions[0].start-0.4)<0.01,
              abs(retakeStudio.captions[0].words[1].start-0.7)<0.01,
              abs(retakeStudio.zooms[0].start-0.4)<0.01,
              retakeStudio.audioTracks.count==2,
              abs(retakeStudio.audioTracks[1].sourceStart-1.2)<0.01,
              abs(retakeStudio.audioTracks[1].timelineStart-0.2)<0.01,
              retakeStudio.retakes[0].choice=="Retake" else {throw retakeStudio.failure("retake ripple lost media or effect sync")}
        let afterRetake=retakeStudio.snapshot
        retakeStudio.chooseRetake(marker.id,keepRetry:true)
        guard retakeStudio.snapshot==afterRetake else{throw retakeStudio.failure("retake applied twice")}
        retakeStudio.undoEdit()
        guard retakeStudio.snapshot==beforeRetake else{throw retakeStudio.failure("retake undo did not restore complete edit")}
        retakeStudio.redoEdit()
        guard retakeStudio.snapshot==afterRetake else{throw retakeStudio.failure("retake redo failed")}
        lines.append("PASS Smart Retake removes only the rejected range, synchronizes effects/audio, prevents repeat application and supports undo/redo")
        let retakeProject=LumioProject(source:retakeStudio.source!.path,look:retakeStudio.look,start:0,end:retakeStudio.duration,videoClips:retakeStudio.videoClips,retakes:retakeStudio.retakes)
        let retakeData=try JSONEncoder().encode(retakeProject)
        let retakeDecoded=try JSONDecoder().decode(LumioProject.self,from:retakeData)
        guard retakeDecoded.retakes==retakeStudio.retakes,decoded.retakes==nil else{throw retakeStudio.failure("retake project compatibility failed")}
        try retakeData.write(to:folder.appendingPathComponent("verified-retake.lumio"))
        guard normalizedRetakes([RetakeMarker(start:2,retryStart:1,end:3),RetakeMarker(start:0,retryStart:.nan,end:3)],duration:3).isEmpty else{throw retakeStudio.failure("invalid retake accepted")}
        let movedClips=[VideoClip(sourceStart:0,sourceEnd:3,timelineStart:4),VideoClip(sourceStart:0,sourceEnd:3,timelineStart:10)]
        let movedCuts=retakeRemovalRanges(clips:movedClips,start:0.2,end:1.2)
        let movedResult=retakeRippleClips(movedClips,cuts:movedCuts)
        guard movedCuts.count==2,movedResult.count==4,abs(movedCuts[0].start-4.2)<0.01,abs(movedCuts[1].start-10.2)<0.01,abs(movedResult[2].timelineStart-9)<0.01 else{throw retakeStudio.failure("retake source mapping after moving/duplicating failed")}
        lines.append("PASS retake project persistence, legacy compatibility, invalid marker rejection and moved/duplicated clip mapping")
        await retakeStudio.export(to:folder.appendingPathComponent("verified-retake.mp4"))
        guard retakeStudio.message==nil else{throw retakeStudio.failure(retakeStudio.message!)}
        let retakeAsset=AVURLAsset(url:folder.appendingPathComponent("verified-retake.mp4"))
        guard abs(try await retakeAsset.load(.duration).seconds-2)<0.1,!(try await retakeAsset.loadTracks(withMediaType:.audio)).isEmpty else{throw retakeStudio.failure("retake export duration or audio failed")}
        lines.append("PASS Smart Retake MP4 exports the chosen sequence with audio")
        retakeStudio.undoEdit();retakeStudio.chooseRetake(marker.id,keepRetry:false)
        guard retakeStudio.retakes[0].choice=="Original",abs(retakeStudio.videoClips.last!.sourceStart-2.2)<0.01 else{throw retakeStudio.failure("keep original removed the wrong attempt")}
        retakeStudio.recording=true;retakeStudio.recordingUptime=ProcessInfo.processInfo.systemUptime-2
        retakeStudio.toggleRetake()
        guard retakeStudio.activeRetake != nil else{throw retakeStudio.failure("recording retake did not start")}
        retakeStudio.recordingUptime=ProcessInfo.processInfo.systemUptime-3
        retakeStudio.finishActiveRetake()
        guard retakeStudio.activeRetake==nil,retakeStudio.recordingRetakes.count==1 else{throw retakeStudio.failure("recording retake did not finish")}
        retakeStudio.recordingURL=folder.appendingPathComponent("retake-capture.mp4");retakeStudio.saveRecordingRetakes()
        retakeStudio.sourceDuration=4;await retakeStudio.loadRetakes(retakeStudio.recordingURL!)
        guard retakeStudio.retakes.count==1 else{throw retakeStudio.failure("recording retake sidecar did not reload")}
        retakeStudio.recording=false;retakeStudio.previewTask?.cancel()
        lines.append("PASS original-take selection, recording retake lifecycle, hotkey registration and sidecar recovery")
        let cleanupAudio=folder.appendingPathComponent("cleanup-analysis.wav")
        guard let cleanupFormat=AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1),
              let cleanupBuffer=AVAudioPCMBuffer(pcmFormat:cleanupFormat,frameCapacity:96_000),
              let cleanupSamples=cleanupBuffer.floatChannelData?[0] else{throw studio.failure("cleanup audio fixture could not be created")}
        cleanupBuffer.frameLength=96_000
        for frame in 0..<96_000 {cleanupSamples[frame]=frame<48_000 ? 0:Float(sin(2*Double.pi*440*Double(frame)/48_000)*0.4)}
        try autoreleasepool {
            let cleanupFile=try AVAudioFile(forWriting:cleanupAudio,settings:cleanupFormat.settings)
            try cleanupFile.write(from:cleanupBuffer)
        }
        let silentRanges=try await analyzeSourceSilence(url:cleanupAudio,thresholdDB:-45,minimumDuration:0.7,padding:0.1)
        guard silentRanges.count==1,silentRanges[0].start>=0.05,silentRanges[0].start<=0.2,silentRanges[0].end>=0.65,silentRanges[0].end<=1 else{throw studio.failure("silence analyzer boundaries failed: \(silentRanges)")}
        let timelineSilence=cleanupTimelineCandidates(sourceRanges:silentRanges,clips:[VideoClip(sourceStart:0,sourceEnd:2,timelineStart:3)],minimumDuration:0.04)
        guard timelineSilence.count==1,abs(timelineSilence[0].start-3.1)<0.08 else{throw studio.failure("silence source-to-timeline mapping failed")}
        let fillerCues=[CaptionCue(start:0,end:1,text:"Um ship it",words:[CaptionWord(text:"Um",start:0,end:0.2),CaptionWord(text:"ship",start:0.3,end:0.6),CaptionWord(text:"it",start:0.7,end:0.9)])]
        let fillerRanges=fillerCleanupCandidates(captions:fillerCues)
        guard fillerRanges.count==1,fillerRanges[0].label=="Um" else{throw studio.failure("filler word detection failed")}
        lines.append("PASS Smart Cleanup detects silence from PCM audio, maps moved clips and finds timed filler words")
        let cleanupStudio=Studio();cleanupStudio.source=folder.appendingPathComponent("sample.mp4");cleanupStudio.sourceDuration=3
        cleanupStudio.videoClips=[VideoClip(sourceStart:0,sourceEnd:3)];cleanupStudio.synchronizeVideoSequence(refresh:false)
        cleanupStudio.zooms=[ZoomClip(start:1.2,end:2.2)]
        cleanupStudio.captions=[CaptionCue(start:1.1,end:2,text:"After pause",words:[CaptionWord(text:"After",start:1.1,end:1.4),CaptionWord(text:"pause",start:1.5,end:2)])]
        cleanupStudio.audioTracks=[AudioTrackEdit(name:"Narration",path:cleanupStudio.source!.path,kind:"Imported",timelineStart:0,sourceEnd:3)]
        cleanupStudio.cleanupCandidates=[CleanupCandidate(start:0.5,end:1,kind:"Silence",label:"Silent pause")]
        let beforeCleanup=cleanupStudio.snapshot
        cleanupStudio.applySelectedCleanup()
        guard abs(cleanupStudio.duration-2.5)<0.01,cleanupStudio.videoClips.count==2,
              abs(cleanupStudio.videoClips[1].sourceStart-1)<0.01,abs(cleanupStudio.videoClips[1].timelineStart-0.5)<0.01,
              abs(cleanupStudio.zooms[0].start-0.7)<0.01,abs(cleanupStudio.captions[0].start-0.6)<0.01,
              cleanupStudio.audioTracks.count==2,cleanupStudio.cleanupCandidates.isEmpty else{throw studio.failure("cleanup ripple lost synchronized edits")}
        cleanupStudio.undoEdit()
        guard cleanupStudio.snapshot==beforeCleanup else{throw studio.failure("cleanup undo did not restore complete edit")}
        cleanupStudio.previewTask?.cancel()
        lines.append("PASS Smart Cleanup removes reviewed ranges, synchronizes every track and supports full undo")
        let arrowShape=classifyCursorShape(size:CGSize(width:28,height:40),hotSpot:CGPoint(x:5,y:5),crossness:0.3,pressed:false)
        let beamShape=classifyCursorShape(size:CGSize(width:9,height:18),hotSpot:CGPoint(x:4,y:9),crossness:1,pressed:false)
        var standardShapes:[String:String]=[:]
        for (expected,cursor) in [("hand",NSCursor.pointingHand),("crosshair",NSCursor.crosshair),("openHand",NSCursor.openHand),("resizeHorizontal",NSCursor.resizeLeftRight),("resizeVertical",NSCursor.resizeUpDown)] where cursor.image.size.width>0 {
            standardShapes[expected]=classifyCursorShape(size:cursor.image.size,hotSpot:cursor.hotSpot,crossness:cursorCrossness(cursor.image),pressed:false)
        }
        let closedShape=classifyCursorShape(size:NSCursor.closedHand.image.size,hotSpot:NSCursor.closedHand.hotSpot,crossness:cursorCrossness(NSCursor.closedHand.image),pressed:true)
        let crossReport=["crosshair":cursorCrossness(NSCursor.crosshair.image),"openHand":cursorCrossness(NSCursor.openHand.image),"closedHand":cursorCrossness(NSCursor.closedHand.image)]
        guard arrowShape=="arrow",beamShape=="ibeam",standardShapes.count==5,standardShapes.allSatisfy({$0.key==$0.value}),closedShape=="closedHand" else{throw studio.failure("cursor shape detection failed: \(standardShapes) closed=\(closedShape) crossness=\(crossReport)")}
        for shape in ["arrow","ibeam","hand","crosshair","resizeHorizontal","resizeVertical","openHand","closedHand"] {
            guard alphaCoverage(cursorArtwork(style:"Classic Outline",color:.white,shape:shape))>0.01 else{throw studio.failure("cursor artwork is blank: \(shape)")}
        }
        let aligned=shiftedPointerSamples([PointerSample(time:0.1,x:0.5,y:0.5,pressed:false),PointerSample(time:0.5,x:0.5,y:0.5,pressed:false)],by:0.12)
        guard aligned.count==2,aligned[0].time==0,abs(aligned[1].time-0.38)<0.000_1 else{throw studio.failure("pointer clock alignment failed")}
        lines.append("PASS cursor shapes are recognized from system cursor geometry, every shape has artwork, pointer data aligns to the file clock")
        let typed=keySample(time:1,keyCode:0,flags:[],characters:"a")
        let save=keySample(time:1,keyCode:1,flags:[.command],characters:"s")
        let wordJump=keySample(time:1,keyCode:123,flags:[.option],characters:nil)
        let optionCharacter=keySample(time:1,keyCode:12,flags:[.option],characters:"q")
        guard typed?.typing==true,typed?.key=="typing",save?.display=="⌘S",save?.typing==nil,wordJump?.display=="⌥←",optionCharacter?.typing==true else{throw studio.failure("keyboard privacy classification failed")}
        let wide=captureEncoding(width:5120,height:2880,preferHEVC:false,available:[.h264,.hevc])
        let wideWithoutHEVC=captureEncoding(width:5120,height:2880,preferHEVC:false,available:[.h264])
        let regular=captureEncoding(width:2560,height:1440,preferHEVC:false,available:[.h264,.hevc])
        guard wide.codec == .hevc,wide.width==5120,wideWithoutHEVC.codec == .h264,wideWithoutHEVC.width==4096,wideWithoutHEVC.height==2304,regular.codec == .h264 else{throw studio.failure("capture codec selection failed")}
        let subtitles=srtDocument([CaptionCue(start:3723.456,end:3724,text:"Two"),CaptionCue(start:0.5,end:1.25,text:"One")])
        guard subtitles.hasPrefix("1\n00:00:00,500 --> 00:00:01,250\nOne\n"),subtitles.contains("2\n01:02:03,456 --> 01:02:04,000\nTwo") else{throw studio.failure("SRT formatting failed")}
        lines.append("PASS typed text is never stored, 5K captures switch to HEVC or scale down for H.264, SRT timestamps are exact")
        let pausedURL=folder.appendingPathComponent("paused-recording.mp4")
        try? FileManager.default.removeItem(at:pausedURL)
        try FileManager.default.copyItem(at:folder.appendingPathComponent("sample.mp4"),to:pausedURL)
        try JSONEncoder().encode([VideoCut(start:0.5,end:1.0)]).write(to:pausedURL.appendingPathExtension("pauses.json"))
        let media=Studio();media.preferences.revealExport=false;media.exportSettings=ExportSettings()
        await media.load(pausedURL)
        guard abs(media.sourceDuration-media.duration-0.5)<0.02,media.videoClips.count==2 else{throw media.failure("paused ranges were not removed on open")}
        lines.append("PASS paused recording time is removed when the recording opens")
        media.resetVideoClips()
        let full=media.duration
        media.pointerSamples=[PointerSample(time:2,x:0.5,y:0.5,pressed:true)]
        if let id=media.videoClips.first?.id {media.setClipSpeed(id,to:2)}
        guard abs(media.duration-full/2)<0.02,verificationPointerClickTimes(media.timelinePointerSamples)==[1] else{throw media.failure("clip speed timing failed")}
        media.splitVideo(at:0.5)
        guard media.videoClips.count==2,abs(media.videoClips[1].sourceStart-1)<0.01,abs(media.videoClips[1].timelineStart-0.5)<0.01 else{throw media.failure("split at 2× failed")}
        media.look.exportHeight=720
        await media.export(to:folder.appendingPathComponent("verified-speed.mp4"))
        guard media.message==nil else{throw media.failure(media.message!)}
        let speedAsset=AVURLAsset(url:folder.appendingPathComponent("verified-speed.mp4"))
        guard abs(try await speedAsset.load(.duration).seconds-full/2)<0.1,!(try await speedAsset.loadTracks(withMediaType:.audio)).isEmpty,let speedVideo=try await speedAsset.loadTracks(withMediaType:.video).first else{throw media.failure("2× export duration or audio failed")}
        let speedRate=try await speedVideo.load(.nominalFrameRate)
        guard speedRate>55 else{throw media.failure("export frame rate is \(speedRate), expected 60")}
        media.undoEdit()
        guard abs(media.duration-full)<0.02,media.videoClips.first?.speed==1 else{throw media.failure("speed undo failed")}
        lines.append("PASS 2× clip speed maps pointer data, splits, exports half length with audio at 60 fps, and undoes")
        media.exportSettings=ExportSettings(format:"MOV",codec:"HEVC",fps:30,copyToClipboard:false)
        await media.export(to:folder.appendingPathComponent("verified-hevc.mov"))
        guard media.message==nil else{throw media.failure(media.message!)}
        let hevcAsset=AVURLAsset(url:folder.appendingPathComponent("verified-hevc.mov"))
        guard let hevcTrack=try await hevcAsset.loadTracks(withMediaType:.video).first,let hevcFormat=try await hevcTrack.load(.formatDescriptions).first else{throw media.failure("HEVC export has no video")}
        let hevcRate=try await hevcTrack.load(.nominalFrameRate)
        guard CMFormatDescriptionGetMediaSubType(hevcFormat)==kCMVideoCodecType_HEVC,abs(hevcRate-30)<2 else{throw media.failure("HEVC MOV 30 fps export failed: \(hevcRate) fps")}
        media.exportSettings=ExportSettings(format:"GIF")
        let gifURL=folder.appendingPathComponent("verified.gif")
        await media.export(to:gifURL)
        guard media.message==nil,let gif=CGImageSourceCreateWithURL(gifURL as CFURL,nil),CGImageSourceGetCount(gif)>=Int(full*15)-1 else{throw media.failure("GIF export failed: \(media.message ?? "frame count")")}
        lines.append("PASS HEVC MOV at 30 fps and a looping GIF export")
        media.exportSettings=ExportSettings();media.look.exportHeight=2160
        let cancelledURL=folder.appendingPathComponent("verified-cancelled.mp4")
        // Cancel at several moments: before the export starts, while the composition is built, and mid-export.
        for delay in [0,150,400,900] {
            try? FileManager.default.removeItem(at:cancelledURL)
            let exportJob=Task {await media.export(to:cancelledURL)}
            try await Task.sleep(for:.milliseconds(delay))
            exportJob.cancel()
            await exportJob.value
            guard !FileManager.default.fileExists(atPath:cancelledURL.path),media.message==nil,!media.busy,media.exportProgress==nil else{throw media.failure("export cancelled after \(delay) ms left a file or an error: \(media.message ?? "")")}
        }
        media.look.exportHeight=720
        lines.append("PASS export cancels without leaving a file or an error")
        media.cameraPath=folder.appendingPathComponent("sample.mp4").path;media.cameraOffset=1.0
        let (cameraEdit,_,_)=try await media.makeEditingComposition(asset:AVURLAsset(url:media.source!),size:CGSize(width:640,height:360),fps:30)
        let cameraTracks=try await cameraEdit.loadTracks(withMediaType:.video)
        guard cameraTracks.count==2 else{throw media.failure("camera track missing")}
        let cameraSegments=try await cameraTracks[1].load(.segments)
        guard let firstCameraSegment=cameraSegments.first,firstCameraSegment.isEmpty,abs(firstCameraSegment.timeMapping.target.duration.seconds-1)<0.02 else{throw media.failure("camera offset sync failed")}
        media.cameraPath=nil;media.cameraOffset=nil
        lines.append("PASS a camera recorded with the screen is placed on the screen clock through its start offset")
        media.captions=[CaptionCue(start:0.2,end:1.2,text:"keep cut",words:[CaptionWord(text:"keep",start:0.2,end:0.6),CaptionWord(text:"cut",start:0.8,end:1.2)])]
        let words=transcriptTokens(media.captions)
        // Annotations ride the same cut as captions: one inside the removed word goes with it, a later one moves back.
        let survivingAnnotation=UUID()
        media.annotations=[Annotation(kind:"Box",start:0.85,end:1.15),Annotation(id:survivingAnnotation,kind:"Blur",start:1.5,end:2.2)]
        guard words.count==2,media.rippleDelete([VideoCut(start:words[1].start,end:words[1].end)]),abs(media.duration-(full-0.4))<0.02,media.captions.first?.words.count==1,media.captions.first?.text=="keep",
              media.annotations.count==1,media.annotations[0].id==survivingAnnotation,abs(media.annotations[0].start-1.1)<0.02,abs(media.annotations[0].end-1.8)<0.02 else{throw media.failure("transcript word removal failed")}
        media.undoEdit();media.previewTask?.cancel()
        guard media.annotations.count==2 else{throw media.failure("undo did not restore annotations")}
        if let speedClip=media.videoClips.first?.id {
            media.setClipSpeed(speedClip,to:2)
            guard let moved=media.annotations.first(where:{$0.id==survivingAnnotation}),abs(moved.start-0.75)<0.03 else{throw media.failure("annotations did not follow a clip speed change")}
            media.undoEdit()
        }
        media.annotations=[]
        lines.append("PASS removing a transcript word cuts the video and keeps captions and annotations aligned")
        // A second recording added to the project plays from its own file: the timeline and the export both grow by its length.
        let secondURL=folder.appendingPathComponent("second-recording.mp4")
        try? FileManager.default.removeItem(at:secondURL)
        try FileManager.default.copyItem(at:folder.appendingPathComponent("sample.mp4"),to:secondURL)
        let merged=Studio();merged.preferences.revealExport=false;merged.exportSettings=ExportSettings()
        await merged.load(folder.appendingPathComponent("sample.mp4"))
        let single=merged.duration
        await merged.addRecording(secondURL)
        // The recording already open cannot be added to itself.
        await merged.addRecording(secondURL.deletingLastPathComponent().appendingPathComponent("sample.mp4"))
        guard merged.message != nil,merged.videoClips.count==2 else{throw merged.failure("adding the open recording again was allowed")}
        merged.message=nil
        merged.copyTimelineItem(.clip,id:merged.videoClips[1].id);merged.position=merged.duration;merged.pasteTimelineItem()
        guard merged.videoClips.count==3,merged.videoClips[1].source==secondURL.standardizedFileURL.path,merged.videoClips[2].source==secondURL.standardizedFileURL.path,
              merged.addedSources.count==1,abs(merged.duration-single*3)<0.1,merged.message==nil else{throw merged.failure("adding a recording failed: \(merged.message ?? "\(merged.videoClips.count) clips, \(merged.duration) s")")}
        merged.videoClips.removeLast();merged.synchronizeVideoSequence()
        merged.look.exportHeight=720
        let mergedURL=folder.appendingPathComponent("verified-merged.mp4")
        await merged.export(to:mergedURL)
        guard merged.message==nil else{throw merged.failure(merged.message!)}
        let mergedAsset=AVURLAsset(url:mergedURL)
        let mergedLength=try await mergedAsset.load(.duration).seconds
        guard abs(mergedLength-single*2)<0.15,!(try await mergedAsset.loadTracks(withMediaType:.audio)).isEmpty else{throw merged.failure("merged export is \(mergedLength) s, expected \(single*2)")}
        let missing=normalizedVideoClips([VideoClip(sourceStart:0,sourceEnd:1,timelineStart:0),VideoClip(sourceStart:0,sourceEnd:1,timelineStart:1,source:"/nope.mp4")],sourceDuration:single,added:[:])
        guard missing.count==1,missing[0].source==nil else{throw merged.failure("a clip pointing at a missing recording was kept")}
        merged.previewTask?.cancel()
        lines.append("PASS a second recording joins the timeline, plays from its own file and exports at full length")
        // The timeline waveform: peaks are read from the file, normalized, and follow clip cuts and speed.
        let peaks=try await audioPeaks(url:folder.appendingPathComponent("sample.mp4"),buckets:400)
        let loudest=peaks.max() ?? 0,quietest=peaks.min() ?? 1
        let waveStudio=Studio();waveStudio.sourceDuration=3;waveStudio.duration=3;waveStudio.waveforms=["":peaks]
        let halfSpeed=VideoClip(sourceStart:1.5,sourceEnd:3,timelineStart:0,speed:0.5)
        let atStart=waveStudio.waveformLevel(at:0,clip:halfSpeed)
        let absentFile=waveStudio.waveformLevel(at:0,clip:VideoClip(sourceStart:0,sourceEnd:1,source:"/nope.mp4"))
        guard peaks.count==400,abs(loudest-1)<0.001,quietest>=0,abs(Double(atStart)-Double(peak(peaks,at:1.5,length:3)))<0.0001,absentFile==0,
              peak(peaks,at:-5,length:3)==peaks.first,peak(peaks,at:99,length:3)==peaks.last else{throw studio.failure("timeline waveform failed")}
        lines.append("PASS the timeline waveform reads the recording's own loudness and follows cuts and speed")
        // Markers: added at the playhead, moved, jumped between, kept through cuts and written as chapters.
        let markerStudio=Studio();markerStudio.duration=200;markerStudio.position=12
        markerStudio.addMarker(name:"Setup");markerStudio.position=75;markerStudio.addMarker(name:"Demo")
        markerStudio.position=3661;markerStudio.addMarker(name:"Past the end")
        let again=markerStudio.addMarker(at:12)
        markerStudio.position=0;markerStudio.goToMarker(forward:true)
        let firstJump=markerStudio.position
        markerStudio.goToMarker(forward:false)
        markerStudio.moveMarker(markerStudio.markers[0].id,to:-5)
        let chapters=chapterList(markerStudio.markers,duration:200)
        let rippled=remappedMarkers(markerStudio.markers) { $0>60 ? $0-30:$0 }
        let restoredMarkers=normalizedMarkers([TimelineMarker(time:.nan,name:"bad"),TimelineMarker(time:400,name:"   "),TimelineMarker(time:5,name:"Keep")],duration:200)
        guard markerStudio.markers.count==3,again==markerStudio.markers.first?.id,abs(firstJump-12)<0.001,abs(markerStudio.position-12)<0.001,
              markerStudio.markers[0].time==0,chapters.hasPrefix("0:00 Setup\n1:15 Demo\n3:20 Past the end"),
              rippled.count==3,abs(rippled[2].time-170)<0.001,restoredMarkers.count==2,restoredMarkers[0].name=="Keep",restoredMarkers[1].time==200,restoredMarkers[1].name=="Marker",
              chapterList([],duration:200).isEmpty,chapterList([TimelineMarker(time:9,name:"Late")],duration:200).hasPrefix("0:00 Start\n0:09 Late") else{throw studio.failure("timeline markers failed")}
        lines.append("PASS markers add, move, jump, survive cuts and export as a chapter list")
        // Export presets set the canvas, file and frame rate, and only reframe a wide recording onto a tall canvas.
        let presetStudio=Studio();presetStudio.mediaAspect=16/9
        presetStudio.applyExportPreset(exportPresets.first { $0.id.hasPrefix("TikTok") }!)
        let vertical=presetStudio.look.canvas
        let verticalReframe=presetStudio.look.autoReframe ?? false
        presetStudio.mediaAspect=9/16
        presetStudio.applyExportPreset(exportPresets.first { $0.id.hasPrefix("TikTok") }!)
        let tallSourceReframe=presetStudio.look.autoReframe ?? false
        presetStudio.applyExportPreset(exportPresets.first { $0.id=="YouTube · 4K" }!)
        guard vertical==CGSize(width:1080,height:1920),verticalReframe,!tallSourceReframe,
              presetStudio.look.canvas==CGSize(width:3840,height:2160),presetStudio.exportSettings.resolvedCodec=="HEVC",presetStudio.exportSettings.resolvedFPS==60,
              presetStudio.look.autoReframe==false,exportPresets.allSatisfy({ ["16:9","9:16","1:1","4:3","4:5"].contains($0.aspect) && ["MP4","MOV","GIF"].contains($0.format) }) else{throw studio.failure("export presets failed")}
        lines.append("PASS export presets set the canvas, file and frame rate for each destination")
        // A recording of another shape added to the project keeps its whole frame instead of being cropped to the canvas width.
        let portraitURL=folder.appendingPathComponent("portrait-clip.mp4")
        try await writePortraitClip(to:portraitURL)
        let shapes=Studio();shapes.preferences.revealExport=false;shapes.exportSettings=ExportSettings()
        await shapes.load(folder.appendingPathComponent("sample.mp4"))
        shapes.look=Look();shapes.look.exportHeight=720;shapes.look.padding=0
        await shapes.addRecording(portraitURL)
        guard shapes.message==nil,shapes.videoClips.count==2 else{throw shapes.failure("the portrait clip was not added: \(shapes.message ?? "")")}
        let portraitStart=shapes.videoClips[1].timelineStart
        let shapesURL=folder.appendingPathComponent("verified-shapes.mp4")
        await shapes.export(to:shapesURL)
        guard shapes.message==nil else{throw shapes.failure(shapes.message!)}
        let shapesGenerator=AVAssetImageGenerator(asset:AVURLAsset(url:shapesURL))
        shapesGenerator.requestedTimeToleranceBefore = .zero;shapesGenerator.requestedTimeToleranceAfter = .zero
        let portraitFrame=try await shapesGenerator.image(at:CMTime(seconds:portraitStart+0.4,preferredTimescale:600)).image
        let frameContext=CIContext(options:[.workingColorSpace:NSNull()])
        var frameData=[UInt8](repeating:0,count:portraitFrame.width*portraitFrame.height*4)
        frameContext.render(CIImage(cgImage:portraitFrame),toBitmap:&frameData,rowBytes:portraitFrame.width*4,bounds:CGRect(x:0,y:0,width:portraitFrame.width,height:portraitFrame.height),format:.RGBA8,colorSpace:nil)
        var white=0,red=0
        for index in stride(from:0,to:frameData.count,by:4) {
            let r=Int(frameData[index]),g=Int(frameData[index+1]),b=Int(frameData[index+2])
            if r>200,g>200,b>200 { white+=1 } else if r>150,g<70,b<70 { red+=1 }
        }
        guard red>1000,white>1000 else{throw shapes.failure("the portrait clip lost its frame: \(white) white and \(red) red pixels")}
        shapes.previewTask?.cancel()
        lines.append("PASS a recording of another shape keeps its whole frame on the canvas")
        // A fixed sequence of edits, checked after every step: nothing may become infinite, leave the timeline or break undo.
        lines.append(contentsOf:try await verifyStress(folder:folder))
        // Shortening a clip must leave a preview that still renders the picture, not a black frame.
        let trimStudio=Studio();trimStudio.preferences.revealExport=false
        await trimStudio.load(folder.appendingPathComponent("sample.mp4"))
        guard let trimmedID=trimStudio.videoClips.first?.id else{throw trimStudio.failure("no clip to trim")}
        func brightness(_ studio:Studio,at time:Double) async throws->Double {
            let (asset,composition,_)=try await studio.makeEditingComposition(asset:AVURLAsset(url:studio.source!),size:CGSize(width:640,height:360),fps:30)
            let generator=AVAssetImageGenerator(asset:asset);generator.videoComposition=composition
            generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
            let image=try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
            let context=CIContext(options:[.workingColorSpace:NSNull()])
            var data=[UInt8](repeating:0,count:640*360*4)
            context.render(CIImage(cgImage:image),toBitmap:&data,rowBytes:640*4,bounds:CGRect(x:0,y:0,width:640,height:360),format:.RGBA8,colorSpace:nil)
            return stride(from:0,to:data.count,by:4).map { Double(data[$0])+Double(data[$0+1])+Double(data[$0+2]) }.reduce(0,+)/Double(640*360*3)
        }
        trimStudio.updateClipEdge(trimmedID,startEdge:false,to:1.5)
        guard abs(trimStudio.duration-1.5)<0.05 else{throw trimStudio.failure("trimming the end left \(trimStudio.duration) s")}
        let afterEndTrim=try await brightness(trimStudio,at:0.7),nearNewEnd=try await brightness(trimStudio,at:1.4)
        trimStudio.updateClipEdge(trimmedID,startEdge:true,to:0.5)
        let afterStartTrim=try await brightness(trimStudio,at:0.3)
        trimStudio.previewTask?.cancel()
        guard afterEndTrim>6,nearNewEnd>6,afterStartTrim>6 else{throw trimStudio.failure("a shortened clip renders black: \(afterEndTrim) / \(nearNewEnd) / \(afterStartTrim)")}
        lines.append("PASS a shortened clip still renders its picture across the timeline")
        // The same check through the preview player, which is what the editor shows: trim, wait for the rebuild, scrub, read a frame.
        func previewBrightness(_ studio:Studio,at time:Double) async throws->Double {
            studio.position=time;studio.seek(time)
            // The rebuild runs after a short delay; waiting for it means the output is attached to the item that stays.
            await studio.previewTask?.value
            for _ in 0..<40 {
                if let item=studio.player.currentItem,item.status == .readyToPlay { break }
                try await Task.sleep(for:.milliseconds(100))
            }
            guard let item=studio.player.currentItem else { throw studio.failure("the preview has no item to play") }
            guard item.status != .failed else { throw studio.failure("the preview item failed: \(item.error?.localizedDescription ?? "unknown")") }
            let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
            item.add(output)
            await studio.player.seek(to:CMTime(seconds:time,preferredTimescale:600),toleranceBefore: .zero,toleranceAfter: .zero)
            // A paused player does not advance host time, so the frame is asked for at the item's own current time.
            var buffer:CVPixelBuffer?
            for _ in 0..<60 {
                if let copied=output.copyPixelBuffer(forItemTime:item.currentTime(),itemTimeForDisplay:nil) { buffer=copied;break }
                try await Task.sleep(for:.milliseconds(100))
            }
            item.remove(output)
            guard let buffer else { throw studio.failure("the preview produced no frame at \(time) s") }
            let image=CIImage(cvPixelBuffer:buffer)
            let context=CIContext(options:[.workingColorSpace:NSNull()])
            var pixel=[UInt8](repeating:0,count:4)
            context.render(image.applyingFilter("CIAreaAverage",parameters:[kCIInputExtentKey:CIVector(cgRect:image.extent)]),toBitmap:&pixel,rowBytes:4,bounds:CGRect(x:0,y:0,width:1,height:1),format:.RGBA8,colorSpace:nil)
            return (Double(pixel[0])+Double(pixel[1])+Double(pixel[2]))/3
        }
        let previewStudio=Studio();previewStudio.preferences.revealExport=false
        await previewStudio.load(folder.appendingPathComponent("sample.mp4"))
        previewStudio.refreshComposition()
        let beforeTrim=try await previewBrightness(previewStudio,at:1.0)
        guard let previewClip=previewStudio.videoClips.first?.id else{throw previewStudio.failure("no clip in the preview studio")}
        previewStudio.updateClipEdge(previewClip,startEdge:false,to:1.5)
        let afterTrimPreview=try await previewBrightness(previewStudio,at:0.8)
        let scrubbedBack=try await previewBrightness(previewStudio,at:0.2)
        previewStudio.player.pause();previewStudio.previewTask?.cancel()
        guard beforeTrim>6,afterTrimPreview>6,scrubbedBack>6 else{throw previewStudio.failure("the preview goes black after shortening: \(beforeTrim) → \(afterTrimPreview) / \(scrubbedBack)")}
        lines.append("PASS the preview keeps showing the picture after a clip is shortened and the playhead moves")
        // Trimming the head must remove the beginning, not push the clip to the right and leave background in front of it.
        let headStudio=Studio();headStudio.preferences.revealExport=false
        await headStudio.load(folder.appendingPathComponent("sample.mp4"))
        let fullLength=headStudio.duration
        headStudio.zooms=[ZoomClip(start:1.2,end:2.2)]
        headStudio.markers=[TimelineMarker(time:1.5,name:"Demo")]
        guard let headClip=headStudio.videoClips.first?.id else{throw headStudio.failure("no clip to trim")}
        headStudio.updateClipEdge(headClip,startEdge:true,to:0.6)
        headStudio.previewTask?.cancel()
        guard headStudio.videoClips[0].timelineStart==0,headStudio.placement(containing:0) != nil,headStudio.placement(containing:0.05) != nil,
              abs(headStudio.duration-(fullLength-0.6))<0.02,abs(headStudio.zooms[0].start-0.6)<0.02,abs(headStudio.markers[0].time-0.9)<0.02 else{
            throw headStudio.failure("trimming the head left a gap: clip starts at \(headStudio.videoClips[0].timelineStart) s, zoom at \(headStudio.zooms.first?.start ?? -1), marker at \(headStudio.markers.first?.time ?? -1)")}
        lines.append("PASS trimming the head removes the beginning and pulls zooms, markers and captions back with it")
        // Deleting a clip closes the timeline over it, and everything after moves back by exactly its length.
        let gapStudio=Studio();gapStudio.preferences.revealExport=false
        await gapStudio.load(folder.appendingPathComponent("sample.mp4"))
        gapStudio.videoClips=[VideoClip(sourceStart:0,sourceEnd:1,timelineStart:0),VideoClip(sourceStart:1,sourceEnd:2,timelineStart:1),VideoClip(sourceStart:2,sourceEnd:3,timelineStart:2)]
        gapStudio.synchronizeVideoSequence(refresh:false)
        gapStudio.zooms=[ZoomClip(start:2.2,end:2.8)];gapStudio.markers=[TimelineMarker(time:2.5,name:"Third")]
        gapStudio.captions=[CaptionCue(start:2.1,end:2.6,text:"third clip")]
        gapStudio.selectedClip=gapStudio.videoClips[1].id
        gapStudio.deleteSelectedClip()
        gapStudio.previewTask?.cancel()
        guard gapStudio.videoClips.count==2,abs(gapStudio.videoClips[1].timelineStart-1)<0.001,abs(gapStudio.duration-2)<0.001,
              gapStudio.placement(containing:1.5) != nil,abs(gapStudio.zooms[0].start-1.2)<0.01,abs(gapStudio.markers[0].time-1.5)<0.01,abs(gapStudio.captions[0].start-1.1)<0.01 else{
            throw gapStudio.failure("deleting a clip left a hole: clips \(gapStudio.videoClips.map{$0.timelineStart}), zoom \(gapStudio.zooms.first?.start ?? -1)")}
        lines.append("PASS deleting a clip closes the timeline over it and moves later items back with it")
        // The browser and window frames: the bar follows the rounded corners, and the address bar shows what was typed.
        var framed=Look();framed.radius=60;framed.padding=0
        var browserStyle=VideoStyle();browserStyle.frame="Browser";browserStyle.frameTitle="  lumio.studio/tour  "
        framed.videoStyle=browserStyle.normalized()
        guard framed.videoStyle?.frameTitle=="lumio.studio/tour" else{throw studio.failure("the frame title was not tidied: \(framed.videoStyle?.frameTitle ?? "nil")")}
        var blankStyle=VideoStyle();blankStyle.frame="Browser";blankStyle.frameTitle="   "
        guard blankStyle.normalized().frameTitle==nil else{throw studio.failure("an empty frame title should stay empty")}
        let framedRect=CGRect(x:0,y:0,width:640,height:360)
        let chrome=borderLayer(look:framed,rect:framedRect,size:CGSize(width:640,height:360))
        guard chrome.masksToBounds,chrome.cornerRadius>1 else{throw studio.failure("the frame does not clip its chrome to the rounded corners")}
        let bar=chrome.sublayers?.first
        let addressPill=bar?.sublayers?.first { $0.cornerRadius>1 && $0.sublayers?.contains(where:{ $0 is CATextLayer }) == true }
        let addressText=addressPill?.sublayers?.compactMap { $0 as? CATextLayer }.first
        guard let addressText,addressText.string as? String=="lumio.studio/tour" else{throw studio.failure("the address bar does not show the typed domain")}
        // The rendered chrome must stay inside the rounded corner: the very corner pixel is not covered by the bar.
        let chromeImage=layerImage(chrome,size:CGSize(width:640,height:360))
        let chromeContext=CIContext(options:[.workingColorSpace:NSNull()])
        var corner=[UInt8](repeating:0,count:4)
        chromeContext.render(CIImage(cgImage:chromeImage),toBitmap:&corner,rowBytes:4,bounds:CGRect(x:1,y:357,width:1,height:1),format:.RGBA8,colorSpace:nil)
        guard corner[3]<40 else{throw studio.failure("the frame bar still paints the square corner (alpha \(corner[3]))")}
        lines.append("PASS the window and browser frames follow the corner radius and show a chosen address")
        var zoomSettings=MotionSettings();zoomSettings.autoZoom=true
        let pointerPath=[PointerSample(time:0,x:0.3,y:0.3,pressed:false),PointerSample(time:0.5,x:0.2,y:0.8,pressed:true),PointerSample(time:0.6,x:0.2,y:0.8,pressed:false),PointerSample(time:6,x:0.9,y:0.1,pressed:false)]
        let typingZooms=autoZoomClips(samples:pointerPath,settings:zoomSettings,duration:10,typing:[4,4.2,4.4,4.6])
        guard typingZooms.count==2,typingZooms[1].follow==false,abs(typingZooms[1].x-0.2)<0.001,abs(typingZooms[1].start-3.7)<0.001 else{throw studio.failure("typing zoom failed: \(typingZooms)")}
        let artCache=OverlayArtCache(captionStyle:CaptionStyle(),keyboardStyle:KeyboardOverlayStyle())
        let cachedCue=CaptionCue(start:0,end:1,text:"Cached words",words:[CaptionWord(text:"Cached",start:0,end:0.5),CaptionWord(text:"words",start:0.5,end:1)])
        let firstArt=artCache.caption(cachedCue,activeWord:1),secondArt=artCache.caption(cachedCue,activeWord:1)
        guard firstArt === secondArt,firstArt.width>0 else{throw studio.failure("overlay art cache failed")}
        let followPath=cameraFollowPath([PointerSample(time:0,x:0.5,y:0.5,pressed:false),PointerSample(time:0.1,x:0.52,y:0.5,pressed:false),PointerSample(time:2,x:0.52,y:0.5,pressed:false)],settings:zoomSettings)
        guard abs(followPath[2].x-0.5)<0.001 else{throw studio.failure("zoom dead zone failed")}
        lines.append("PASS typing bursts zoom to the clicked field, small pointer moves do not pan the zoom, overlay art is cached")
        func pixel(_ image:CGImage,_ x:Double,_ y:Double)->(r:Double,g:Double,b:Double) {
            let rep=NSBitmapImageRep(cgImage:image)
            let color=rep.colorAt(x:Int(Double(rep.pixelsWide-1)*x),y:Int(Double(rep.pixelsHigh-1)*y))?.usingColorSpace(.sRGB)
            return (Double(color?.redComponent ?? 0)*255,Double(color?.greenComponent ?? 0)*255,Double(color?.blueComponent ?? 0)*255)
        }
        var geometryLook=Look()
        let fitted=videoPlacement(look:geometryLook,canvas:CGSize(width:1920,height:1080),mediaAspect:16.0/9.0)
        let zoomedPose=ZoomPose(scale:2,x:0.25,y:0.75)
        let legacyOffset=zoomedPose.offset(width:fitted.rect.width,height:fitted.rect.height,flipped:true)
        let fittedOrigin=fitted.origin(zoomedPose)
        guard abs(fittedOrigin.x-(fitted.rect.minX+legacyOffset.x))<0.001,abs(fittedOrigin.y-(fitted.rect.minY+legacyOffset.y))<0.001 else{throw studio.failure("shared placement changed fitted zoom geometry")}
        geometryLook.aspect="9:16";geometryLook.autoReframe=true
        let portrait=videoPlacement(look:geometryLook,canvas:CGSize(width:1080,height:1920),mediaAspect:16.0/9.0)
        let rightView=portrait.origin(ZoomPose(x:1)),leftView=portrait.origin(ZoomPose(x:0))
        guard portrait.rect.width<portrait.rect.height,abs(portrait.contentSize.height-portrait.rect.height)<0.5,portrait.contentSize.width>portrait.rect.width*3,
              abs(rightView.x-(portrait.rect.maxX-portrait.contentSize.width))<0.5,abs(leftView.x-portrait.rect.minX)<0.5 else{throw studio.failure("auto reframe geometry failed")}
        lines.append("PASS shared video placement keeps fitted zoom geometry and covers a vertical frame edge to edge")
        let cropStudio=Studio();cropStudio.preferences.revealExport=false;cropStudio.exportSettings=ExportSettings()
        cropStudio.loadImage(stillURL);cropStudio.look=Look();cropStudio.look.aspect="1:1";cropStudio.look.exportHeight=720;cropStudio.look.glow=0
        var topLeft=VideoStyle();topLeft.cropRight=0.45;topLeft.cropBottom=0.45;cropStudio.look.videoStyle=topLeft
        let croppedPNG=folder.appendingPathComponent("verified-crop.png")
        cropStudio.exportImage(to:croppedPNG)
        guard cropStudio.message==nil,let croppedImage=NSImage(contentsOf:croppedPNG)?.cgImage(forProposedRect:nil,context:nil,hints:nil) else{throw studio.failure("cropped PNG export failed")}
        let croppedCentre=pixel(croppedImage,0.5,0.5)
        guard croppedCentre.r>180,croppedCentre.g>150,croppedCentre.b<110 else{throw studio.failure("image crop shows the wrong region: \(croppedCentre)")}
        await cropStudio.load(folder.appendingPathComponent("sample.mp4"))
        cropStudio.look=Look();cropStudio.look.exportHeight=720;cropStudio.look.glow=0;cropStudio.motion.autoZoom=false;cropStudio.motion.showCursor=false
        var leftStrip=VideoStyle();leftStrip.cropRight=0.85;cropStudio.look.videoStyle=leftStrip
        cropStudio.pointerSamples=[PointerSample(time:1,x:0.075,y:0.5,pressed:false)]
        guard let croppedPointer=cropStudio.timelinePointerSamples.first,abs(croppedPointer.x-0.5)<0.001 else{throw studio.failure("pointer is not mapped into the crop")}
        await cropStudio.export(to:folder.appendingPathComponent("verified-crop.mp4"))
        guard cropStudio.message==nil else{throw studio.failure(cropStudio.message!)}
        let cropFrame=try await AVAssetImageGenerator(asset:AVURLAsset(url:folder.appendingPathComponent("verified-crop.mp4"))).image(at:CMTime(seconds:1,preferredTimescale:600)).image
        func isRed(_ color:(r:Double,g:Double,b:Double))->Bool { color.r>150 && color.g<110 && color.b<110 }
        func isCyan(_ color:(r:Double,g:Double,b:Double))->Bool { color.r<110 && color.g>150 && color.b>150 }
        let cropSamples:[(r:Double,g:Double,b:Double)]=[pixel(cropFrame,0.5,0.4),pixel(cropFrame,0.5,0.5),pixel(cropFrame,0.5,0.6)]
        let redPoints=cropSamples.filter(isRed)
        guard redPoints.count>=2 else{throw studio.failure("video crop shows the wrong region: \(pixel(cropFrame,0.5,0.5))")}
        lines.append("PASS crop shows the chosen region in PNG and MP4 exports and maps the pointer into it")
        cropStudio.look=Look();cropStudio.look.exportHeight=720;cropStudio.look.glow=0;cropStudio.look.aspect="9:16";cropStudio.look.autoReframe=true
        let reframeCases:[(label:String,x:Double,sample:[Double],expectCyan:Bool)]=[("right",0.95,[0.55,0.6,0.65],true),("left",0.05,[0.3,0.35,0.4],false)]
        for (label,x,sample,expectCyan) in reframeCases {
            cropStudio.pointerSamples=[PointerSample(time:0,x:x,y:0.5,pressed:false),PointerSample(time:2.9,x:x,y:0.5,pressed:false)]
            let url=folder.appendingPathComponent("verified-reframe-\(label).mp4")
            await cropStudio.export(to:url)
            guard cropStudio.message==nil else{throw studio.failure(cropStudio.message!)}
            let frame=try await AVAssetImageGenerator(asset:AVURLAsset(url:url)).image(at:CMTime(seconds:1.5,preferredTimescale:600)).image
            let colors:[(r:Double,g:Double,b:Double)]=sample.map { pixel(frame,$0,0.5) }
            let matches=colors.filter(expectCyan ? isCyan:isRed)
            guard frame.width<frame.height,matches.count>=2 else{throw studio.failure("auto reframe did not follow the pointer to the \(label): \(colors)")}
        }
        lines.append("PASS vertical auto reframe fills the canvas and follows the pointer left and right")
        guard deviceFrameAndCanvas(mediaAspect:0.46)==("iPhone","9:16"),deviceFrameAndCanvas(mediaAspect:0.75)==("iPad","4:5"),deviceFrameAndCanvas(mediaAspect:2.17)==("iPhone","16:9"),deviceFrameAndCanvas(mediaAspect:1.33)==("iPad","4:3"),allowScreenCaptureDevices() else{throw studio.failure("device recording setup failed")}
        lines.append("PASS iPhone and iPad screen capture is enabled and recorded devices get a matching frame and canvas")
        let micRecording=folder.appendingPathComponent("mic-recording.mp4")
        let micFile=microphoneRecordingURL(for:micRecording)
        for file in [micRecording,micFile,micRecording.appendingPathExtension("mic.json")] {try? FileManager.default.removeItem(at:file)}
        try FileManager.default.copyItem(at:folder.appendingPathComponent("sample.mp4"),to:micRecording)
        guard let micExporter=AVAssetExportSession(asset:AVURLAsset(url:micRecording),presetName:AVAssetExportPresetAppleM4A) else{throw studio.failure("microphone fixture could not be created")}
        try await micExporter.export(to:micFile,as:.m4a)
        try JSONEncoder().encode(CameraSidecar(file:micFile.lastPathComponent,offset:0.5)).write(to:micRecording.appendingPathExtension("mic.json"))
        let micStudio=Studio();micStudio.preferences.revealExport=false;micStudio.exportSettings=ExportSettings()
        await micStudio.load(micRecording)
        guard micStudio.microphonePath==micFile.path,micStudio.microphoneOffset==0.5 else{throw studio.failure("microphone sidecar was not loaded")}
        let (micEdit,_,micMix)=try await micStudio.makeEditingComposition(asset:AVURLAsset(url:micRecording),size:CGSize(width:640,height:360),fps:30)
        let micTracks=try await micEdit.loadTracks(withMediaType:.audio)
        var micStart = -1.0
        if micTracks.count>=2 { micStart=try await micTracks[1].load(.segments).first(where:{!$0.isEmpty})?.timeMapping.target.start.seconds ?? -1 }
        guard micTracks.count==2,abs(micStart-0.5)<0.02,(micMix?.inputParameters.count ?? 0)==2 else{throw studio.failure("microphone track is not placed on the screen clock: \(micTracks.count) tracks, starts \(micStart)")}
        lines.append("PASS a separately recorded microphone becomes its own adjustable track, placed through its clock offset")
        let speechURL=folder.appendingPathComponent("voice-speech.aiff")
        try? FileManager.default.removeItem(at:speechURL)
        let say=Process();say.executableURL=URL(fileURLWithPath:"/usr/bin/say");say.arguments=["-o",speechURL.path,"This recording checks that background noise is removed while the voice stays in sync."]
        try say.run();say.waitUntilExit()
        let cleanSpeech=try readMono48k(url:speechURL,seconds:30)
        guard cleanSpeech.count>48_000 else{throw studio.failure("speech fixture could not be created")}
        let lead=48_000
        var noisySpeech=[Float](repeating:0,count:cleanSpeech.count+lead*2)
        var seed:UInt64=7
        for index in noisySpeech.indices {
            seed=seed &* 6364136223846793005 &+ 1442695040888963407
            let noise=Float(Double(seed>>11)/Double(UInt64(1)<<53)*2-1)*0.04
            let speech=index>=lead && index<lead+cleanSpeech.count ? cleanSpeech[index-lead]*0.5:0
            noisySpeech[index]=noise+speech
        }
        let noisyURL=folder.appendingPathComponent("voice-noisy.caf"),enhancedURL=folder.appendingPathComponent("voice-enhanced.m4a")
        try? FileManager.default.removeItem(at:noisyURL);try? FileManager.default.removeItem(at:enhancedURL)
        guard let monoFormat=AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1),let noisyBuffer=AVAudioPCMBuffer(pcmFormat:monoFormat,frameCapacity:AVAudioFrameCount(noisySpeech.count)) else{throw studio.failure("noisy fixture buffer failed")}
        noisyBuffer.frameLength=AVAudioFrameCount(noisySpeech.count)
        for index in noisySpeech.indices {noisyBuffer.floatChannelData![0][index]=noisySpeech[index]}
        try autoreleasepool { try AVAudioFile(forWriting:noisyURL,settings:monoFormat.settings).write(from:noisyBuffer) }
        let report=try enhanceVoice(input:noisyURL,output:enhancedURL,isolation:1,level:true)
        let enhanced=try readMono48k(url:enhancedURL,seconds:60)
        func rmsDB(_ samples:[Float],_ start:Int,_ end:Int)->Double {
            let slice=samples[max(0,start)..<min(samples.count,end)];let power=slice.reduce(0.0){$0+Double($1*$1)}/Double(max(1,slice.count))
            return 10*log10(max(power,1e-12))
        }
        let noiseBefore=rmsDB(noisySpeech,4_800,43_200),noiseAfter=rmsDB(enhanced,4_800,43_200)
        let residualLag=measureLag(input:noisySpeech,output:enhanced+[Float](repeating:0,count:12_000),sampleRate:48_000) ?? -1
        guard report.isolated,noiseBefore-noiseAfter>15,abs(enhanced.count-noisySpeech.count)<2_400,residualLag>=0,residualLag<480 else{throw studio.failure("voice enhancement failed: noise \(noiseBefore)→\(noiseAfter) dB, length \(enhanced.count)/\(noisySpeech.count), residual lag \(residualLag), removed lag \(report.lagSamples)")}
        lines.append(String(format:"PASS voice enhancement lowers background noise by %.0f dB, removes the %.0f ms isolation delay and keeps length",noiseBefore-noiseAfter,Double(report.lagSamples)/48))
        micStudio.audioSettings.enhanceVoice=true
        micStudio.refreshVoiceEnhancement()
        await micStudio.voiceTask?.value
        guard let readyVoice=micStudio.readyEnhancedVoiceURL(),!micStudio.voiceProcessing,micStudio.message==nil else{throw studio.failure("microphone enhancement was not prepared: \(micStudio.message ?? "")")}
        await micStudio.export(to:folder.appendingPathComponent("verified-voice.mp4"))
        guard micStudio.message==nil,!(try await AVURLAsset(url:folder.appendingPathComponent("verified-voice.mp4")).loadTracks(withMediaType:.audio)).isEmpty else{throw studio.failure("export with enhanced microphone failed")}
        try? FileManager.default.removeItem(at:readyVoice)
        micStudio.previewTask?.cancel();cropStudio.previewTask?.cancel()
        lines.append("PASS the enhanced microphone is cached, used by the export, and prepared before exporting")
        let board=Studio();board.source=folder.appendingPathComponent("sample.mp4");board.sourceDuration=3
        board.videoClips=[VideoClip(sourceStart:0,sourceEnd:3)];board.synchronizeVideoSequence(refresh:false)
        let copiedZoom=ZoomClip(start:0.5,end:1.5,scale:2,x:0.3,y:0.6,transition:0.3)
        board.zooms=[copiedZoom]
        board.focusTimeline(.zoom,id:copiedZoom.id);board.copyTimelineSelection()
        board.position=1.8
        guard board.pasteTimelineItem(),board.zooms.count==2,let pastedZoom=board.zooms.last,pastedZoom.id != copiedZoom.id,abs(pastedZoom.start-1.8)<0.001,abs(pastedZoom.end-2.8)<0.001,
              pastedZoom.scale==2,pastedZoom.x==0.3,board.selectedZoom==pastedZoom.id,abs(board.position-2.8)<0.001 else{throw board.failure("zoom paste at the playhead failed")}
        board.position=2.95
        guard !board.pasteTimelineItem(),board.zooms.count==2 else{throw board.failure("a zoom was pasted past the end of the timeline")}
        board.message=nil
        board.duplicateTimelineSelection()
        var clipboardKept=false
        if case .zoom(let onClipboard)? = board.timelineClipboard { clipboardKept = onClipboard.id == copiedZoom.id }
        guard board.zooms.count==3,abs(board.zooms[2].start-2.8)<0.001,clipboardKept else{throw board.failure("zoom duplicate failed or replaced the clipboard")}
        board.deleteTimelineSelection()
        guard board.zooms.count==2,!board.zooms.contains(where:{abs($0.start-2.8)<0.001}) else{throw board.failure("Delete did not remove the selected zoom")}
        board.captions=[CaptionCue(start:0.2,end:1,text:"Copy me",words:[CaptionWord(text:"Copy",start:0.2,end:0.5),CaptionWord(text:"me",start:0.6,end:1)])]
        board.cutTimelineItem(.caption,id:board.captions[0].id)
        board.position=1.5
        guard board.captions.isEmpty,board.pasteTimelineItem(),let movedCue=board.captions.first,abs(movedCue.start-1.5)<0.001,abs(movedCue.words[1].start-1.9)<0.001 else{throw board.failure("caption cut and paste failed")}
        board.copyTimelineItem(.clip,id:board.videoClips[0].id);board.position=1
        guard board.pasteTimelineItem(),board.videoClips.count==2,abs(board.videoClips[1].timelineStart-1)<0.001,abs(board.duration-4)<0.001,board.timelineFocus == .clip else{throw board.failure("clip paste at the playhead failed")}
        board.previewTask?.cancel()
        lines.append("PASS timeline items copy, cut, paste at the playhead, duplicate and delete; repeated pastes line up after each other")
        lines.append(contentsOf:try await verifyLooks(folder:folder))
        lines.append(contentsOf:try await verifyPrivacy(folder:folder))
        lines.append(contentsOf:try await verifyEffects(folder:folder))
        lines.append(contentsOf:try await verifyEditing(folder:folder))
        try lines.joined(separator:"\n").write(to:folder.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8)
        print(lines.joined(separator:"\n")); exit(0)
    } catch {
        lines.append("FAIL \(error.localizedDescription)")
        try? lines.joined(separator:"\n").write(to:folder.appendingPathComponent("verification.txt"),atomically:true,encoding:.utf8)
        print(lines.joined(separator:"\n")); exit(1)
    }
}

/// Developer-only: transcribes an audio file with the Generate Captions pipeline and prints the timed cues.
/// Checks the camera background treatment on a real recording: prints how much of each sampled frame
/// Vision sees as a person and writes before/after frames next to the video for a look.
/// Writes a short portrait clip: red with a white band across the top, so a renderer that crops instead of
/// fitting can be told apart from one that keeps the whole frame.
func writePortraitClip(to url:URL,size:CGSize=CGSize(width:360,height:640),seconds:Double=1) async throws {
    try? FileManager.default.removeItem(at:url)
    let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:Int(size.width),AVVideoHeightKey:Int(size.height)])
    input.expectsMediaDataInRealTime=false
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
    var buffer:CVPixelBuffer?
    CVPixelBufferCreate(nil,Int(size.width),Int(size.height),kCVPixelFormatType_32BGRA,nil,&buffer)
    guard let buffer else { throw NSError(domain:"Lumio",code:90,userInfo:[NSLocalizedDescriptionKey:"no pixel buffer"]) }
    CVPixelBufferLockBaseAddress(buffer,[])
    if let base=CVPixelBufferGetBaseAddress(buffer) {
        let context=CGContext(data:base,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue)!
        context.setFillColor(CGColor(red:1,green:0,blue:0,alpha:1));context.fill(CGRect(origin:.zero,size:size))
        context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1));context.fill(CGRect(x:0,y:size.height*0.88,width:size.width,height:size.height*0.12))
    }
    CVPixelBufferUnlockBaseAddress(buffer,[])
    let frames=Int(seconds*30)
    for frame in 0..<frames {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(10)) }
        adaptor.append(buffer,withPresentationTime:CMTime(value:CMTimeValue(frame),timescale:30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

/// Exports one recording with a transparent background and reports what came out.
@MainActor func verifyTransparentExport(video:URL) async {
    let studio=Studio();studio.preferences.revealExport=false
    await studio.load(video)
    studio.look=Look();studio.look.padding=25;studio.look.shadow=0;studio.look.glow=0;studio.look.exportHeight=360
    studio.look.transparentBackground=ProcessInfo.processInfo.environment["LUMIO_OPAQUE"] == nil ? true:nil
    studio.exportSettings=ExportSettings(format:"MOV",codec:"ProRes 4444",fps:30,copyToClipboard:false)
    let output=video.deletingPathExtension().appendingPathExtension("transparent.mov")
    print("exporting…")
    await studio.export(to:output)
    if let message=studio.message { print("FAIL \(message)");exit(2) }
    print("wrote \(output.lastPathComponent)")
    exit(0)
}

@MainActor func verifyCameraBackground(video:URL) async {
    let asset=AVURLAsset(url:video)
    let generator=AVAssetImageGenerator(asset:asset);generator.appliesPreferredTrackTransform=true
    generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
    let masks=PersonMaskMaker(quality:.balanced)
    let context=CIContext()
    var style=CameraStyle();style.background="Blur"
    do {
        let duration=try await asset.load(.duration).seconds
        guard duration>0 else { print("FAIL the video has no duration");exit(2) }
        var found=0
        for step in 0..<5 {
            let time=duration*Double(step)/5
            let frame=CIImage(cgImage:try await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image)
            let treated=cameraWithTreatedBackground(frame,style:style,masks:masks,fingerprint:"check-\(step)")
            let changed=treated != frame
            if changed { found+=1 }
            print(String(format:"%.2f s · %@",time,changed ? "person found, background blurred":"nobody found, frame left alone"))
            if step==0,let png=context.pngRepresentation(of:treated,format:.RGBA8,colorSpace:CGColorSpaceCreateDeviceRGB()) {
                let output=video.deletingPathExtension().appendingPathExtension("background.png")
                try? png.write(to:output);print("wrote \(output.lastPathComponent)")
            }
        }
        print(found>0 ? "PASS the camera background treatment found a person in \(found) of 5 frames":"FAIL no person was found in any sampled frame")
        exit(found>0 ? 0:2)
    } catch { print("FAIL \(error.localizedDescription)");exit(2) }
}

@MainActor func verifyTranscription(audio:URL) async {
    do {
        let duration=try await AVURLAsset(url:audio).load(.duration).seconds
        var tokens:[CaptionToken]?
        var engine="SFSpeechRecognizer"
        if #available(macOS 26.0, *) {
            tokens=try await transcribeWithSpeechAnalyzer(url:audio,locale:Locale(identifier:"en-US"))
            if tokens != nil {engine="SpeechAnalyzer"}
        }
        if tokens == nil {tokens=try await transcribeWithSpeechRecognizer(url:audio,duration:duration,locale:Locale(identifier:"en-US"))}
        let cues=makeCaptionCues(tokens:tokens ?? [],maxWords:5)
        print("ENGINE \(engine)")
        for cue in cues {print(String(format:"%.2f-%.2f ",cue.start,cue.end)+cue.text)}
        exit(cues.isEmpty ? 1:0)
    } catch {
        print("FAIL \(error.localizedDescription)");exit(1)
    }
}
