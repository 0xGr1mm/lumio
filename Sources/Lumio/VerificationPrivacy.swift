import AVFoundation
import AppKit
import CoreImage
import Foundation
import Vision

/// Draws a mock dApp screen: an address, a recovery phrase, an e-mail and a balance, each on its own line,
/// so the scan can be checked against text whose place on the picture is known.
func privacyTestScreen(lines:[String],size:CGSize=CGSize(width:1280,height:720))->CGImage? {
    guard let context=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red:1,green:1,blue:1,alpha:1))
    context.fill(CGRect(origin:.zero,size:size))
    let graphics=NSGraphicsContext(cgContext:context,flipped:false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=graphics
    let font=NSFont.monospacedSystemFont(ofSize:26,weight:.medium)
    for (index,text) in lines.enumerated() {
        let y=size.height-120-Double(index)*70
        (text as NSString).draw(at:CGPoint(x:70,y:y),withAttributes:[.font:font,.foregroundColor:NSColor.black])
    }
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

/// Every line the recognizer read, for a failure message that says what it actually saw.
func privacyRecognizedLines(_ image:CGImage)->[String] {
    let request=VNRecognizeTextRequest()
    request.recognitionLevel = .accurate; request.usesLanguageCorrection=false
    guard (try? VNImageRequestHandler(cgImage:image,options:[:]).perform([request])) != nil else { return [] }
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
}

/// Developer-only: runs the privacy checks alone, which is faster than the whole suite while they are being written.
@MainActor func verifyPrivacyOnly(folder:URL) async {
    do { print(try await verifyPrivacy(folder:folder).joined(separator:"\n")); exit(0) }
    catch { print("FAIL \(error.localizedDescription)"); exit(1) }
}

/// Writes a short recording of a screen with a wallet address on it, so the scan can be run the way it
/// runs for a user: over frames read out of a file rather than over a picture handed to it.
func writeAddressClip(to url:URL,lines:[String],seconds:Double=2) async throws {
    guard let frame=privacyTestScreen(lines:lines) else { throw NSError(domain:"Lumio",code:96,userInfo:[NSLocalizedDescriptionKey:"the test screen could not be drawn"]) }
    try? FileManager.default.removeItem(at:url)
    let size=CGSize(width:frame.width,height:frame.height)
    let writer=try AVAssetWriter(outputURL:url,fileType:.mp4)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:frame.width,AVVideoHeightKey:frame.height])
    input.expectsMediaDataInRealTime=false
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
    var buffer:CVPixelBuffer?
    CVPixelBufferCreate(nil,frame.width,frame.height,kCVPixelFormatType_32BGRA,nil,&buffer)
    guard let buffer else { throw NSError(domain:"Lumio",code:95,userInfo:[NSLocalizedDescriptionKey:"no pixel buffer"]) }
    CVPixelBufferLockBaseAddress(buffer,[])
    if let base=CVPixelBufferGetBaseAddress(buffer),
       let context=CGContext(data:base,width:frame.width,height:frame.height,bitsPerComponent:8,bytesPerRow:CVPixelBufferGetBytesPerRow(buffer),space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipFirst.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) {
        context.draw(frame,in:CGRect(origin:.zero,size:size))
    }
    CVPixelBufferUnlockBaseAddress(buffer,[])
    for index in 0..<Int(seconds*30) {
        while !input.isReadyForMoreMediaData { try await Task.sleep(for:.milliseconds(10)) }
        adaptor.append(buffer,withPresentationTime:CMTime(value:CMTimeValue(index),timescale:30))
    }
    input.markAsFinished()
    await writer.finishWriting()
}

