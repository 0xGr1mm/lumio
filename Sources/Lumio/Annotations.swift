import AppKit
import CoreImage
import SwiftUI

/// An arrow, box, text label, blurred region or spotlight shown over the recording for a time range.
/// It is placed on the video itself, so it stays on the same spot while zooms and pans move the view.
struct Annotation: Codable, Equatable, Identifiable {
    static let kinds = ["Arrow","Box","Text","Blur","Hide","Spotlight"]
    var id = UUID()
    var kind = "Arrow"
    var start: Double
    var end: Double
    /// Top-left unit coordinates in the visible (cropped) video. For an arrow, (x, y) is the tail and (x+width, y+height) the head.
    var x = 0.35
    var y = 0.35
    var width = 0.2
    var height = 0.15
    var color = RGB(0xFF3B30)
    var text = "Look here"
    /// Line width at 1080p for arrows and boxes.
    var thickness = 7.0
    /// Text size at 1080p.
    var fontSize = 46.0
    /// Blur radius or spotlight dimming, 0…1.
    var strength = 0.6
    var rect: CGRect { CGRect(x:min(x,x+width),y:min(y,y+height),width:abs(width),height:abs(height)) }
    var symbol: String {
        switch kind {
        case "Box": return "rectangle"
        case "Text": return "textformat"
        case "Blur": return "eye.slash"
        case "Hide": return "square.slash"
        case "Spotlight": return "light.max"
        default: return "arrow.up.right"
        }
    }
    /// Opacity at a time: annotations fade in and out over 0.2 s.
    func alpha(at time:Double)->Double {
        guard time >= start, time <= end else { return 0 }
        let ramp = min(0.2,(end-start)/2)
        return ramp > 0 ? min(1,(time-start)/ramp,(end-time)/ramp) : 1
    }
}

func normalizedAnnotations(_ items:[Annotation],duration:Double,limit:Int=2_000)->[Annotation] {
    guard duration.isFinite, duration > 0 else { return [] }
    var ids = Set<UUID>()
    return items.prefix(limit).compactMap { original in
        var a = original
        guard [a.start,a.end,a.x,a.y,a.width,a.height,a.thickness,a.fontSize,a.strength].allSatisfy(\.isFinite) else { return nil }
        if !Annotation.kinds.contains(a.kind) { a.kind = "Arrow" }
        a.start = max(0,min(duration,a.start)); a.end = max(0,min(duration,a.end))
        guard a.end-a.start >= 0.1 else { return nil }
        a.x = max(-1,min(2,a.x)); a.y = max(-1,min(2,a.y)); a.width = max(-2,min(2,a.width)); a.height = max(-2,min(2,a.height))
        a.color = a.color.normalized(); a.text = String(a.text.prefix(200))
        a.thickness = max(1,min(40,a.thickness)); a.fontSize = max(12,min(160,a.fontSize)); a.strength = max(0,min(1,a.strength))
        if !ids.insert(a.id).inserted { a.id = UUID() }
        return a
    }
}

/// Moves annotations onto a rebuilt timeline: removed ranges and speed changes shift them like zooms and captions,
/// and an annotation whose whole range was cut away goes with it.
func remappedAnnotations(_ items:[Annotation],_ remap:(Double)->Double)->[Annotation] {
    items.compactMap { item in
        var copy=item;copy.start=remap(item.start);copy.end=remap(item.end)
        return copy.end-copy.start>=0.1 ? copy:nil
    }
}

/// Unit rectangle (top-left) to Core Image pixels (bottom-left) in an image of the given size.
func annotationPixels(_ unit:CGRect,in size:CGSize)->CGRect {
    CGRect(x:unit.minX*size.width,y:(1-unit.maxY)*size.height,width:unit.width*size.width,height:unit.height*size.height)
}

