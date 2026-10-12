import SwiftUI
import AVKit
import CoreImage

struct RGB: Codable, Equatable {
    var r: Double; var g: Double; var b: Double
    init(r:Double,g:Double,b:Double){self.r=r;self.g=g;self.b=b}
    init(_ hex: UInt32) { r = Double((hex >> 16) & 255) / 255; g = Double((hex >> 8) & 255) / 255; b = Double(hex & 255) / 255 }
    init(_ color: Color) { let c = NSColor(color).usingColorSpace(.sRGB) ?? .white; r = c.redComponent; g = c.greenComponent; b = c.blueComponent }
    var ns: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    var color: Color { Color(nsColor: ns) }
    func normalized()->RGB {RGB(r:max(0,min(1,r.isFinite ? r:1)),g:max(0,min(1,g.isFinite ? g:1)),b:max(0,min(1,b.isFinite ? b:1)))}
}
struct VideoStyle: Codable, Equatable {
    var scale = 1.0
    var x = 0.0
    var y = 0.0
    var opacity = 1.0
    var frame = "None"
    var frameColor = RGB(0x17181C)
    /// What the browser frame shows in its address bar, or the macOS window frame in its title bar.
    var frameTitle: String? = nil
    /// Crop insets as fractions of the source width or height.
    var cropLeft: Double? = nil
    var cropTop: Double? = nil
    var cropRight: Double? = nil
    var cropBottom: Double? = nil
    /// Visible part of the source in unit coordinates with a top-left origin; at least 10% remains on each axis.
    var cropRect: CGRect {
        func inset(_ value:Double?,limit:Double)->Double { let v=value ?? 0; return max(0,min(limit,v.isFinite ? v:0)) }
        let left=inset(cropLeft,limit:0.9),top=inset(cropTop,limit:0.9)
        let right=inset(cropRight,limit:0.9-left),bottom=inset(cropBottom,limit:0.9-top)
        return CGRect(x:left,y:top,width:1-left-right,height:1-top-bottom)
    }
    func normalized()->VideoStyle {
        var value=self
        let crop=cropRect
        value.cropLeft=crop.minX;value.cropTop=crop.minY;value.cropRight=1-crop.maxX;value.cropBottom=1-crop.maxY
        if crop == CGRect(x:0,y:0,width:1,height:1) {value.cropLeft=nil;value.cropTop=nil;value.cropRight=nil;value.cropBottom=nil}
        value.scale=max(0.5,min(2,value.scale.isFinite ? value.scale:1));value.x=max(-1,min(1,value.x.isFinite ? value.x:0));value.y=max(-1,min(1,value.y.isFinite ? value.y:0));value.opacity=max(0,min(1,value.opacity.isFinite ? value.opacity:1))
        if !["None","macOS Window","Browser","iPhone","iPad"].contains(value.frame){value.frame="None"}
        let title=(value.frameTitle ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
        value.frameTitle=title.isEmpty ? nil:String(title.prefix(120))
        value.frameColor=value.frameColor.normalized();return value
    }
}
struct Look: Codable, Equatable {
    var mode = "Gradient"
    var first = RGB(0x40308E)
    var second = RGB(0xEAA391)
    var angle = 35.0
    var pattern = "None"
    var patternOpacity = 12.0
    /// Darkening towards the corners, 0…100.
    var vignette: Double? = nil
    /// Film-like grain over the background, 0…100.
    var grain: Double? = nil
    var resolvedVignette: Double { let value=vignette ?? 0;return value.isFinite ? max(0,min(100,value)):0 }
    var resolvedGrain: Double { let value=grain ?? 0;return value.isFinite ? max(0,min(100,value)):0 }
    var imagePath: String?
    var blur = 0.0
    var dim = 0.0
    var padding = 9.0
    var radius = 18.0
    var shadow = 45.0
    var shadowBlur = 36.0
    var shadowY = 18.0
    var glow = 0.0
    var glowBlur = 45.0
    var glowColor = RGB(0xA18AFF)
    var border = 0.0
    var borderColor = RGB(0xFFFFFF)
    var aspect = "16:9"
    var exportHeight = 1080
    var videoStyle: VideoStyle? = VideoStyle()
    /// Fill the canvas with the video and pan to follow the pointer (for vertical or square output).
    var autoReframe: Bool? = nil
    /// Leaves the background out so the finished video can sit on top of something else.
    var transparentBackground: Bool? = nil
    var isTransparent: Bool { transparentBackground ?? false }
    /// A logo drawn over the finished video: file, corner, size as a percentage of the canvas width, and opacity.
    var watermarkPath: String? = nil
    var watermarkPosition: String? = nil
    var watermarkSize: Double? = nil
    var watermarkOpacity: Double? = nil
    var resolvedWatermarkPosition: String { let value=watermarkPosition ?? "Bottom Right";return ["Top Left","Top Right","Bottom Left","Bottom Right"].contains(value) ? value:"Bottom Right" }
    var resolvedWatermarkSize: Double { let value=watermarkSize ?? 12;return value.isFinite ? max(3,min(40,value)):12 }
    var resolvedWatermarkOpacity: Double { let value=watermarkOpacity ?? 85;return value.isFinite ? max(5,min(100,value)):85 }
    /// A name in a corner of every frame: the handle people should look up, without needing a logo file.
    var handleText: String? = nil
    var handlePosition: String? = nil
    var handleSize: Double? = nil
    var handleOpacity: Double? = nil
    var handleColor: RGB? = nil
    var resolvedHandleText: String { String((handleText ?? "").trimmingCharacters(in:.whitespacesAndNewlines).prefix(60)) }
    var resolvedHandlePosition: String { let value=handlePosition ?? "Bottom Left";return ["Top Left","Top Right","Bottom Left","Bottom Right"].contains(value) ? value:"Bottom Left" }
    var resolvedHandleSize: Double { let value=handleSize ?? 3.2;return value.isFinite ? max(1.4,min(9,value)):3.2 }
    var resolvedHandleOpacity: Double { let value=handleOpacity ?? 80;return value.isFinite ? max(5,min(100,value)):80 }
    var resolvedHandleColor: RGB { (handleColor ?? RGB(0xFFFFFF)).normalized() }
    /// A bar across the bottom that fills as the video plays: its height in pixels at 1080p, 0 for none.
    var progressBar: Double? = nil
    var progressColor: RGB? = nil
    var resolvedProgressBar: Double { let value=progressBar ?? 0;return value.isFinite ? max(0,min(40,value)):0 }
    var resolvedProgressColor: RGB { (progressColor ?? RGB(0xBFEE63)).normalized() }
    /// Seconds of fade from and to black at the two ends of the finished video, picture and sound together.
    var fadeIn: Double? = nil
    var fadeOut: Double? = nil
    var resolvedFadeIn: Double { let value=fadeIn ?? 0;return value.isFinite ? max(0,min(5,value)):0 }
    var resolvedFadeOut: Double { let value=fadeOut ?? 0;return value.isFinite ? max(0,min(5,value)):0 }
    /// How much of the picture is shown at a time, 0 while it is still black.
    func fadeLevel(at time:Double,duration:Double)->Double {
        guard duration>0 else { return 1 }
        let opening=resolvedFadeIn,closing=resolvedFadeOut
        var level=1.0
        if opening>0 { level=min(level,max(0,time)/opening) }
        if closing>0 { level=min(level,max(0,duration-time)/closing) }
        return max(0,min(1,level))
    }
    /// Aspect of the visible video after cropping.
    func contentAspect(media:Double)->Double {
        let crop=(videoStyle ?? VideoStyle()).cropRect
        return max(0.05,media*crop.width/crop.height)
    }
    /// Aspect of the video frame on the canvas: the cropped video, or the whole padded canvas when auto reframe fills it.
    func frameAspect(media:Double,canvas size:CGSize)->Double {
        guard autoReframe ?? false else { return contentAspect(media:media) }
        let inset=min(size.width,size.height)*padding/100
        return max(0.05,(size.width-inset*2)/max(1,size.height-inset*2))
    }
    var canvas: CGSize {
        let ratios: [String: Double] = ["16:9": 16/9, "9:16": 9/16, "1:1": 1, "4:3": 4/3, "4:5": 4/5]
        let h = Double(exportHeight)
        return CGSize(width: (h * (ratios[aspect] ?? 16/9) / 2).rounded() * 2, height: h)
    }
    func videoRect(in canvas: CGSize, aspect: Double) -> CGRect {
        let inset = min(canvas.width, canvas.height) * padding / 100
        let width = min(canvas.width - inset * 2, (canvas.height - inset * 2) * aspect)
        return CGRect(x: (canvas.width - width)/2, y: (canvas.height - width/aspect)/2, width: width, height: width/aspect)
    }
    var backgroundKey: String { "\(mode)|\(first)|\(second)|\(angle)|\(pattern)|\(patternOpacity)|\(imagePath ?? "")|\(blur)|\(dim)|\(aspect)|\(resolvedVignette)|\(resolvedGrain)" }
    func normalized() -> Look {
        var value=self
        value.mode=["gradyan":"Gradient","radyal":"Radial","aurora":"Aurora","düz renk":"Color","görsel":"Image"][mode] ?? mode
        value.pattern=["yok":"None","noktalar":"Dots","ızgara":"Grid","çizgiler":"Lines"][pattern] ?? pattern
        if !["Gradient","Radial","Aurora","Mesh","Color","Image"].contains(value.mode){value.mode="Gradient"}
        if !["None","Dots","Grid","Lines","Waves"].contains(value.pattern){value.pattern="None"}
        value.vignette=value.resolvedVignette>0 ? value.resolvedVignette:nil
        value.grain=value.resolvedGrain>0 ? value.resolvedGrain:nil
        if let path=value.imagePath,!FileManager.default.fileExists(atPath:path){value.imagePath=nil}
        if value.mode=="Image",value.imagePath==nil{value.mode="Gradient"}
        value.first=value.first.normalized();value.second=value.second.normalized();value.glowColor=value.glowColor.normalized();value.borderColor=value.borderColor.normalized()
        value.angle=max(0,min(360,value.angle.isFinite ? value.angle:35));value.patternOpacity=max(0,min(60,value.patternOpacity.isFinite ? value.patternOpacity:12));value.blur=max(0,min(80,value.blur.isFinite ? value.blur:0));value.dim=max(0,min(85,value.dim.isFinite ? value.dim:0))
        value.padding=max(0,min(35,value.padding.isFinite ? value.padding:9));value.radius=max(0,min(80,value.radius.isFinite ? value.radius:18));value.shadow=max(0,min(100,value.shadow.isFinite ? value.shadow:45));value.shadowBlur=max(0,min(100,value.shadowBlur.isFinite ? value.shadowBlur:36));value.shadowY=max(-60,min(60,value.shadowY.isFinite ? value.shadowY:18))
        value.fadeIn=value.resolvedFadeIn>0 ? value.resolvedFadeIn:nil;value.fadeOut=value.resolvedFadeOut>0 ? value.resolvedFadeOut:nil
        if let path=value.watermarkPath,!FileManager.default.fileExists(atPath:path) { value.watermarkPath=nil }
        if value.watermarkPath == nil { value.watermarkPosition=nil;value.watermarkSize=nil;value.watermarkOpacity=nil }
        else { value.watermarkPosition=value.resolvedWatermarkPosition;value.watermarkSize=value.resolvedWatermarkSize;value.watermarkOpacity=value.resolvedWatermarkOpacity }
        value.glow=max(0,min(100,value.glow.isFinite ? value.glow:0));value.glowBlur=max(1,min(120,value.glowBlur.isFinite ? value.glowBlur:45));value.border=max(0,min(10,value.border.isFinite ? value.border:0))
        if !["16:9","9:16","1:1","4:3","4:5"].contains(value.aspect){value.aspect="16:9"};if ![720,1080,1440,2160].contains(value.exportHeight){value.exportHeight=1080}
        // The bar, the handle and the transparent background are only written back when they are in use,
        // so an untouched look still compares equal to a fresh one.
        value.progressBar=value.resolvedProgressBar>0 ? value.resolvedProgressBar:nil
        if value.progressBar == nil { value.progressColor=nil } else { value.progressColor=value.resolvedProgressColor }
        if value.resolvedHandleText.isEmpty { value.handleText=nil;value.handlePosition=nil;value.handleSize=nil;value.handleOpacity=nil;value.handleColor=nil }
        else {
            value.handleText=value.resolvedHandleText;value.handlePosition=value.resolvedHandlePosition
            value.handleSize=value.resolvedHandleSize;value.handleOpacity=value.resolvedHandleOpacity;value.handleColor=value.resolvedHandleColor
        }
        value.videoStyle=(value.videoStyle ?? VideoStyle()).normalized()
        return value
    }
}
/// Where video content sits inside its canvas frame for a zoom pose. Shared by the renderer and the preview's zoom targeting.
struct VideoPlacement {
    /// The video frame on the canvas (bottom-left origin).
    var rect:CGRect
    /// Content size at pose scale 1, after crop, fit or cover, and the Video Transform scale.
    var contentSize:CGSize
    /// Video Transform offset.
    var shift:CGPoint
    func origin(_ pose:ZoomPose)->CGPoint {
        let offset=pose.placement(viewWidth:rect.width,viewHeight:rect.height,contentWidth:contentSize.width,contentHeight:contentSize.height,flipped:true)
        return CGPoint(x:rect.minX+offset.x+shift.x,y:rect.minY+offset.y+shift.y)
    }
    /// Canvas position of a normalized pointer sample (top-left origin) for a pose.
    func point(_ sample:PointerSample,_ pose:ZoomPose)->CGPoint {
        let o=origin(pose)
        return CGPoint(x:o.x+sample.x*contentSize.width*pose.scale,y:o.y+(1-sample.y)*contentSize.height*pose.scale)
    }
    /// Visible source width and height at this zoom, including vertical reframing.
    func followSize(zoom:Double)->CGSize {
        CGSize(width:min(1,rect.width/max(1,contentSize.width*max(1,zoom))),height:min(1,rect.height/max(1,contentSize.height*max(1,zoom))))
    }
    /// Visible fraction of the content, used to size the pointer-follow dead zone.
    func followFraction(zoom:Double,reframe:Bool)->Double {
        let zoomed=1/max(1,zoom)
        guard reframe else { return zoomed }
        return min(zoomed,rect.width/max(1,contentSize.width),rect.height/max(1,contentSize.height))
    }
}
func videoPlacement(look:Look,canvas:CGSize,mediaAspect:Double)->VideoPlacement {
    let style=look.videoStyle ?? VideoStyle()
    let rect=look.videoRect(in:canvas,aspect:look.frameAspect(media:mediaAspect,canvas:canvas))
    let aspect=look.contentAspect(media:mediaAspect)
    // Fit and cover are the same when the frame already has the content's aspect; auto reframe covers the taller or wider frame.
    var width=rect.width,height=rect.width/aspect
    if height<rect.height { height=rect.height;width=height*aspect }
    let scale=max(0.25,style.scale)
    return VideoPlacement(rect:rect,contentSize:CGSize(width:width*scale,height:height*scale),shift:CGPoint(x:style.x*rect.width*0.5,y:style.y*rect.height*0.5))
}
/// Converts a top-left crop rectangle to Core Animation's contentsRect, whose origin is at the bottom left on macOS.
func layerContentsRect(_ crop:CGRect)->CGRect { CGRect(x:crop.minX,y:1-crop.maxY,width:crop.width,height:crop.height) }

struct LookPreset: Identifiable {
    var id: String; var a: UInt32; var b: UInt32
}
let lookPresets = [
    LookPreset(id: "Twilight", a: 0x40308E, b: 0xEAA391), .init(id: "Aurora", a: 0x092C4A, b: 0x6AE7AC),
    .init(id: "Lavender", a: 0x302257, b: 0xBB9FF5), .init(id: "Ocean", a: 0x063B78, b: 0x5CDBED),
    .init(id: "Sunset", a: 0x9A253E, b: 0xFFC680), .init(id: "Ember", a: 0x311026, b: 0xF35334),
    .init(id: "Forest", a: 0x073C31, b: 0x98BD73), .init(id: "Ice", a: 0x7788AC, b: 0xDBF6FC),
    .init(id: "Night", a: 0x060811, b: 0x353C5D), .init(id: "Graphite", a: 0x141417, b: 0x535359),
    .init(id: "Pearl", a: 0xB6BFCB, b: 0xF9F8F5), .init(id: "Candy", a: 0xFFAAC6, b: 0xACA4F9),
    .init(id: "Lime", a: 0x254438, b: 0xD2ED6B), .init(id: "Cobalt", a: 0x171975, b: 0x5D88FF),
    .init(id: "Copper", a: 0x492724, b: 0xD7A37B), .init(id: "Orchid", a: 0x57245B, b: 0xE57FBC),
    .init(id: "Lagoon", a: 0x076A76, b: 0x94EDDD), .init(id: "Sand", a: 0x89684F, b: 0xE9D6AC),
    .init(id: "Mint", a: 0x0D3B33, b: 0x7FE3C0), .init(id: "Peach", a: 0xC2502F, b: 0xFFD9B0),
    .init(id: "Indigo", a: 0x1A1B3A, b: 0x6C63FF), .init(id: "Rose", a: 0x6B1030, b: 0xFF9BB3),
    .init(id: "Slate", a: 0x1F2933, b: 0x7B8794), .init(id: "Butter", a: 0x7A5C10, b: 0xFFE28A),
    .init(id: "Teal", a: 0x04343C, b: 0x37B7C3), .init(id: "Plum", a: 0x2B1036, b: 0xA166C9),
    .init(id: "Coral", a: 0x8C2F39, b: 0xFF8A6B), .init(id: "Steel", a: 0x121A24, b: 0x4A6FA5),
    .init(id: "Moss", a: 0x1E2B16, b: 0x8FA86A), .init(id: "Blush", a: 0xA65D7A, b: 0xFFE1E6),
    .init(id: "Cocoa", a: 0x2B1C15, b: 0xC08457), .init(id: "Sky", a: 0x0B4F8A, b: 0xBFE6FF),
    .init(id: "Neon", a: 0x0A0A12, b: 0x39FF88), .init(id: "Clay", a: 0x5C3A2E, b: 0xE8B49A),
    .init(id: "Fog", a: 0x5A6472, b: 0xE7ECF1), .init(id: "Violet", a: 0x2A0E4F, b: 0xC77DFF),
    .init(id: "Amber", a: 0x6B3A05, b: 0xFFC247), .init(id: "Pine", a: 0x04251E, b: 0x3F8F6B)
]

/// A ready-made background: colours, texture and finishing set together, the way a template would.
struct BackgroundStyle: Identifiable {
    var id: String
    var mode: String
    var first: UInt32
    var second: UInt32
    var pattern: String = "None"
    var patternOpacity: Double = 12
    var vignette: Double = 0
    var grain: Double = 0
    var blur: Double = 0
    var dim: Double = 0
    func applied(to look: Look) -> Look {
        var value = look
        value.mode = mode; value.first = RGB(first); value.second = RGB(second)
        value.pattern = pattern; value.patternOpacity = patternOpacity
        value.vignette = vignette > 0 ? vignette : nil
        value.grain = grain > 0 ? grain : nil
        value.blur = blur; value.dim = dim
        if mode != "Image" { value.imagePath = nil }
        return value.normalized()
    }
}

let backgroundStyles: [BackgroundStyle] = [
    BackgroundStyle(id:"Studio Mesh",mode:"Mesh",first:0x40308E,second:0xEAA391,vignette:32,grain:8),
    BackgroundStyle(id:"Soft Grid",mode:"Gradient",first:0x060811,second:0x353C5D,pattern:"Grid",patternOpacity:14,vignette:26),
    BackgroundStyle(id:"Paper",mode:"Color",first:0xF2EFE9,second:0xF2EFE9,vignette:16,grain:24),
    BackgroundStyle(id:"Neon Night",mode:"Mesh",first:0x0A0A12,second:0x39FF88,vignette:52,grain:12),
    BackgroundStyle(id:"Warm Film",mode:"Gradient",first:0x492724,second:0xD7A37B,vignette:38,grain:30),
    BackgroundStyle(id:"Clean",mode:"Color",first:0x0E0F13,second:0x0E0F13),
    BackgroundStyle(id:"Ripple",mode:"Radial",first:0x04343C,second:0x37B7C3,pattern:"Waves",patternOpacity:22,vignette:20),
    BackgroundStyle(id:"Daylight",mode:"Gradient",first:0xBFE6FF,second:0xF9F8F5,pattern:"Dots",patternOpacity:10)
]

/// Five related colors for a mesh background: the two chosen ones plus hues rotated between them.
@MainActor func meshColors(first:NSColor,second:NSColor)->[NSColor] {
    let a=first.usingColorSpace(.sRGB) ?? first,b=second.usingColorSpace(.sRGB) ?? second
    func rotated(_ color:NSColor,by degrees:Double,brightness:Double)->NSColor {
        var hue:CGFloat=0,saturation:CGFloat=0,value:CGFloat=0,alpha:CGFloat=0
        color.getHue(&hue,saturation:&saturation,brightness:&value,alpha:&alpha)
        return NSColor(hue:(hue+degrees/360).truncatingRemainder(dividingBy:1),saturation:min(1,saturation*1.05),brightness:max(0.12,min(1,value*brightness)),alpha:alpha)
    }
    return [a,b,rotated(a,by:28,brightness:1.15),rotated(b,by:-24,brightness:0.9),rotated(a,by:-40,brightness:1.05)]
}

/// Draws a handle as light text with a soft shadow behind it, so it reads on a bright screen as well as a dark one.
func handleArtwork(_ text:String,fontSize:Double,color:RGB)->CGImage? {
    guard !text.isEmpty,fontSize>=4 else { return nil }
    let font=NSFont.systemFont(ofSize:fontSize,weight:.semibold)
    let measured=(text as NSString).size(withAttributes:[.font:font])
    let pad=fontSize*0.6
    let width=Int((measured.width+pad*2).rounded(.up)),height=Int((measured.height+pad*2).rounded(.up))
    guard width>1,height>1,width<8192,height<8192,
          let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    let graphics=NSGraphicsContext(cgContext:context,flipped:false)
    NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics
    context.setShadow(offset:CGSize(width:0,height:-fontSize*0.06),blur:fontSize*0.35,color:NSColor.black.withAlphaComponent(0.55).cgColor)
    (text as NSString).draw(at:CGPoint(x:pad,y:pad),withAttributes:[.font:font,.foregroundColor:color.ns])
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()
}

@MainActor final class BackgroundRenderer {
    static let shared = BackgroundRenderer()
    private var key = ""
    private var cached: CGImage?
    func image(_ look: Look, size: CGSize) -> CGImage? {
        let nextKey = look.backgroundKey + "\(size)"
        if key == nextKey, let cached { return cached }
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = CGRect(origin: .zero, size: size)
        look.first.ns.setFill(); rect.fill()
        if ["Image","görsel"].contains(look.mode), let path = look.imagePath, let photo = NSImage(contentsOfFile: path), photo.size.width > 0, photo.size.height > 0 {
            let scale = max(size.width/photo.size.width, size.height/photo.size.height)
            photo.draw(in: CGRect(x: (size.width-photo.size.width*scale)/2, y: (size.height-photo.size.height*scale)/2, width: photo.size.width*scale, height: photo.size.height*scale))
        } else if look.mode == "Mesh" {
            // Soft blobs of related colors, the way modern wallpapers blend several hues into one another.
            let palette=meshColors(first:look.first.ns,second:look.second.ns)
            let spots=[CGPoint(x:0.18,y:0.78),CGPoint(x:0.82,y:0.72),CGPoint(x:0.3,y:0.22),CGPoint(x:0.74,y:0.24),CGPoint(x:0.5,y:0.55)]
            for (index,spot) in spots.enumerated() {
                let color=palette[index % palette.count]
                let center=NSPoint(x:size.width*spot.x,y:size.height*spot.y)
                let radius=max(size.width,size.height)*(index == 4 ? 0.42:0.55)
                let blob=NSGradient(starting:color.withAlphaComponent(index == 4 ? 0.55:0.85),ending:color.withAlphaComponent(0))!
                blob.draw(fromCenter:center,radius:0,toCenter:center,radius:radius,options:[])
            }
        } else if !["Color","düz renk"].contains(look.mode) {
            let gradient = NSGradient(starting: look.first.ns, ending: look.second.ns)!
            if ["Radial","radyal"].contains(look.mode) { gradient.draw(in: rect, relativeCenterPosition: NSPoint(x: -0.45, y: 0.4)) }
            else { gradient.draw(in: rect, angle: look.angle) }
            if ["Aurora","aurora"].contains(look.mode) {
                let glow = NSGradient(starting: look.second.ns.withAlphaComponent(0.8), ending: look.second.ns.withAlphaComponent(0))!
                glow.draw(fromCenter: NSPoint(x: size.width*0.72, y: size.height*0.7), radius: 0, toCenter: NSPoint(x: size.width*0.72, y: size.height*0.7), radius: size.width*0.65, options: [])
            }
        }
        if !["None","yok"].contains(look.pattern) {
            NSColor.white.withAlphaComponent(look.patternOpacity/100).setStroke()
            NSColor.white.withAlphaComponent(look.patternOpacity/100).setFill()
            let step = max(12, size.width/42)
            let path = NSBezierPath(); path.lineWidth = max(0.6, size.width/1920)
            for x in stride(from: 0.0, through: size.width + size.height, by: step) {
                if ["Lines","çizgiler"].contains(look.pattern) { path.move(to: NSPoint(x:x, y:0)); path.line(to:NSPoint(x:x-size.height, y:size.height)) }
                else if ["Grid","ızgara"].contains(look.pattern) { path.move(to:NSPoint(x:x,y:0)); path.line(to:NSPoint(x:x,y:size.height)) }
                else if look.pattern == "Waves" {
                    let wave=NSBezierPath();wave.lineWidth=max(0.8,size.width/1200)
                    let amplitude=step*0.55,y0=x.truncatingRemainder(dividingBy:size.height)
                    wave.move(to:NSPoint(x:0,y:y0))
                    for px in stride(from:0.0,through:size.width,by:max(4,size.width/240)) {
                        wave.line(to:NSPoint(x:px,y:y0+sin(px/size.width*6*Double.pi+x/step)*amplitude))
                    }
                    wave.stroke()
                }
                else { for y in stride(from: 0.0, through: size.height, by: step) { NSBezierPath(ovalIn: CGRect(x:x,y:y,width:max(1.5,size.width/700),height:max(1.5,size.width/700))).fill() } }
            }
            if ["Grid","ızgara"].contains(look.pattern) { for y in stride(from: 0.0, through: size.height, by: step) { path.move(to:NSPoint(x:0,y:y)); path.line(to:NSPoint(x:size.width,y:y)) } }
            path.stroke()
        }
        NSColor.black.withAlphaComponent(look.dim/100).setFill(); rect.fill(using:.sourceOver)
        img.unlockFocus()
        var imageRect = rect
        var result = img.cgImage(forProposedRect:&imageRect,context:nil,hints:nil)
        if look.blur > 0, let original = result {
            let ci = CIImage(cgImage: original)
            let blurred = ci.clampedToExtent().applyingFilter("CIGaussianBlur", parameters:[kCIInputRadiusKey:look.blur*size.width/1920]).cropped(to:ci.extent)
            result = CIContext().createCGImage(blurred, from:ci.extent)
        }
        if look.resolvedVignette > 0 || look.resolvedGrain > 0, let original = result {
            var ci = CIImage(cgImage: original)
            if look.resolvedVignette > 0 {
                ci = ci.applyingFilter("CIVignetteEffect",parameters:[
                    kCIInputCenterKey:CIVector(x:size.width/2,y:size.height/2),
                    kCIInputRadiusKey:max(size.width,size.height)*0.62,
                    kCIInputIntensityKey:look.resolvedVignette/100*1.6,
                    "inputFalloff":0.5]).cropped(to:ci.extent)
            }
            if look.resolvedGrain > 0,let noise=CIFilter(name:"CIRandomGenerator")?.outputImage {
                let grey=noise.applyingFilter("CIColorControls",parameters:[kCIInputSaturationKey:0,kCIInputBrightnessKey:0,kCIInputContrastKey:1])
                    .cropped(to:ci.extent)
                    .applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:look.resolvedGrain/100*0.35)])
                ci = grey.composited(over:ci).cropped(to:ci.extent)
            }
            result = CIContext().createCGImage(ci,from:ci.extent)
        }
        key = nextKey; cached = result; return result
    }
}

