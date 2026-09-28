import AVFoundation
import AppKit
import CoreImage

struct FrameDesign {
    var size:CGSize
    var rect:CGRect
    var placement:VideoPlacement
    /// Visible part of the source, top-left unit coordinates.
    var crop:CGRect
    var reframe:Bool
    var transform:CGAffineTransform
    var background:CGImage
    var border:CGImage
    var mask:CGImage
    var ripple:CGImage
    var cursors:[String:CGImage]
    var hotspots:[String:CGPoint]
    var samples:[PointerSample]
    /// Where automatic zooms point: the pointer path with a dead zone and a softer spring.
    var follow:[PointerSample]
    var clicks:[Double]
    var manual:[ZoomClip]
    var auto:[ZoomClip]
    var settings:MotionSettings
    var videoStyle:VideoStyle
    var cameraStyle:CameraStyle
    var captionCues:[CaptionCue]
    var captionStyle:CaptionStyle
    var shortcuts:[KeySample]
    var typingTimes:[Double]
    var keyboardStyle:KeyboardOverlayStyle
    var overlays:OverlayArtCache
    var duration:Double
    var cameraID:CMPersistentTrackID = kCMPersistentTrackID_Invalid
    var showVideo=true
    /// True when the background is left out, so the video is delivered with transparency around it.
    var transparent=false
    var visibleRanges:[RenderTimeRange]=[]
    var annotations:[Annotation]=[]
    /// Seconds of fade from and to black at the ends of the video.
    var fadeIn:Double=0
    var fadeOut:Double=0
    /// Cuts that dip to black: the moment of the cut and how long the dip lasts in total.
    var dips:[RenderTimeRange]=[]
    /// Stretches where the incoming clip crosses over the outgoing one.
    var dissolves:[DissolveSpan]=[]
    var secondaryID:CMPersistentTrackID=kCMPersistentTrackID_Invalid
    /// A logo over the finished frame, already placed and faded.
    var watermark:CGImage?=nil
    var watermarkRect:CGRect = .zero
    var watermarkOpacity:Double=1
    /// Present only when the camera background is blurred or removed.
    var personMasks:PersonMaskMaker?=nil
    /// Stretches played by the recording the editor was opened with; only there is its pointer drawn.
    var cursorRanges:[RenderTimeRange]=[]
    /// Height in canvas pixels of the bar that fills as the video plays, and its colour. Zero for none.
    var progressHeight:Double=0
    var progressColor:RGB=RGB(0xBFEE63)
}
/// One cross dissolve: when it begins, how long it lasts, and which track carries the incoming clip.
struct DissolveSpan {
    var start:Double
    var length:Double
    var incomingOnSecondary:Bool
    /// How much of the incoming clip is shown at a time, 0…1.
    func weight(at time:Double)->Double {
        guard length>0.0001 else { return time>=start ? 1:0 }
        return max(0,min(1,(time-start)/length))
    }
}