@MainActor func verifyPrivacy(folder:URL) async throws->[String] {
    var lines:[String]=[]
    func privacyFailure(_ text:String)->NSError { NSError(domain:"Lumio",code:98,userInfo:[NSLocalizedDescriptionKey:text]) }
    let whole=CGRect(x:0,y:0,width:1,height:1)

    // Reading a screen: the scan has to find each kind of private detail and put a box on the right line.
    let screenLines=[
        "Wallet  0x71C7656EC7ab88b098defB751B7401B5f6d8976F",
        "abandon ability able absent absorb abstract",
        "absurd abuse access accident acoustic acquire",
        "Account  sonner@example.com",
        "Balance  12.48 ETH"
    ]
    guard let screen=privacyTestScreen(lines:screenLines) else { throw privacyFailure("the privacy test screen could not be drawn") }
    let everything=sensitivePatterns(addresses:true,emails:true,balances:true)
    let found=sensitiveFinds(in:screen,at:1,crop:whole,patterns:everything)
    let kinds=Set(found.map(\.kind))
    guard kinds.contains("Wallet Address") else { throw privacyFailure("the wallet address was not found: \(kinds.sorted())") }
    guard kinds.contains("Recovery Phrase") else { throw privacyFailure("the recovery phrase was not found: \(kinds.sorted()) · read: \(privacyRecognizedLines(screen))") }
    guard kinds.contains("E-mail") else { throw privacyFailure("the e-mail address was not found: \(kinds.sorted())") }
    guard kinds.contains("Balance") else { throw privacyFailure("the balance was not found: \(kinds.sorted()) · read: \(privacyRecognizedLines(screen))") }
    // Each line sits a tenth of the picture below the one before it, so the boxes have to be in that order.
    guard let address=found.first(where:{ $0.kind == "Wallet Address" }),let phrase=found.first(where:{ $0.kind == "Recovery Phrase" }),
          let mail=found.first(where:{ $0.kind == "E-mail" }) else { throw privacyFailure("a find is missing its box") }
    guard address.rect.midY<phrase.rect.midY,phrase.rect.midY<mail.rect.midY else {
        throw privacyFailure("the boxes are not on the lines they were read from: \(address.rect.midY) / \(phrase.rect.midY) / \(mail.rect.midY)") }
    guard address.rect.minX>0,address.rect.maxX<1,address.rect.height>0.01,address.rect.height<0.2 else { throw privacyFailure("the address box is the wrong shape: \(address.rect)") }
    // The hint must not carry the secret: five characters and the last three is all the list shows.
    guard !address.hint.contains("8976F") || address.hint.count<=12 else { throw privacyFailure("the hint shows too much: \(address.hint)") }
    // With every switch off a recovery phrase is still found, because it is never meant to be on screen.
    let phraseOnly=sensitiveFinds(in:screen,at:1,crop:whole,patterns:sensitivePatterns(addresses:false,emails:false,balances:false))
    guard phraseOnly.contains(where:{ $0.kind == "Recovery Phrase" }),!phraseOnly.contains(where:{ $0.kind == "Wallet Address" }) else {
        throw privacyFailure("the switches do not decide what is looked for: \(Set(phraseOnly.map(\.kind)).sorted())") }
    // A private key is the one thing that must always be caught.
    guard let keyScreen=privacyTestScreen(lines:["4c0883a69102937d6231471b5dbb6204fe512961708279c1b4b7c5b9d5a1e1f2"]),
          sensitiveFinds(in:keyScreen,at:0,crop:whole,patterns:everything).contains(where:{ $0.kind == "Private Key" }) else {
        throw privacyFailure("a 64-character private key was not recognized") }
    // Wallets usually show a phrase as a grid of numbered boxes, not as a sentence, so that layout has to work too.
    guard let grid=privacyTestScreen(lines:["1 abandon    2 ability    3 able","4 absent    5 absorb    6 abstract","7 absurd    8 abuse    9 access","10 accident    11 acoustic    12 acquire"]),
          sensitiveFinds(in:grid,at:0,crop:whole,patterns:everything).contains(where:{ $0.kind == "Recovery Phrase" }) else {
        throw privacyFailure("a phrase laid out as a numbered grid was not recognized: \(privacyRecognizedLines(privacyTestScreen(lines:["1 abandon    2 ability    3 able","4 absent    5 absorb    6 abstract","7 absurd    8 abuse    9 access","10 accident    11 acoustic    12 acquire"]) ?? screen))") }
    // Ordinary writing on screen is not a phrase, however many short words it has.
    guard let prose=privacyTestScreen(lines:["the quick brown fox jumps over the lazy dog","and then it runs back home for more of it"]),
          !sensitiveFinds(in:prose,at:0,crop:whole,patterns:everything).contains(where:{ $0.kind == "Recovery Phrase" }) else {
        throw privacyFailure("plain writing was mistaken for a recovery phrase") }
    lines.append("PASS the scan reads wallet addresses, recovery phrases, e-mail and balances off a screen and boxes each one")

    // A crop moves the picture, so a find has to be reported where it now is, and one the crop removed is dropped.
    let half=CGRect(x:0,y:0,width:1,height:0.5)
    let cropped=sensitiveFinds(in:screen,at:1,crop:half,patterns:everything)
    guard let croppedAddress=cropped.first(where:{ $0.kind == "Wallet Address" }) else { throw privacyFailure("the address was lost when the picture was cropped") }
    guard abs(croppedAddress.rect.midY-address.rect.midY*2)<0.02 else { throw privacyFailure("the crop was not taken into account: \(croppedAddress.rect.midY) vs \(address.rect.midY*2)") }
    guard !sensitiveFinds(in:screen,at:1,crop:CGRect(x:0,y:0.75,width:1,height:0.25),patterns:everything).contains(where:{ $0.kind == "Wallet Address" }) else {
        throw privacyFailure("a find the crop removed was still reported") }
    // The same address on frame after frame is one thing to hide, for as long as it was there.
    let repeated=[SensitiveFind(kind:"Wallet Address",hint:"0x71C…76F",rect:CGRect(x:0.1,y:0.2,width:0.3,height:0.05),start:0,end:0),
                  SensitiveFind(kind:"Wallet Address",hint:"0x71C…76F",rect:CGRect(x:0.11,y:0.2,width:0.3,height:0.05),start:2,end:2),
                  SensitiveFind(kind:"E-mail",hint:"sonne…com",rect:CGRect(x:0.1,y:0.2,width:0.3,height:0.05),start:1,end:1)]
    let merged=mergedFinds(repeated,duration:3)
    guard merged.count==2,let span=merged.first(where:{ $0.kind == "Wallet Address" }),span.start<0.01,span.end>2.4,span.rect.width>0.3 else {
        throw privacyFailure("finds were not merged into one range: \(merged.count)") }
    lines.append("PASS finds follow the crop, drop out when it removes them, and repeat sightings become one range")

    // The block has to cover the picture where it is put, and the rest of the frame has to come through untouched.
    let hideStudio=Studio();hideStudio.preferences.revealExport=false
    await hideStudio.load(folder.appendingPathComponent("sample.mp4"))
    hideStudio.look.padding=0;hideStudio.look.radius=0;hideStudio.look.shadow=0;hideStudio.look.glow=0
    let context=CIContext(options:[.workingColorSpace:NSNull()])
    func frameLevels(_ studio:Studio) async throws->(centre:Double,corner:Double) {
        let (asset,composition,_)=try await studio.makeEditingComposition(asset:AVURLAsset(url:studio.source!),size:CGSize(width:640,height:360),fps:30)
        let generator=AVAssetImageGenerator(asset:asset);generator.videoComposition=composition
        generator.requestedTimeToleranceBefore = .zero;generator.requestedTimeToleranceAfter = .zero
        let image=try await generator.image(at:CMTime(seconds:1.5,preferredTimescale:600)).image
        var pixels=[UInt8](repeating:0,count:640*360*4)
        context.render(CIImage(cgImage:image),toBitmap:&pixels,rowBytes:640*4,bounds:CGRect(x:0,y:0,width:640,height:360),format:.RGBA8,colorSpace:nil)
        return (looksPatch(pixels,x:300,y:170,size:20,width:640,height:360),looksPatch(pixels,x:40,y:40,size:20,width:640,height:360))
    }
    let plain=try await frameLevels(hideStudio)
    var block=Annotation(kind:"Hide",start:0,end:3)
    block.x=0.3;block.y=0.3;block.width=0.4;block.height=0.4;block.color=RGB(0x101216)
    hideStudio.annotations=[block]
    let hidden=try await frameLevels(hideStudio)
    guard hidden.centre<20 else { throw privacyFailure("the block does not cover the picture: \(hidden.centre)") }
    guard abs(hidden.corner-plain.corner)<12 else { throw privacyFailure("the block changed the rest of the frame: \(plain.corner) vs \(hidden.corner)") }
    guard plain.centre>hidden.centre+25 else { throw privacyFailure("the picture under the block was already dark: \(plain.centre)") }
    hideStudio.previewTask?.cancel()
    lines.append("PASS a Hide block covers the picture where it is placed and leaves the rest of the frame alone")

    // The whole scan, the way it runs for a user: frames read out of a recording, then covered.
    let clipURL=folder.appendingPathComponent("privacy-screen.mp4")
    try await writeAddressClip(to:clipURL,lines:["Send to  0x71C7656EC7ab88b098defB751B7401B5f6d8976F","Confirm in wallet"])
    let scan=Studio();scan.preferences.revealExport=false
    await scan.load(clipURL)
    guard scan.message==nil,scan.duration>1.5 else { throw privacyFailure("the address recording did not open: \(scan.message ?? "no duration")") }
    scan.privacyAddresses=true;scan.privacyEmails=true;scan.privacyBalances=false
    await scan.scanForSensitiveText()
    guard !scan.privacyScanning,scan.privacyProgress==nil else { throw privacyFailure("the scan did not finish") }
    guard let onScreen=scan.privacyFinds.first(where:{ $0.kind=="Wallet Address" }) else {
        throw privacyFailure("the scan found nothing in the recording: \(scan.privacyFinds.map(\.kind))") }
    // It is on screen the whole time, so the block has to last the whole time.
    guard onScreen.start<0.2,onScreen.end>scan.duration-0.3 else { throw privacyFailure("the range does not cover the recording: \(onScreen.start) – \(onScreen.end)") }
    scan.hideEveryFind()
    guard scan.annotations.count==scan.privacyFinds.count,scan.annotations.allSatisfy({ $0.kind=="Hide" }),scan.privacyFinds.allSatisfy(\.hidden) else {
        throw privacyFailure("the finds were not covered: \(scan.annotations.count) blocks for \(scan.privacyFinds.count) finds") }
    guard let block=scan.annotations.first(where:{ abs($0.y-onScreen.rect.minY)<0.001 }) else { throw privacyFailure("a block is not where its find was") }
    guard block.start==onScreen.start,block.end==onScreen.end else { throw privacyFailure("a block does not last as long as its find") }
    // And the picture under it is gone: the address was dark text on white, the block is near black.
    scan.look.padding=0;scan.look.radius=0;scan.look.shadow=0;scan.look.glow=0
    let (scanAsset,scanComposition,_)=try await scan.makeEditingComposition(asset:AVURLAsset(url:clipURL),size:CGSize(width:640,height:360),fps:30)
    let scanGenerator=AVAssetImageGenerator(asset:scanAsset);scanGenerator.videoComposition=scanComposition
    scanGenerator.requestedTimeToleranceBefore = .zero;scanGenerator.requestedTimeToleranceAfter = .zero
    let coveredFrame=try await scanGenerator.image(at:CMTime(seconds:1,preferredTimescale:600)).image
    var covered=[UInt8](repeating:0,count:640*360*4)
    context.render(CIImage(cgImage:coveredFrame),toBitmap:&covered,rowBytes:640*4,bounds:CGRect(x:0,y:0,width:640,height:360),format:.RGBA8,colorSpace:nil)
    let blockRow=Int((block.y+block.height/2)*360),blockColumn=Int((block.x+block.width/2)*640)
    let insideBlock=looksPatch(covered,x:max(0,blockColumn-8),y:max(0,blockRow-4),size:12,width:640,height:360)
    let elsewhere=looksPatch(covered,x:40,y:40,size:20,width:640,height:360)
    guard insideBlock<60 else { throw privacyFailure("the address is still readable under the block: \(insideBlock)") }
    guard elsewhere>150 else { throw privacyFailure("the block covered more than the address: \(elsewhere)") }
    scan.previewTask?.cancel()
    lines.append("PASS the scan reads a recording, covers the address it found for as long as it is there, and leaves the rest")

    // A scan describes the timeline it was made on. Cutting a range out moves everything after it, so the
    // list is dropped rather than left pointing at the wrong moments; the block already placed moves with the cut.
    scan.annotations=[];scan.privacyFinds=[];scan.privacyScanned=false
    await scan.scanForSensitiveText()
    guard let beforeCut=scan.privacyFinds.first else { throw privacyFailure("the second scan found nothing") }
    scan.hideFind(beforeCut.id)
    let placedAt=scan.annotations.first?.start ?? -1
    guard scan.rippleDelete([VideoCut(start:0.2,end:0.7)]) else { throw privacyFailure("the test cut was not made") }
    guard scan.privacyFinds.isEmpty,!scan.privacyScanned else { throw privacyFailure("a stale scan survived a cut") }
    guard let movedBlock=scan.annotations.first,movedBlock.start<=placedAt+0.001 else { throw privacyFailure("the block already placed did not move with the cut") }
    guard movedBlock.end<=scan.duration+0.001 else { throw privacyFailure("the block reaches past the shortened timeline") }
    scan.previewTask?.cancel()
    lines.append("PASS a cut drops the scan's list instead of leaving it pointing at the wrong moments")

    // The one-click pass: every step reaches an end, the fade is set, and the clicks are lit.
    let quick=Studio();quick.preferences.revealExport=false
    await quick.load(folder.appendingPathComponent("sample.mp4"))
    quick.captions=[CaptionCue(start:0.2,end:1,text:"Already written",words:[])]
    let startingDuration=quick.duration
    await quick.quickEdit()
    guard quick.quickSteps.count==5,quick.quickSteps.allSatisfy({ $0.state=="done" || $0.state=="skipped" }) else {
        throw quick.failure("the quick edit left a step unfinished: \(quick.quickSteps.map { "\($0.label):\($0.state)" })") }
    guard quick.quickSteps[1].detail.contains("already") else { throw quick.failure("the quick edit rewrote captions that were already there") }
    guard quick.motion.autoZoom,quick.motion.clickHighlight else { throw quick.failure("the quick edit did not turn on click zooms") }
    guard quick.look.resolvedFadeIn>0,quick.look.resolvedFadeOut>0 else { throw quick.failure("the quick edit did not fade the ends") }
    guard quick.duration<=startingDuration+0.001 else { throw quick.failure("the quick edit made the video longer") }
    guard quick.quickEditFinished != nil,!quick.quickRunning else { throw quick.failure("the quick edit did not finish") }
    // Running it twice must not fade an already faded video again or cut anything a second time.
    let settled=quick.snapshot
    await quick.quickEdit()
    guard quick.snapshot==settled else { throw quick.failure("a second quick edit changed the video again") }
    quick.previewTask?.cancel()
    lines.append("PASS the one-click pass cuts, captions, zooms, checks privacy and fades, and does nothing the second time")
    return lines
}