@MainActor func decorationLayers(look: Look, size: CGSize, mediaAspect: Double) -> (CALayer, CGRect) {
    let root = CALayer(); root.frame = CGRect(origin:.zero,size:size); root.masksToBounds = true
    let background = CALayer(); background.frame = root.bounds; background.contents = BackgroundRenderer.shared.image(look,size:size); root.addSublayer(background)
    let rect = look.videoRect(in:size,aspect:mediaAspect)
    let factor = min(size.width,size.height)/800
    let corner = look.radius*factor
    let shade = CALayer(); shade.frame = rect; shade.cornerRadius = corner; shade.backgroundColor = NSColor.black.cgColor
    shade.shadowColor = NSColor.black.cgColor; shade.shadowOpacity = Float(look.shadow/100); shade.shadowRadius = look.shadowBlur*factor; shade.shadowOffset = CGSize(width:0,height:-look.shadowY*factor); root.addSublayer(shade)
    if look.glow > 0 {
        let glow = CALayer(); glow.frame = rect; glow.cornerRadius = corner; glow.backgroundColor = look.glowColor.ns.cgColor
        glow.shadowColor = look.glowColor.ns.cgColor; glow.shadowOpacity = Float(look.glow/100); glow.shadowRadius = look.glowBlur*factor; glow.shadowOffset = .zero; root.addSublayer(glow)
    }
    return (root,rect)
}
/// A line of text inside a frame's chrome, drawn at the render size so it stays sharp in the export.
@MainActor private func chromeText(_ string:String,frame:CGRect,size:Double,color:NSColor,centered:Bool)->CATextLayer {
    let text=CATextLayer()
    text.string=string
    text.font=NSFont.systemFont(ofSize:size,weight:.medium)
    text.fontSize=size
    text.foregroundColor=color.cgColor
    text.alignmentMode=centered ? .center: .left
    text.truncationMode = .middle
    text.isWrapped=false
    text.contentsScale=1
    text.frame=frame
    return text
}