/// Applies the annotations active at a time to the visible source frame (extent at the origin), before zoom and placement.
func annotated(_ source:CIImage,time:Double,annotations:[Annotation],art:OverlayArtCache)->CIImage {
    let active = annotations.filter { time >= $0.start && time <= $0.end }
    guard !active.isEmpty else { return source }
    let extent = source.extent, size = extent.size
    var image = source
    func mask(_ region:CGRect,level:Double)->CIImage {
        let radius = min(region.width,region.height)*0.12
        return CIFilter(name:"CIRoundedRectangleGenerator",parameters:["inputExtent":CIVector(cgRect:region),"inputRadius":radius,"inputColor":CIColor(red:level,green:level,blue:level)])?.outputImage?.cropped(to:extent) ?? CIImage(color:CIColor(red:level,green:level,blue:level)).cropped(to:region)
    }
    // Pixel effects first, so arrows and labels are drawn sharp on top of them.
    for a in active where a.kind == "Blur" || a.kind == "Hide" || a.kind == "Spotlight" {
        let alpha = a.alpha(at:time), region = annotationPixels(a.rect,in:size).intersection(extent)
        guard alpha > 0.001, !region.isNull, region.width >= 1, region.height >= 1 else { continue }
        let black = CIImage(color:.black).cropped(to:extent)
        if a.kind == "Blur" {
            let radius = (4+a.strength*46)*size.height/1080
            // Only the region is blurred: blurring the whole frame would cost the same at every annotation and resolution.
            let margin = region.insetBy(dx:-radius*3,dy:-radius*3).intersection(extent)
            let blurred = image.cropped(to:margin).clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:region)
            image = blurred.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask(region,level:alpha).composited(over:black)])
        } else if a.kind == "Hide" {
            // A block, not a blur: a blurred address can still be read back from a video, a covered one cannot.
            let block = CIImage(color:CIColor(red:a.color.r,green:a.color.g,blue:a.color.b)).cropped(to:extent)
            image = block.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:image,kCIInputMaskImageKey:mask(region,level:alpha).composited(over:black)])
        } else {
            let keep = 1-min(0.9,a.strength*0.9)*alpha
            let dimmed = image.applyingFilter("CIColorMatrix",parameters:["inputRVector":CIVector(x:keep,y:0,z:0,w:0),"inputGVector":CIVector(x:0,y:keep,z:0,w:0),"inputBVector":CIVector(x:0,y:0,z:keep,w:0)])
            image = image.applyingFilter("CIBlendWithMask",parameters:[kCIInputBackgroundImageKey:dimmed,kCIInputMaskImageKey:mask(region,level:1).composited(over:black)])
        }
    }
    for a in active where a.kind == "Arrow" || a.kind == "Box" || a.kind == "Text" {
        let alpha = a.alpha(at:time)
        guard alpha > 0.001, let drawn = art.annotation(a,frame:size) else { continue }
        var layer = CIImage(cgImage:drawn.image).transformed(by:CGAffineTransform(scaleX:1/drawn.scale,y:1/drawn.scale))
        layer = layer.transformed(by:CGAffineTransform(translationX:drawn.origin.x,y:drawn.origin.y))
        if alpha < 0.999 { layer = layer.applyingFilter("CIColorMatrix",parameters:["inputAVector":CIVector(x:0,y:0,z:0,w:alpha)]) }
        image = layer.composited(over:image)
    }
    return image.cropped(to:extent)
}

struct AnnotationArt { var image:CGImage; var origin:CGPoint; var scale:Double }