struct RenderTimeRange {
    var start:Double
    var end:Double
    func contains(_ time:Double)->Bool {time>=start && time<end}
}
/// Caption and shortcut images are drawn the first time a frame needs them and reused,
/// instead of rendering every word state of the whole video on the main thread before each preview.
final class OverlayArtCache:@unchecked Sendable {
    private let lock=NSLock()
    private var captions:[String:CGImage]=[:]
    private var shortcuts:[UUID:CGImage]=[:]
    private var annotations:[String:AnnotationArt]=[:]
    let captionStyle:CaptionStyle
    let keyboardStyle:KeyboardOverlayStyle
    init(captionStyle:CaptionStyle,keyboardStyle:KeyboardOverlayStyle) {self.captionStyle=captionStyle;self.keyboardStyle=keyboardStyle}
    func caption(_ cue:CaptionCue,activeWord:Int?)->CGImage {
        let key="\(cue.id.uuidString)|\(activeWord ?? -1)"
        lock.lock();let hit=captions[key];lock.unlock()
        if let hit {return hit}
        let image=captionArtwork(cue:cue,activeWord:activeWord,style:captionStyle)
        lock.lock();if captions.count>600 {captions.removeAll()};captions[key]=image;lock.unlock()
        return image
    }
    func shortcut(_ sample:KeySample)->CGImage {
        lock.lock();let hit=shortcuts[sample.id];lock.unlock()
        if let hit {return hit}
        let image=shortcutArtwork(sample:sample,style:keyboardStyle)
        lock.lock();if shortcuts.count>600 {shortcuts.removeAll()};shortcuts[sample.id]=image;lock.unlock()
        return image
    }
    /// The cache lives for one composition, and any annotation edit builds a new one, so the id and frame size identify the drawing.
    func annotation(_ item:Annotation,frame size:CGSize)->AnnotationArt? {
        let key="\(item.id.uuidString)|\(Int(size.width))x\(Int(size.height))"
        lock.lock();let hit=annotations[key];lock.unlock()
        if let hit {return hit}
        guard let art=annotationArtwork(item,frame:size) else {return nil}
        lock.lock();if annotations.count>200 {annotations.removeAll()};annotations[key]=art;lock.unlock()
        return art
    }
}
/// True when any of the sorted times falls within [start, end].
func hasEvent(_ times:[Double],from start:Double,to end:Double)->Bool {
    var low=0,high=times.count
    while low<high {let mid=(low+high)/2;if times[mid]<start {low=mid+1} else {high=mid}}
    return low<times.count && times[low]<=end
}
@MainActor func rippleArtwork() -> CGImage {
    let c=CGContext(data:nil,width:128,height:128,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.setStrokeColor(NSColor(red:0.75,green:0.93,blue:0.39,alpha:0.8).cgColor);c.setLineWidth(4);c.strokeEllipse(in:CGRect(x:4,y:4,width:120,height:120));return c.makeImage()!
}
@MainActor func layerImage(_ layer:CALayer,size:CGSize) -> CGImage {
    let c=CGContext(data:nil,width:Int(size.width),height:Int(size.height),bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    layer.render(in:c);return c.makeImage()!
}
@MainActor func magnificCursorArtwork(style:String) -> CGImage? {
    struct Source {var file:String;var crop:CGRect;var key:(Double,Double,Double);var tolerance:Double;var softness:Double}
    let source:Source?
    switch style {
    case "Neon":source=Source(file:"neon",crop:CGRect(x:32,y:60,width:270,height:330),key:(0.0,0.07,0.25),tolerance:0.10,softness:0.30)
    case "Pixel":source=Source(file:"pixel",crop:CGRect(x:55,y:42,width:150,height:180),key:(1,1,1),tolerance:0.08,softness:0.18)
    case "3D":source=Source(file:"three-dimensional",crop:CGRect(x:130,y:146,width:380,height:380),key:(0.97,0.97,0.97),tolerance:0.12,softness:0.20)
    case "Color Pop":source=Source(file:"color",crop:CGRect(x:48,y:310,width:155,height:188),key:(0.96,0.96,0.96),tolerance:0.06,softness:0.20)
    case "Cartoon":source=Source(file:"cartoon",crop:CGRect(x:245,y:125,width:130,height:120),key:(0.54,0.53,0.57),tolerance:0.10,softness:0.22)
    default:source=nil
    }
    guard let source,let url=Bundle.main.url(forResource:source.file,withExtension:"jpg",subdirectory:"Cursors/Magnific"),let image=NSImage(contentsOf:url) else{return nil}
    let width=96,height=128
    var pixels=[UInt8](repeating:0,count:width*height*4)
    guard let context=CGContext(data:&pixels,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
    context.translateBy(x:0,y:CGFloat(height));context.scaleBy(x:1,y:-1)
    let graphics=NSGraphicsContext(cgContext:context,flipped:true)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
    let aspect=source.crop.width/source.crop.height
    let targetHeight=112.0,targetWidth=min(82.0,targetHeight*aspect)
    image.draw(in:CGRect(x:7,y:6,width:targetWidth,height:targetHeight),from:source.crop,operation:.sourceOver,fraction:1)
    NSGraphicsContext.restoreGraphicsState()
    let key=source.key
    for i in stride(from:0,to:pixels.count,by:4) where pixels[i+3] > 0 {
        let r=Double(pixels[i])/255,g=Double(pixels[i+1])/255,b=Double(pixels[i+2])/255
        let distance=sqrt(pow(r-key.0,2)+pow(g-key.1,2)+pow(b-key.2,2))
        let keep=max(0,min(1,(distance-source.tolerance)/source.softness))
        let oldAlpha=Double(pixels[i+3]),newAlpha=oldAlpha*keep
        if oldAlpha>0 {let ratio=newAlpha/oldAlpha;pixels[i]=UInt8(Double(pixels[i])*ratio);pixels[i+1]=UInt8(Double(pixels[i+1])*ratio);pixels[i+2]=UInt8(Double(pixels[i+2])*ratio);pixels[i+3]=UInt8(newAlpha)}
    }
    for y in 0..<(height/2) {
        let opposite=height-1-y
        for x in 0..<width {
            let a=(y*width+x)*4,b=(opposite*width+x)*4
            for channel in 0..<4 {pixels.swapAt(a+channel,b+channel)}
        }
    }
    return context.makeImage()
}
@MainActor func customCursorPackArtwork(style:String,shape:String) -> CGImage? {
    let file:String?
    switch style {
    case "Minecraft Enchanted":file="minecraft-enchanted"
    case "Pop Cat":file="pop-cat"
    case "Rose Diamond":file="among-us-rose"
    case "Among Us Batman":file="among-us-batman"
    case "Among Us Joker":file="among-us-joker"
    case "Harley Quinn":file="harley-quinn"
    default:file=nil
    }
    guard let file,
          ["arrow","hand","openHand","closedHand"].contains(shape),
          let url=Bundle.main.url(forResource:file,withExtension:"png",subdirectory:"Cursors/CustomCursor"),
          let image=NSImage(contentsOf:url),
          let source=image.cgImage(forProposedRect:nil,context:nil,hints:nil) else{return nil}
    let usePointer=shape != "arrow"
    let half=source.width/2
    let crop=CGRect(x:usePointer ? half:0,y:0,width:usePointer ? source.width-half:half,height:source.height)
    guard let artwork=source.cropping(to:crop) else{return nil}
    let width=96,height=128
    guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return nil}
    let scale=min(88/CGFloat(artwork.width),112/CGFloat(artwork.height))
    let size=CGSize(width:CGFloat(artwork.width)*scale,height:CGFloat(artwork.height)*scale)
    let target=CGRect(x:4,y:CGFloat(height)-size.height-8,width:size.width,height:size.height)
    context.interpolationQuality = .high
    context.draw(artwork,in:target)
    return context.makeImage()
}
@MainActor func nativeCursor(_ shape:String) -> NSCursor? {
    switch shape {
    case "ibeam":return .iBeam
    case "hand":return .pointingHand
    case "crosshair":return .crosshair
    case "resizeHorizontal":return .resizeLeftRight
    case "resizeVertical":return .resizeUpDown
    case "openHand":return .openHand
    case "closedHand":return .closedHand
    default:return nil
    }
}
/// The artwork pixel (top-left origin, 96×128) that sits exactly on the recorded pointer position.
@MainActor func cursorHotspot(style:String,shape:String) -> CGPoint {
    let packs=["Minecraft Enchanted","Pop Cat","Rose Diamond","Among Us Batman","Among Us Joker","Harley Quinn"]
    if shape == "arrow" || (packs.contains(style) && ["hand","openHand","closedHand"].contains(shape)) {return CGPoint(x:8,y:8)}
    if let native=nativeCursor(shape),native.image.size.width>0,native.image.size.height>0 {
        return CGPoint(x:8+native.hotSpot.x/native.image.size.width*76,y:8+native.hotSpot.y/native.image.size.height*76)
    }
    switch shape {
    case "ibeam":return CGPoint(x:40,y:44)
    case "hand":return CGPoint(x:37,y:4)
    default:return CGPoint(x:46,y:46)
    }
}
@MainActor func cursorArtwork(style:String,color:NSColor,shape:String="arrow") -> CGImage {
    if let custom=customCursorPackArtwork(style:style,shape:shape) {return custom}
    if shape == "arrow",let magnific=magnificCursorArtwork(style:style) {return magnific}
    let c=CGContext(data:nil,width:96,height:128,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.translateBy(x:0,y:128);c.scaleBy(x:1,y:-1)
    // Some system cursors report an empty image outside a running app; fall back to drawn shapes instead of a blank cursor.
    if shape != "arrow",let native=nativeCursor(shape)?.image,native.size.width>0,native.size.height>0 {
        let graphics=NSGraphicsContext(cgContext:c,flipped:true)
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
        native.draw(in:CGRect(x:8,y:8,width:76,height:76),from:.zero,operation:.sourceOver,fraction:1)
        NSGraphicsContext.restoreGraphicsState()
        return c.makeImage()!
    }
    let p=CGMutablePath()
    if shape == "ibeam" {
        p.move(to:CGPoint(x:24,y:8));p.addLine(to:CGPoint(x:55,y:8));p.move(to:CGPoint(x:40,y:8));p.addLine(to:CGPoint(x:40,y:80));p.move(to:CGPoint(x:24,y:80));p.addLine(to:CGPoint(x:55,y:80))
        c.addPath(p);c.setStrokeColor(NSColor.black.cgColor);c.setLineWidth(11);c.strokePath()
        c.addPath(p);c.setStrokeColor(color.cgColor);c.setLineWidth(6);c.strokePath()
    } else if shape == "hand" || shape == "openHand" || shape == "closedHand" {
        p.move(to:CGPoint(x:30,y:80));p.addLine(to:CGPoint(x:12,y:48));p.addQuadCurve(to:CGPoint(x:30,y:48),control:CGPoint(x:18,y:32));p.addLine(to:CGPoint(x:30,y:12));p.addQuadCurve(to:CGPoint(x:44,y:12),control:CGPoint(x:37,y:0));p.addLine(to:CGPoint(x:44,y:38));p.addLine(to:CGPoint(x:66,y:32));p.addQuadCurve(to:CGPoint(x:78,y:48),control:CGPoint(x:80,y:28));p.addLine(to:CGPoint(x:72,y:86));p.closeSubpath()
        c.addPath(p);c.setFillColor(color.cgColor);c.setStrokeColor(NSColor.black.cgColor);c.setLineWidth(4);c.drawPath(using:.fillStroke)
    } else if shape != "arrow" {
        p.move(to:CGPoint(x:46,y:10));p.addLine(to:CGPoint(x:46,y:82));p.move(to:CGPoint(x:10,y:46));p.addLine(to:CGPoint(x:82,y:46))
        c.addPath(p);c.setStrokeColor(NSColor.black.cgColor);c.setLineWidth(9);c.strokePath()
        c.addPath(p);c.setStrokeColor(color.cgColor);c.setLineWidth(4);c.strokePath()
    } else {
        let pts:[CGPoint] = [CGPoint(x:8,y:8),CGPoint(x:8,y:88),CGPoint(x:30,y:68),CGPoint(x:49,y:106),CGPoint(x:63,y:99),CGPoint(x:44,y:61),CGPoint(x:76,y:59)]
        p.addLines(between:pts);p.closeSubpath()
        let fill:NSColor
        let stroke:NSColor
        let lineWidth:CGFloat
        let mode:CGPathDrawingMode
        switch style {
        case "Classic Outline":fill=color;stroke = .black;lineWidth=4;mode = .fillStroke
        case "Solid Arrow":fill = .black;stroke = .black;lineWidth=0;mode = .fill
        default:fill=style == "Lavender" ? NSColor(red:0.65,green:0.5,blue:1,alpha:1):color;stroke = .black;lineWidth=3;mode = .fillStroke
        }
        c.addPath(p);c.setFillColor(fill.cgColor);c.setStrokeColor(stroke.cgColor);c.setLineWidth(lineWidth);c.setLineJoin(.round);c.drawPath(using:mode)
        if style == "Lavender" { c.saveGState();c.addPath(p);c.clip();let colors=[NSColor.white.cgColor,fill.cgColor,NSColor.systemBlue.cgColor] as CFArray;let g=CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,0.5,1])!;c.drawLinearGradient(g,start:CGPoint(x:10,y:10),end:CGPoint(x:75,y:95),options:[]);c.restoreGState() }
    }
    return c.makeImage()!
}
final class FrameInstruction:NSObject,AVVideoCompositionInstructionProtocol,@unchecked Sendable {
    let timeRange:CMTimeRange
    let enablePostProcessing=false
    let containsTweening=true
    let requiredSourceTrackIDs:[NSValue]?
    let passthroughTrackID:CMPersistentTrackID=kCMPersistentTrackID_Invalid
    let trackID:CMPersistentTrackID
    let design:FrameDesign
    init(trackID:CMPersistentTrackID,timeRange:CMTimeRange,design:FrameDesign) {
        self.trackID=trackID;self.design=design;self.timeRange=timeRange
        var ids:[NSValue]=[];if trackID != kCMPersistentTrackID_Invalid {ids.append(NSNumber(value:trackID))};if design.cameraID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value:design.cameraID)) };if design.secondaryID != kCMPersistentTrackID_Invalid { ids.append(NSNumber(value:design.secondaryID)) };requiredSourceTrackIDs=ids
    }
}
final class FrameCompositor:NSObject,AVVideoCompositing,@unchecked Sendable {
    var sourcePixelBufferAttributes:[String:any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String:[kCVPixelFormatType_32BGRA,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]]
    var requiredPixelBufferAttributesForRenderContext:[String:any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferIOSurfacePropertiesKey as String:[String:Int]()]
    let queue=DispatchQueue(label:"studio.lumio.compositor")
    let context=CIContext(options:[.cacheIntermediates:false])
    func renderContextChanged(_ newRenderContext:AVVideoCompositionRenderContext) {}
    func startRequest(_ request:AVAsynchronousVideoCompositionRequest) {
        queue.async {
            autoreleasepool {
                guard let instruction=request.videoCompositionInstruction as? FrameInstruction,let output=request.renderContext.newPixelBuffer() else { request.finish(with:NSError(domain:"Lumio.render",code:1));return }
                let source=instruction.trackID == kCMPersistentTrackID_Invalid ? nil:request.sourceFrame(byTrackID:instruction.trackID)
                let camera=instruction.design.cameraID == kCMPersistentTrackID_Invalid ? nil:request.sourceFrame(byTrackID:instruction.design.cameraID)
                let time=request.compositionTime.seconds
                let second=instruction.design.secondaryID == kCMPersistentTrackID_Invalid ? nil:request.sourceFrame(byTrackID:instruction.design.secondaryID)
                let cameraImage=camera.map{CIImage(cvPixelBuffer:$0)}
                var image=self.frame(source.map{CIImage(cvPixelBuffer:$0)},camera:cameraImage,time:time,design:instruction.design)
                if let second {
                    // Both clips are on screen: the finished frame is drawn for each and mixed by how far the dissolve has come.
                    let incoming=self.frame(CIImage(cvPixelBuffer:second),camera:cameraImage,time:time,design:instruction.design)
                    let span=instruction.design.dissolves.first { time>=$0.start-0.001 && time<=$0.start+$0.length+0.001 }
                    let weight=span?.weight(at:time) ?? (source == nil ? 1:0)
                    if source == nil { image=incoming }
                    else if weight>0.001 { image=self.opacity(incoming,weight).composited(over:image).cropped(to:CGRect(origin:.zero,size:instruction.design.size)) }
                }
                self.context.render(image,to:output,bounds:CGRect(origin:.zero,size:instruction.design.size),colorSpace:CGColorSpaceCreateDeviceRGB())
                request.finish(withComposedVideoFrame:output)
            }
        }
    }
    func cancelAllPendingVideoCompositionRequests() { queue.sync {} }
    func opacity(_ image:CIImage,_ amount:Double)->CIImage { image.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:amount)]) }
    func fitted(_ image:CIImage,to rect:CGRect,mirror:Bool=false)->CIImage {
        let normalized=image.transformed(by:CGAffineTransform(translationX:-image.extent.minX,y:-image.extent.minY))
        let scale=max(rect.width/normalized.extent.width,rect.height/normalized.extent.height)
        var output=normalized.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
        if mirror {output=output.transformed(by:CGAffineTransform(translationX:output.extent.width,y:0).scaledBy(x:-1,y:1))}
        return output.transformed(by:CGAffineTransform(translationX:rect.midX-output.extent.midX,y:rect.midY-output.extent.midY)).cropped(to:rect)
    }
    func rounded(_ image:CIImage,in rect:CGRect,radius:Double)->CIImage {
        guard let filter=CIFilter(name:"CIRoundedRectangleGenerator") else{return image.cropped(to:rect)}
        filter.setValue(CIVector(cgRect:rect),forKey:"inputExtent");filter.setValue(radius,forKey:"inputRadius");filter.setValue(CIColor.white,forKey:"inputColor")
        guard let mask=filter.outputImage else{return image.cropped(to:rect)}
        return image.applyingFilter("CIBlendWithAlphaMask",parameters:[kCIInputBackgroundImageKey:CIImage(color:.clear).cropped(to:rect),kCIInputMaskImageKey:mask]).cropped(to:rect)
    }
    func cameraRect(_ style:CameraStyle,canvas:CGRect,video:CGRect,zoomed:Bool)->CGRect {
        if style.layout == "Camera Full" {return video}
        if style.layout == "Split Left" {return CGRect(x:video.minX,y:video.minY,width:video.width*0.36,height:video.height)}
        if style.layout == "Split Right" {return CGRect(x:video.maxX-video.width*0.36,y:video.minY,width:video.width*0.36,height:video.height)}
        let zoomFactor=zoomed ? style.zoomSize/100:1
        let w=canvas.width*style.size/100*zoomFactor,h=w*0.75
        let m=style.margin
        let x=style.position.contains("Left") ? m:style.position.contains("Right") ? canvas.width-w-m:(canvas.width-w)/2
        let y=style.position.contains("Top") ? canvas.height-h-m:style.position.contains("Bottom") ? m:(canvas.height-h)/2
        return CGRect(x:x,y:y,width:w,height:h)
    }
    func frame(_ raw:CIImage?,camera:CIImage?,time:Double,design d:FrameDesign)->CIImage {
        let canvas=CGRect(origin:.zero,size:d.size),r=d.rect,s=d.settings,vs=d.videoStyle,placement=d.placement
        let visible=d.visibleRanges.isEmpty || d.visibleRanges.contains {$0.contains(time)}
        let backdrop=d.transparent ? CIImage.empty().cropped(to:canvas):CIImage(cgImage:d.background)
        guard visible,d.showVideo,let raw else {return CIImage(cgImage:d.border).composited(over:backdrop).cropped(to:canvas)}
        let transformed=raw.transformed(by:d.transform)
        var source=transformed.transformed(by:CGAffineTransform(translationX:-transformed.extent.minX,y:-transformed.extent.minY))
        if d.crop != CGRect(x:0,y:0,width:1,height:1) {
            // The crop uses top-left unit coordinates; Core Image's origin is at the bottom left.
            let width=source.extent.width,height=source.extent.height
            let kept=CGRect(x:d.crop.minX*width,y:(1-d.crop.maxY)*height,width:d.crop.width*width,height:d.crop.height*height)
            source=source.cropped(to:kept).transformed(by:CGAffineTransform(translationX:-kept.minX,y:-kept.minY))
        }
        // Annotations are drawn on the visible video before zoom, so they stay on their spot as the view moves.
        if !d.annotations.isEmpty { source=annotated(source,time:time,annotations:d.annotations,art:d.overlays) }
        // A recording added to the project can have another shape; it is fitted whole instead of being cropped to the canvas width.
        let sourceAspect=source.extent.width/max(1,source.extent.height)
        let contentAspect=placement.contentSize.width/max(1,placement.contentSize.height)
        let mismatched=abs(sourceAspect-contentAspect)>0.01
        let baseScale=mismatched ? min(placement.contentSize.width/max(1,source.extent.width),placement.contentSize.height/max(1,source.extent.height))
                             : placement.contentSize.width/max(1,source.extent.width)
        let centering=CGPoint(x:(placement.contentSize.width-source.extent.width*baseScale)/2,y:(placement.contentSize.height-source.extent.height*baseScale)/2)
        func pose(_ t:Double)->ZoomPose {
            let value=motionPose(at:t,manual:d.manual,auto:d.auto,samples:d.follow,settings:s)
            return d.reframe ? reframedPose(value,follow:pointerAt(t,samples:d.follow)):value
        }
        let current=pose(time)
        let count=s.blurEnabled ? [3,5,9][max(0,min(2,s.blurQuality))]:1
        var video:CIImage?
        for i in 0..<count {
            let delta=count == 1 ? 0:Double(i)/Double(count-1)*s.blurAmount/30
            let sampleTime=max(0,time-delta*s.blurZoom)
            let sampled=sampleTime == time ? current:pose(sampleTime)
            let box=placement.origin(sampled)
            let origin=CGPoint(x:box.x+centering.x*sampled.scale,y:box.y+centering.y*sampled.scale)
            var layer=source.transformed(by:CGAffineTransform(scaleX:baseScale*sampled.scale,y:baseScale*sampled.scale)).transformed(by:CGAffineTransform(translationX:origin.x,y:origin.y)).cropped(to:r)
            if vs.opacity < 0.999 {layer=opacity(layer,max(0,min(1,vs.opacity)))}
            if count > 1 && s.blurScreen > 0 {
                let a=placement.origin(pose(max(0,sampleTime-1.0/60)))
                let dx=origin.x-a.x,dy=origin.y-a.y
                let radius=min(30,hypot(dx,dy)*s.blurScreen*s.blurAmount*0.25)
                if radius > 0.1 { layer=layer.clampedToExtent().applyingFilter("CIMotionBlur",parameters:[kCIInputRadiusKey:radius,kCIInputAngleKey:atan2(dy,dx)]).cropped(to:r) }
            }
            let weighted=opacity(layer,1/Double(count))
            video=video.map { weighted.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:$0]) } ?? weighted
        }
        var content=video ?? source
        let onOpenedRecording=d.cursorRanges.isEmpty || d.cursorRanges.contains { $0.contains(time) }
        if s.showCursor,onOpenedRecording,!d.samples.isEmpty {
            var cursorLayer:CIImage?
            let n=s.blurEnabled && s.blurCursor > 0 ? count:1
            for i in 0..<n {
                let lag=n == 1 ? 0:Double(i)/Double(n-1)*s.blurAmount*s.blurCursor/30
                var t=max(0,time-lag)
                if s.endMotion == "loop",let last=d.samples.last,last.time > 0,t > last.time { t=t.truncatingRemainder(dividingBy:last.time) }
                guard let p=pointerAt(t,samples:d.samples),p.x >= 0,p.x <= 1,p.y >= 0,p.y <= 1 else { continue }
                if s.endMotion == "hide", let last=d.samples.last,t > last.time+0.1 { continue }
                if s.hideTyping,hasEvent(d.typingTimes,from:t-0.45,to:t) {continue}
                if s.hideIdle,let earlier=pointerAt(max(0,t-s.idleDelay),samples:d.samples),hypot(p.x-earlier.x,p.y-earlier.y)<0.0025,!d.clicks.contains(where:{t-$0>=0 && t-$0<s.idleDelay}) {continue}
                let shape=s.type == "Auto" ? p.shape:"arrow"
                guard let cg=d.cursors[shape] ?? d.cursors["arrow"] else { continue }
                let hot=d.hotspots[shape] ?? CGPoint(x:8,y:8)
                let click=d.clicks.last(where:{$0 <= t})
                let elapsed=click.map{t-$0} ?? 100
                let pulse=elapsed < s.clickDuration ? sin(.pi*elapsed/max(0.01,s.clickDuration)):0
                let factor=max(0.1,s.size/100)*placement.contentSize.width/1920*0.38*current.scale*(1-s.clickZoom*pulse)
                let point=placement.point(p,current)
                var c=CIImage(cgImage:cg).transformed(by:CGAffineTransform(translationX:-hot.x,y:-(CGFloat(cg.height)-hot.y))).transformed(by:CGAffineTransform(scaleX:factor,y:factor))
                if s.tilt,let previous=pointerAt(max(0,t-0.04),samples:d.samples) { let angle=max(-0.45,min(0.45,(p.x-previous.x)*12));c=c.transformed(by:CGAffineTransform(rotationAngle:-angle)) }
                c=c.transformed(by:CGAffineTransform(translationX:point.x,y:point.y))
                if s.clickHighlight,elapsed < s.clickDuration {
                    let radius=(12+elapsed/max(0.01,s.clickDuration)*45)*r.width/1920
                    let ring=CIImage(cgImage:d.ripple).transformed(by:CGAffineTransform(translationX:-64,y:-64)).transformed(by:CGAffineTransform(scaleX:radius/60,y:radius/60)).transformed(by:CGAffineTransform(translationX:point.x,y:point.y))
                    c=c.composited(over:opacity(ring,1-elapsed/max(0.01,s.clickDuration)))
                }
                let weighted=opacity(c,1/Double(n));cursorLayer=cursorLayer.map{weighted.applyingFilter("CIAdditionCompositing",parameters:[kCIInputBackgroundImageKey:$0])} ?? weighted
            }
            if let cursorLayer { content=cursorLayer.composited(over:content) }
        }
        // A spotlight on the pointer: everything else is dimmed, so an eye goes where the hand is.
        if s.resolvedSpotlight>0,onOpenedRecording,let p=pointerAt(time,samples:d.samples) {
            let point=placement.point(p,current)
            let radius=max(24.0,s.resolvedSpotlightSize/100*min(r.width,r.height)*current.scale)
            let keep=1-s.resolvedSpotlight/100*0.85
            if let falloff=CIFilter(name:"CIRadialGradient",parameters:[
                "inputCenter":CIVector(x:point.x,y:point.y),
                "inputRadius0":radius*0.7,"inputRadius1":radius,
                "inputColor0":CIColor(red:1,green:1,blue:1),"inputColor1":CIColor(red:0,green:0,blue:0)])?.outputImage?.cropped(to:canvas) {
                let dimmed=content.applyingFilter("CIColorMatrix",parameters:[
                    "inputRVector":CIVector(x:keep,y:0,z:0,w:0),
                    "inputGVector":CIVector(x:0,y:keep,z:0,w:0),
                    "inputBVector":CIVector(x:0,y:0,z:keep,w:0)])
                content=content.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:dimmed,kCIInputMaskImageKey:falloff]).cropped(to:canvas)
            }
        }
        let clear=CIImage(color:.clear).cropped(to:canvas)
        content=content.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:clear,kCIInputMaskImageKey:CIImage(cgImage:d.mask)])
        var result=content.composited(over:backdrop)
        let cameraStyle=d.cameraStyle
        if var camera,cameraStyle.enabled,cameraStyle.layout != "Screen Only" {
            camera=cameraWithTreatedBackground(camera,style:cameraStyle,masks:d.personMasks,fingerprint:String(format:"%.4f",time))
            let target=cameraRect(cameraStyle,canvas:canvas,video:r,zoomed:current.scale > 1.01)
            // A removed background leaves the person cut out, so a frame or rounded corners around them would put the box back.
            let cutout=cameraStyle.resolvedBackground == "Remove"
            var cameraLayer=cutout ? fitted(camera,to:target,mirror:cameraStyle.mirror).cropped(to:target)
                                   : rounded(fitted(camera,to:target,mirror:cameraStyle.mirror),in:target,radius:min(target.width,target.height)*cameraStyle.roundness/200)
            if cameraStyle.borderWidth > 0, !cutout {
                let outer=CIImage(color:CIColor(red:cameraStyle.borderColor.r,green:cameraStyle.borderColor.g,blue:cameraStyle.borderColor.b)).cropped(to:target)
                let inner=target.insetBy(dx:cameraStyle.borderWidth,dy:cameraStyle.borderWidth)
                let border=rounded(outer,in:target,radius:min(target.width,target.height)*cameraStyle.roundness/200)
                let innerCamera=rounded(fitted(camera,to:inner,mirror:cameraStyle.mirror),in:inner,radius:min(inner.width,inner.height)*cameraStyle.roundness/200)
                cameraLayer=innerCamera.composited(over:border).cropped(to:target)
            }
            // A floating camera fades while the cursor passes under it, so it never hides what is being clicked.
            if cameraStyle.avoidCursor ?? true,cameraStyle.layout == "Floating",s.showCursor,let p=pointerAt(time,samples:d.samples),p.x >= 0,p.x <= 1,p.y >= 0,p.y <= 1 {
                let point=placement.point(p,current)
                let dx=max(target.minX-point.x,0,point.x-target.maxX),dy=max(target.minY-point.y,0,point.y-target.maxY)
                let u=min(1,hypot(dx,dy)/max(1,target.width*0.35))
                let alpha=0.22+0.78*u*u*(3-2*u)
                if alpha < 0.999 {cameraLayer=opacity(cameraLayer,alpha)}
            }
            if cameraStyle.layout == "Camera Full" {result=cameraLayer.composited(over:backdrop)}
            else {result=cameraLayer.composited(over:result)}
        }
        var final=CIImage(cgImage:d.border).composited(over:result).cropped(to:canvas)
        if d.captionStyle.enabled,let cue=d.captionCues.last(where:{time >= $0.start && time <= $0.end}) {
            let activeWord=cue.words.isEmpty ? nil:max(0,cue.words.lastIndex(where:{time >= $0.start}) ?? 0)
            var overlay=CIImage(cgImage:d.overlays.caption(cue,activeWord:activeWord))
            let entry=max(0,min(1,(time-cue.start)/0.20))
            var scale=d.size.height/1080
            var alpha=1.0
            var slide=0.0
            switch d.captionStyle.animation {
            case "Pop":scale *= 0.72+0.28*(entry*entry*(3-2*entry))
            case "Bounce":scale *= 1+sin(.pi*entry)*0.16
            case "Fade":alpha=entry
            case "Slide":slide = -45*(1-entry)*d.size.height/1080
            default:break
            }
            overlay=overlay.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            if alpha < 0.999 {overlay=opacity(overlay,alpha)}
            let x=(canvas.width-overlay.extent.width)/2
            let baseY=d.captionStyle.position == "Top" ? canvas.height-overlay.extent.height-canvas.height*0.08:d.captionStyle.position == "Center" ? (canvas.height-overlay.extent.height)/2:canvas.height*0.075
            let y=baseY+d.captionStyle.verticalOffset*d.size.height/1080+slide
            overlay=overlay.transformed(by:CGAffineTransform(translationX:x-overlay.extent.minX,y:y-overlay.extent.minY))
            final=overlay.composited(over:final).cropped(to:canvas)
        }
        if d.keyboardStyle.enabled,let shortcut=d.shortcuts.last(where:{time >= $0.time && time <= $0.time+d.keyboardStyle.duration}) {
            var overlay=CIImage(cgImage:d.overlays.shortcut(shortcut))
            let scale=min(1,d.size.width/1920);overlay=overlay.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            if d.keyboardStyle.opacity<0.999 {overlay=opacity(overlay,d.keyboardStyle.opacity)}
            let margin=d.size.width*0.045
            let x=d.keyboardStyle.alignment == "Left" ? margin:d.keyboardStyle.alignment == "Right" ? canvas.width-overlay.extent.width-margin:(canvas.width-overlay.extent.width)/2
            let y=d.keyboardStyle.position == "Top" ? canvas.height-overlay.extent.height-canvas.height*0.06:canvas.height*0.06
            overlay=overlay.transformed(by:CGAffineTransform(translationX:x-overlay.extent.minX,y:y-overlay.extent.minY))
            final=overlay.composited(over:final).cropped(to:canvas)
        }
        if let watermark=d.watermark,d.watermarkRect.width>1 {
            let image=CIImage(cgImage:watermark)
            let scale=min(d.watermarkRect.width/max(1,image.extent.width),d.watermarkRect.height/max(1,image.extent.height))
            var placed=image.transformed(by:CGAffineTransform(scaleX:scale,y:scale))
            placed=placed.transformed(by:CGAffineTransform(translationX:d.watermarkRect.midX-placed.extent.width/2-placed.extent.minX,y:d.watermarkRect.midY-placed.extent.height/2-placed.extent.minY))
            if d.watermarkOpacity<0.999 { placed=opacity(placed,d.watermarkOpacity) }
            final=placed.composited(over:final).cropped(to:canvas)
        }
        if d.progressHeight>=1,d.duration>0 {
            let fraction=max(0,min(1,time/d.duration))
            let height=min(canvas.height/8,d.progressHeight)
            let track=CGRect(x:0,y:0,width:canvas.width,height:height)
            let filled=CGRect(x:0,y:0,width:canvas.width*fraction,height:height)
            let shade=CIImage(color:CIColor(red:0,green:0,blue:0,alpha:0.35)).cropped(to:track)
            final=shade.composited(over:final)
            if filled.width>=1 {
                let bar=CIImage(color:CIColor(red:d.progressColor.r,green:d.progressColor.g,blue:d.progressColor.b)).cropped(to:filled)
                final=bar.composited(over:final)
            }
            final=final.cropped(to:canvas)
        }
        // The fade is applied last, so the background, camera and captions all dip to black together.
        if d.fadeIn>0 || d.fadeOut>0 || !d.dips.isEmpty {
            var look=Look();look.fadeIn=d.fadeIn;look.fadeOut=d.fadeOut
            var level=look.fadeLevel(at:time,duration:d.duration)
            for dip in d.dips {
                // start holds the cut, end holds the whole length of the dip.
                let half=dip.end/2
                guard half>0 else { continue }
                level=min(level,max(0,min(1,abs(time-dip.start)/half)))
            }
            if level<0.999 {
                final=final.applyingFilter("CIColorMatrix",parameters:[
                    "inputRVector":CIVector(x:level,y:0,z:0,w:0),
                    "inputGVector":CIVector(x:0,y:level,z:0,w:0),
                    "inputBVector":CIVector(x:0,y:0,z:level,w:0)]).cropped(to:canvas)
            }
        }
        return final
    }
}