@MainActor func borderLayer(look: Look, rect: CGRect, size: CGSize) -> CALayer {
    let layer = CALayer(); layer.frame = rect; layer.cornerRadius = look.radius*min(size.width,size.height)/800
    // Without this the window and browser bars keep their square top corners while the video below is rounded.
    layer.masksToBounds = true
    layer.borderWidth = look.border*min(size.width,size.height)/800; layer.borderColor = look.borderColor.ns.cgColor
    let style=look.videoStyle ?? VideoStyle()
    let unit=min(size.width,size.height)/800
    if style.frame == "macOS Window" || style.frame == "Browser" {
        let bar=CALayer();bar.frame=CGRect(x:0,y:rect.height-34*unit,width:rect.width,height:34*unit);bar.backgroundColor=style.frameColor.ns.cgColor
        layer.addSublayer(bar)
        for (i,color) in [NSColor.systemRed,NSColor.systemYellow,NSColor.systemGreen].enumerated() {
            let dot=CALayer();dot.frame=CGRect(x:(13+Double(i)*18)*unit,y:11*unit,width:10*unit,height:10*unit);dot.cornerRadius=5*unit;dot.backgroundColor=color.cgColor;bar.addSublayer(dot)
        }
        if style.frame == "Browser" {
            let address=CALayer();address.frame=CGRect(x:78*unit,y:8*unit,width:max(30,rect.width-96*unit),height:18*unit);address.cornerRadius=9*unit;address.backgroundColor=NSColor.white.withAlphaComponent(0.11).cgColor;bar.addSublayer(address)
            if let title=style.frameTitle,!title.isEmpty {
                let inset=10*unit,fontSize=11*unit
                address.addSublayer(chromeText(title,frame:CGRect(x:inset,y:(address.frame.height-fontSize*1.3)/2,width:max(10,address.frame.width-inset*2),height:fontSize*1.3),size:fontSize,color:NSColor.white.withAlphaComponent(0.75),centered:false))
            }
        } else if let title=style.frameTitle,!title.isEmpty {
            let fontSize=12*unit
            bar.addSublayer(chromeText(title,frame:CGRect(x:78*unit,y:(bar.frame.height-fontSize*1.3)/2,width:max(10,rect.width-156*unit),height:fontSize*1.3),size:fontSize,color:NSColor.white.withAlphaComponent(0.7),centered:true))
        }
    } else if style.frame == "iPhone" || style.frame == "iPad" {
        layer.borderWidth=max(layer.borderWidth,style.frame == "iPhone" ? 12*unit:9*unit);layer.borderColor=style.frameColor.ns.cgColor
        let camera=CALayer()
        if style.frame == "iPhone" {camera.frame=CGRect(x:rect.width/2-35*unit,y:rect.height-20*unit,width:70*unit,height:13*unit);camera.cornerRadius=7*unit}
        else {camera.frame=CGRect(x:rect.width/2-3*unit,y:rect.height-8*unit,width:6*unit,height:6*unit);camera.cornerRadius=3*unit}
        camera.backgroundColor=NSColor.black.cgColor;layer.addSublayer(camera)
    }
    return layer
}