/// Draws an arrow, box or label at the frame's pixel scale. `origin` is where its bottom-left corner goes on the frame.
func annotationArtwork(_ a:Annotation,frame size:CGSize)->AnnotationArt? {
    let unit = size.height/1080
    let line = a.thickness*unit
    let pad = max(line*4,24*unit)
    var bounds = annotationPixels(a.rect,in:size)
    if a.kind == "Text" {
        let font = NSFont.systemFont(ofSize:a.fontSize*unit,weight:.bold)
        let measured = (a.text as NSString).size(withAttributes:[.font:font])
        let center = CGPoint(x:bounds.midX,y:bounds.midY)
        bounds = CGRect(x:center.x-measured.width/2-20*unit,y:center.y-measured.height/2-10*unit,width:measured.width+40*unit,height:measured.height+20*unit)
    }
    let outer = bounds.insetBy(dx:-pad,dy:-pad)
    guard outer.width >= 2, outer.height >= 2 else { return nil }
    let scale = min(1,4096/max(outer.width,outer.height))
    let width = Int((outer.width*scale).rounded(.up)), height = Int((outer.height*scale).rounded(.up))
    guard let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.scaleBy(x:scale,y:scale); context.translateBy(x:-outer.minX,y:-outer.minY)
    context.setShadow(offset:CGSize(width:0,height:-3*unit),blur:10*unit,color:NSColor.black.withAlphaComponent(0.45).cgColor)
    let color = a.color.ns.cgColor
    switch a.kind {
    case "Box":
        let path = CGPath(roundedRect:bounds,cornerWidth:min(14*unit,bounds.width/2),cornerHeight:min(14*unit,bounds.height/2),transform:nil)
        context.addPath(path); context.setStrokeColor(color); context.setLineWidth(line); context.strokePath()
    case "Text":
        let graphics = NSGraphicsContext(cgContext:context,flipped:false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
        let pill = NSBezierPath(roundedRect:bounds,xRadius:bounds.height*0.3,yRadius:bounds.height*0.3)
        a.color.ns.setFill(); pill.fill()
        context.setShadow(offset:.zero,blur:0,color:nil)
        let font = NSFont.systemFont(ofSize:a.fontSize*unit,weight:.bold)
        let light = 0.299*a.color.r+0.587*a.color.g+0.114*a.color.b > 0.62
        (a.text as NSString).draw(at:CGPoint(x:bounds.minX+20*unit,y:bounds.minY+10*unit),withAttributes:[.font:font,.foregroundColor:light ? NSColor.black:NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
    default:
        // Tail at (x, y), head at (x+width, y+height), both top-left unit coordinates.
        let tail = CGPoint(x:a.x*size.width,y:(1-a.y)*size.height), head = CGPoint(x:(a.x+a.width)*size.width,y:(1-a.y-a.height)*size.height)
        let length = hypot(head.x-tail.x,head.y-tail.y)
        guard length > 1 else { return nil }
        let angle = atan2(head.y-tail.y,head.x-tail.x), headLength = min(length*0.45,line*4.2), spread = 0.48
        let base = CGPoint(x:head.x-cos(angle)*headLength*0.8,y:head.y-sin(angle)*headLength*0.8)
        context.setStrokeColor(color); context.setFillColor(color); context.setLineWidth(line); context.setLineCap(.round)
        context.move(to:tail); context.addLine(to:base); context.strokePath()
        context.move(to:head)
        context.addLine(to:CGPoint(x:head.x-cos(angle-spread)*headLength,y:head.y-sin(angle-spread)*headLength))
        context.addLine(to:CGPoint(x:head.x-cos(angle+spread)*headLength,y:head.y-sin(angle+spread)*headLength))
        context.closePath(); context.fillPath()
    }
    guard let image = context.makeImage() else { return nil }
    return AnnotationArt(image:image,origin:outer.origin,scale:scale)
}

@MainActor extension Studio {
    var selectedAnnotationIndex: Int? { annotations.firstIndex { $0.id == selectedAnnotation } }
    /// Adds an annotation at the playhead and selects it; drawing on the preview then places it.
    func addAnnotation(_ kind:String) {
        guard duration > 0, stillImage == nil else { return }
        let start = min(max(0,position),max(0,duration-0.2))
        var item = Annotation(kind:kind,start:start,end:min(duration,start+3))
        switch kind {
        case "Arrow": item.x = 0.3; item.y = 0.62; item.width = 0.16; item.height = -0.18
        case "Text": item.color = RGB(0xFFD60A); item.x = 0.35; item.y = 0.08; item.width = 0.3; item.height = 0.08
        case "Blur", "Spotlight": item.x = 0.3; item.y = 0.3; item.width = 0.4; item.height = 0.3
        case "Hide": item.color = RGB(0x101216); item.x = 0.32; item.y = 0.42; item.width = 0.36; item.height = 0.1
        default: break
        }
        annotations.append(item); focusTimeline(.annotation,id:item.id)
        player.pause(); playing = false; position = start+min(0.3,(item.end-start)/2); seek(position)
    }
    func setAnnotationRange(_ id:UUID,to range:TimelineRange) {
        guard let i = annotations.firstIndex(where:{ $0.id == id }) else { return }
        annotations[i].start = max(0,range.start); annotations[i].end = min(duration,max(annotations[i].start+0.1,range.end))
    }
}

struct AnnotationPanel: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Add at playhead").font(.caption).foregroundStyle(.secondary)
            HStack(spacing:8) {
                ForEach(Annotation.kinds,id:\.self) { kind in
                    Button { studio.addAnnotation(kind) } label: {
                        VStack(spacing:4) { Image(systemName:Annotation(kind:kind,start:0,end:1).symbol).font(.system(size:15)); Text(kind).font(.system(size:9)) }
                            .frame(width:48,height:44).contentShape(Rectangle())
                    }.buttonStyle(.plain).background(.white.opacity(0.06)).clipShape(RoundedRectangle(cornerRadius:8)).help("Add \(kind.lowercased()) at the playhead")
                }
            }.disabled(studio.stillImage != nil || studio.duration <= 0)
            // Bound by id, so deleting the selected annotation while the panel is open cannot leave a stale index behind.
            if let item = studio.annotations.first(where:{ $0.id == studio.selectedAnnotation }) {
                let id = item.id, kind = item.kind
                Text(kind == "Arrow" ? "Drag on the preview from the tail to the tip. The arrow stays on that spot when the view zooms.":"Drag on the preview to place it, or drag inside it to move it. It stays on that spot when the view zooms.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if kind == "Text" {
                    TextField("Text",text:studio.binding(\.annotations,id:id,\.text,fallback:item.text)).textFieldStyle(.roundedBorder)
                    Text(String(format:"Size · %.0f",item.fontSize)).font(.caption)
                    Slider(value:studio.binding(\.annotations,id:id,\.fontSize,fallback:item.fontSize),in:18...120)
                }
                if kind == "Hide" {
                    ColorPicker("Block Color",selection:Binding(get:{ item.color.color },set:{ color in studio.update(\.annotations,id:id) { $0.color = RGB(color) } }),supportsOpacity:false)
                }
                if kind == "Arrow" || kind == "Box" || kind == "Text" {
                    ColorPicker("Color",selection:Binding(get:{ item.color.color },set:{ color in studio.update(\.annotations,id:id) { $0.color = RGB(color) } }),supportsOpacity:false)
                    HStack(spacing:8) {
                        ForEach([0xFF3B30,0xFFD60A,0x34C759,0x0A84FF,0xFFFFFF,0x111111] as [UInt32],id:\.self) { hex in
                            Button { studio.update(\.annotations,id:id) { $0.color = RGB(hex) } } label: { Circle().fill(RGB(hex).color).frame(width:18,height:18).overlay(Circle().stroke(.white.opacity(0.4))).padding(3).contentShape(Rectangle()) }.buttonStyle(.plain).help("Use this color")
                        }
                    }
                }
                if kind == "Arrow" || kind == "Box" {
                    Text(String(format:"Line · %.0f",item.thickness)).font(.caption)
                    Slider(value:studio.binding(\.annotations,id:id,\.thickness,fallback:item.thickness),in:2...24)
                }
                if kind == "Blur" || kind == "Spotlight" {
                    Text(String(format:kind == "Blur" ? "Blur · %.0f%%":"Dim outside · %.0f%%",item.strength*100)).font(.caption)
                    Slider(value:studio.binding(\.annotations,id:id,\.strength,fallback:item.strength),in:0.05...1)
                }
                HStack {
                    Text(String(format:"%.2f – %.2f s",item.start,item.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Button("Delete",role:.destructive) { studio.deleteTimelineItem(.annotation,id:id) }
                }
            } else {
                Text("Arrows, boxes and labels point at part of the screen; Blur softens private details and Hide covers them outright; Spotlight dims everything else. Select one in the timeline to edit it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
        .onAppear { studio.annotationEditing = true }
        .onDisappear { studio.annotationEditing = false }
    }
}
