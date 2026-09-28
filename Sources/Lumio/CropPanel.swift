import SwiftUI
import AVFoundation

enum CropCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
    func point(in box:CGRect)->CGPoint {
        switch self {
        case .topLeft: return CGPoint(x:box.minX,y:box.minY)
        case .topRight: return CGPoint(x:box.maxX,y:box.minY)
        case .bottomLeft: return CGPoint(x:box.minX,y:box.maxY)
        case .bottomRight: return CGPoint(x:box.maxX,y:box.maxY)
        }
    }
    var opposite: CropCorner {
        switch self {
        case .topLeft: return .bottomRight
        case .topRight: return .bottomLeft
        case .bottomLeft: return .topRight
        case .bottomRight: return .topLeft
        }
    }
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: return .topLeading
        case .topRight: return .topTrailing
        case .bottomLeft: return .bottomLeading
        case .bottomRight: return .bottomTrailing
        }
    }
}

/// A crop rectangle from two opposite corners, kept at least a tenth of the frame in each direction.
func normalizedCrop(_ a:CGPoint,_ b:CGPoint)->CGRect {
    let left=min(a.x,b.x),top=min(a.y,b.y)
    let width=max(0.1,abs(a.x-b.x)),height=max(0.1,abs(a.y-b.y))
    return CGRect(x:min(left,1-width),y:min(top,1-height),width:width,height:height)
}

struct CropPanel: View {
    @ObservedObject var studio: Studio
    @State private var frame: NSImage?
    @State private var drag: CropDrag?
    var style: VideoStyle { studio.look.videoStyle ?? VideoStyle() }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            GeometryReader { geo in
                let crop = style.cropRect
                let box = CGRect(x:crop.minX*geo.size.width,y:crop.minY*geo.size.height,width:crop.width*geo.size.width,height:crop.height*geo.size.height)
                ZStack(alignment:.topLeading) {
                    if let frame { Image(nsImage:frame).resizable().frame(width:geo.size.width,height:geo.size.height) }
                    else { Rectangle().fill(Color.white.opacity(0.06)) }
                    Path { path in path.addRect(CGRect(origin:.zero,size:geo.size)); path.addRect(box) }
                        .fill(Color.black.opacity(0.55),style:FillStyle(eoFill:true))
                    Rectangle().stroke(accent,lineWidth:2).frame(width:box.width,height:box.height).offset(x:box.minX,y:box.minY)
                }
                .overlay {
                    // Corner handles resize the crop; dragging inside moves it and dragging outside draws a new one.
                    ForEach(CropCorner.allCases,id:\.self) { corner in
                        RoundedRectangle(cornerRadius:2).fill(accent).frame(width:12,height:12)
                            .offset(x:corner.point(in:box).x-6,y:corner.point(in:box).y-6)
                            .pointerStyle(.frameResize(position:corner.resizePosition))
                    }.allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance:1)
                    .onChanged { value in
                        let session=drag ?? cropDrag(from:value.startLocation,box:box,crop:crop)
                        if drag == nil { drag=session }
                        let point=CGPoint(x:value.location.x/max(1,geo.size.width),y:value.location.y/max(1,geo.size.height))
                        let anchor=CGPoint(x:value.startLocation.x/max(1,geo.size.width),y:value.startLocation.y/max(1,geo.size.height))
                        apply(croppedRect(drag:session,anchor:anchor,point:point))
                    }
                    .onEnded { _ in drag=nil })
            }
            .aspectRatio(max(0.3,studio.mediaAspect),contentMode:.fit)
            .clipShape(RoundedRectangle(cornerRadius:6))
            inset("Left",\.cropLeft)
            inset("Right",\.cropRight)
            inset("Top",\.cropTop)
            inset("Bottom",\.cropBottom)
            HStack {
                Button("Reset Crop") { setCrop(left:0,top:0,right:0,bottom:0) }.disabled(style.cropRect == CGRect(x:0,y:0,width:1,height:1))
                Spacer()
                Text("\(Int((style.cropRect.width*100).rounded()))% × \(Int((style.cropRect.height*100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
            }.font(.caption)
            Text("Drag inside the preview to draw the crop, drag its corners to resize it and drag the box to move it. Cropping hides parts of the recording; zooms and the cursor follow the cropped view.").font(.caption).foregroundStyle(.secondary)
        }
        .task(id:studio.source) { await loadFrame() }
    }
    private func inset(_ title:String,_ key:WritableKeyPath<VideoStyle,Double?>)->some View {
        MotionSlider(title:title,value:Binding(get:{ (style[keyPath:key] ?? 0)*100 },set:{ newValue in
            var value = style; value[keyPath:key] = max(0,min(90,newValue))/100
            let crop = value.cropRect
            value.cropLeft = crop.minX; value.cropTop = crop.minY; value.cropRight = 1-crop.maxX; value.cropBottom = 1-crop.maxY
            studio.look.videoStyle = value
        }),range:0...90,suffix:"%")
    }
    /// Which part of the crop box a drag grabbed, and where the box was when it began.
    struct CropDrag { var corner:CropCorner?; var moving:Bool; var original:CGRect }
    private func cropDrag(from point:CGPoint,box:CGRect,crop:CGRect)->CropDrag {
        if let corner=CropCorner.allCases.first(where:{ hypot($0.point(in:box).x-point.x,$0.point(in:box).y-point.y)<=14 }) { return CropDrag(corner:corner,moving:false,original:crop) }
        // A crop that still covers the whole frame has nothing to move, so a drag inside it draws a new box.
        let full=crop.width>0.999 && crop.height>0.999
        return CropDrag(corner:nil,moving: !full && box.insetBy(dx:-4,dy:-4).contains(point),original:crop)
    }
    /// The crop a drag produces: moved, resized from one corner, or drawn fresh between the two points.
    private func croppedRect(drag:CropDrag,anchor:CGPoint,point:CGPoint)->CGRect {
        let limit={ (value:Double) in max(0,min(1,value)) }
        if let corner=drag.corner {
            let fixed=corner.opposite.point(in:drag.original)
            return normalizedCrop(fixed,CGPoint(x:limit(point.x),y:limit(point.y)))
        }
        if drag.moving {
            let x=max(0,min(1-drag.original.width,drag.original.minX+point.x-anchor.x))
            let y=max(0,min(1-drag.original.height,drag.original.minY+point.y-anchor.y))
            return CGRect(x:x,y:y,width:drag.original.width,height:drag.original.height)
        }
        return normalizedCrop(CGPoint(x:limit(anchor.x),y:limit(anchor.y)),CGPoint(x:limit(point.x),y:limit(point.y)))
    }
    private func apply(_ rect:CGRect) {
        setCrop(left:rect.minX,top:rect.minY,right:1-rect.maxX,bottom:1-rect.maxY)
    }
    private func setCrop(left:Double,top:Double,right:Double,bottom:Double) {
        var value = style
        value.cropLeft = max(0,left); value.cropTop = max(0,top); value.cropRight = max(0,right); value.cropBottom = max(0,bottom)
        studio.look.videoStyle = value
    }
    private func loadFrame() async {
        if let still = studio.stillImage { frame = still; return }
        guard let source = studio.source else { frame = nil; return }
        let generator = AVAssetImageGenerator(asset:AVURLAsset(url:source))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width:640,height:640)
        let sourceTime = studio.placement(containing:studio.position).map { $0.clip.sourceTime(forTimeline:studio.position) } ?? 0
        if let image = try? await generator.image(at:CMTime(seconds:sourceTime,preferredTimescale:600)).image { frame = NSImage(cgImage:image,size:.zero) }
    }
}