@MainActor final class CanvasView:NSView {
    let playerLayer=AVPlayerLayer()
    var studio:Studio?
    override init(frame:NSRect) { super.init(frame:frame);wantsLayer=true;layer=CALayer();layer?.addSublayer(playerLayer) }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() { super.layout();refresh() }
    let annotationOutline=CAShapeLayer()
    /// The annotation being placed with the mouse: its state when the drag began, where it began, and whether it is being moved or drawn.
    private var annotationDrag:(original:Annotation,anchor:CGPoint,moving:Bool)?
    /// Placement and zoom pose of the frame shown at the playhead, as the renderer computes them.
    func currentPose()->(VideoPlacement,ZoomPose)? {
        guard let studio else { return nil }
        let placement=videoPlacement(look:studio.look,canvas:bounds.size,mediaAspect:studio.mediaAspect)
        let reframe=studio.look.autoReframe ?? false
        let scale=max(studio.motion.zoom,studio.zooms.filter{$0.follow == true}.map(\.scale).max() ?? 1)
        let paths=studio.motionPaths(viewport:placement.followSize(zoom:scale))
        let follow=paths.camera
        var pose=motionPose(at:studio.position,manual:studio.zooms,auto:paths.automatic,samples:follow,settings:studio.motion)
        if reframe { pose=reframedPose(pose,follow:pointerAt(studio.position,samples:follow)) }
        return (placement,pose)
    }
    /// Top-left unit coordinates in the video for a point in this view.
    func videoPoint(_ event:NSEvent,_ placement:VideoPlacement,_ pose:ZoomPose)->CGPoint {
        let p=convert(event.locationInWindow,from:nil),origin=placement.origin(pose)
        return CGPoint(x:(p.x-origin.x)/(placement.contentSize.width*pose.scale),y:1-(p.y-origin.y)/(placement.contentSize.height*pose.scale))
    }
    override func mouseDown(with event:NSEvent) {
        guard let studio,let (placement,pose)=currentPose() else { return }
        guard placement.rect.contains(convert(event.locationInWindow,from:nil)) else { return }
        let point=videoPoint(event,placement,pose)
        if studio.annotationEditing,studio.stillImage == nil {
            if studio.selectedAnnotationIndex == nil { studio.addAnnotation("Arrow") }
            guard let i=studio.selectedAnnotationIndex else { return }
            let item=studio.annotations[i]
            let inside=item.kind != "Arrow" && item.rect.insetBy(dx:-0.01,dy:-0.01).contains(point)
            annotationDrag=(item,point,inside)
            return
        }
        guard let i=studio.zooms.firstIndex(where:{$0.id == studio.selectedZoom}) else { return }
        studio.zooms[i].follow=false
        studio.zooms[i].x=min(1,max(0,point.x))
        studio.zooms[i].y=min(1,max(0,point.y))
    }
    override func mouseDragged(with event:NSEvent) {
        guard let studio,let drag=annotationDrag,studio.annotations.contains(where:{$0.id == drag.original.id}),let (placement,pose)=currentPose() else { return }
        let point=videoPoint(event,placement,pose)
        var item=drag.original
        if drag.moving { item.x+=point.x-drag.anchor.x;item.y+=point.y-drag.anchor.y }
        else { item.x=drag.anchor.x;item.y=drag.anchor.y;item.width=point.x-drag.anchor.x;item.height=point.y-drag.anchor.y }
        studio.update(\.annotations,id:item.id) { $0=item }
    }
    override func mouseUp(with event:NSEvent) {
        guard let studio,let drag=annotationDrag else { return }
        annotationDrag=nil
        guard var item=studio.annotations.first(where:{$0.id == drag.original.id}) else { return }
        if !drag.moving && hypot(item.width,item.height)<0.012 {
            // A click without a drag moves the annotation there at its previous size.
            item=drag.original
            if item.kind == "Arrow" { item.x=drag.anchor.x-item.width;item.y=drag.anchor.y-item.height }
            else { item.x=drag.anchor.x-abs(item.width)/2;item.y=drag.anchor.y-abs(item.height)/2;item.width=abs(item.width);item.height=abs(item.height) }
        } else if item.kind != "Arrow" {
            let rect=item.rect;item.x=rect.minX;item.y=rect.minY;item.width=rect.width;item.height=rect.height
        }
        studio.update(\.annotations,id:item.id) { $0=item }
    }
    /// A dashed outline shows the selected annotation right away; the rendered preview follows once it is rebuilt.
    func updateAnnotationOutline() {
        guard let studio,studio.annotationEditing,let item=studio.annotations.first(where:{$0.id == studio.selectedAnnotation}),let (placement,pose)=currentPose() else { annotationOutline.path=nil;return }
        let origin=placement.origin(pose)
        func view(_ x:Double,_ y:Double)->CGPoint { CGPoint(x:origin.x+x*placement.contentSize.width*pose.scale,y:origin.y+(1-y)*placement.contentSize.height*pose.scale) }
        let path=CGMutablePath()
        if item.kind == "Arrow" { path.move(to:view(item.x,item.y));path.addLine(to:view(item.x+item.width,item.y+item.height));path.addEllipse(in:CGRect(origin:view(item.x+item.width,item.y+item.height),size:.zero).insetBy(dx:-5,dy:-5)) }
        else { let r=item.rect,a=view(r.minX,r.maxY),b=view(r.maxX,r.minY);path.addRect(CGRect(x:a.x,y:a.y,width:b.x-a.x,height:b.y-a.y)) }
        let active=studio.position>=item.start && studio.position<=item.end
        annotationOutline.path=path;annotationOutline.fillColor=nil;annotationOutline.lineWidth=1.5;annotationOutline.lineDashPattern=[6,4]
        annotationOutline.strokeColor=NSColor.white.withAlphaComponent(active ? 0.9:0.35).cgColor
        annotationOutline.shadowColor=NSColor.black.cgColor;annotationOutline.shadowOpacity=0.6;annotationOutline.shadowRadius=2;annotationOutline.shadowOffset = .zero
        annotationOutline.frame=bounds
    }
    func refresh() {
        guard let studio else { return }
        CATransaction.begin();CATransaction.setDisableActions(true)
        if let still=studio.stillImage {
            let (root,r)=decorationLayers(look:studio.look,size:bounds.size,mediaAspect:studio.look.contentAspect(media:studio.mediaAspect))
            let img=CALayer();img.frame=r;img.contents=still.cgImage(forProposedRect:nil,context:nil,hints:nil);img.contentsRect=layerContentsRect((studio.look.videoStyle ?? VideoStyle()).cropRect);img.cornerRadius=studio.look.radius*min(bounds.width,bounds.height)/800;img.masksToBounds=true;root.addSublayer(img);layer=root
        } else {
            if playerLayer.superlayer !== layer { layer=CALayer();layer?.addSublayer(playerLayer) }
            playerLayer.player=studio.player;playerLayer.frame=bounds;playerLayer.videoGravity = .resizeAspect
        }
        if annotationOutline.superlayer !== layer { layer?.addSublayer(annotationOutline) }
        updateAnnotationOutline()
        CATransaction.commit()
    }
}
struct CanvasPreview: NSViewRepresentable {
    @ObservedObject var studio: Studio
    func makeNSView(context:Context) -> CanvasView { let view = CanvasView(); view.studio = studio; return view }
    func updateNSView(_ view:CanvasView,context:Context) { view.studio = studio; view.refresh() }
}

/// Two colours that describe a frame: a deep one for the far side of the background and a bright one for the near side.
/// Colours are counted in coarse buckets, so one strong hue wins over a spread of similar pixels.
func dominantColors(of image:CGImage)->(dark:RGB,light:RGB)? {
    let width=min(160,image.width),height=min(160,image.height)
    guard width>4,height>4 else { return nil }
    var data=[UInt8](repeating:0,count:width*height*4)
    guard let context=CGContext(data:&data,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image,in:CGRect(x:0,y:0,width:width,height:height))
    var buckets:[Int:(count:Int,r:Double,g:Double,b:Double)]=[:]
    for index in stride(from:0,to:data.count,by:4) {
        let r=Double(data[index])/255,g=Double(data[index+1])/255,b=Double(data[index+2])/255
        let saturation=max(r,max(g,b))-min(r,min(g,b))
        // Grey pixels describe the screen's chrome rather than its subject, so they carry less weight.
        let weight=saturation>0.12 ? 3:1
        let key=Int(r*7)*64+Int(g*7)*8+Int(b*7)
        var bucket=buckets[key] ?? (0,0,0,0)
        bucket.count+=weight;bucket.r+=r*Double(weight);bucket.g+=g*Double(weight);bucket.b+=b*Double(weight)
        buckets[key]=bucket
    }
    let ranked=buckets.values.sorted { $0.count>$1.count }.prefix(4).map { RGB(r:$0.r/Double($0.count),g:$0.g/Double($0.count),b:$0.b/Double($0.count)) }
    guard let first=ranked.first else { return nil }
    func level(_ color:RGB)->Double { 0.299*color.r+0.587*color.g+0.114*color.b }
    /// Keeps the hue, lifts washed-out colours and sets the brightness, without going through AppKit.
    func shifted(_ color:RGB,brightness:Double)->RGB {
        let high=max(color.r,max(color.g,color.b)),low=min(color.r,min(color.g,color.b))
        let delta=high-low
        var hue=0.0
        if delta>0.0001 {
            if high==color.r { hue=(color.g-color.b)/delta }
            else if high==color.g { hue=2+(color.b-color.r)/delta }
            else { hue=4+(color.r-color.g)/delta }
            hue=(hue*60).truncatingRemainder(dividingBy:360)
            if hue<0 { hue+=360 }
        }
        let saturation=min(1,max(0.35,(high>0 ? delta/high:0)*1.2))
        let value=max(0.08,min(0.95,brightness))
        let sector=hue/60,index=Int(sector)%6,fraction=sector-Double(Int(sector))
        let p=value*(1-saturation),q=value*(1-saturation*fraction),t=value*(1-saturation*(1-fraction))
        switch index {
        case 0: return RGB(r:value,g:t,b:p)
        case 1: return RGB(r:q,g:value,b:p)
        case 2: return RGB(r:p,g:value,b:t)
        case 3: return RGB(r:p,g:q,b:value)
        case 4: return RGB(r:t,g:p,b:value)
        default: return RGB(r:value,g:p,b:q)
        }
    }
    let second=ranked.count>1 ? ranked.sorted { abs(level($0)-level(first))>abs(level($1)-level(first)) }.first! : first
    let darkSource=level(first)<=level(second) ? first:second
    let lightSource=level(first)<=level(second) ? second:first
    return (shifted(darkSource,brightness:0.22),shifted(lightSource,brightness:0.78))
}
