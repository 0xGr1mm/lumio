import AppKit
import AVFoundation
import SwiftUI

struct PointerSample: Codable, Equatable {
    var time: Double; var x: Double; var y: Double; var pressed: Bool
    var shape: String = "arrow"
}
struct CameraStyle: Codable, Equatable {
    var enabled = true
    var layout = "Floating"
    var position = "Bottom Right"
    var size = 19.0
    var roundness = 36.0
    var borderWidth = 3.0
    var borderColor = RGB(0xFFFFFF)
    var mirror = false
    var zoomSize = 78.0
    var margin = 24.0
    var avoidCursor: Bool? = nil
    /// What happens behind the person in the camera: "None", "Blur" or "Remove".
    var background: String? = nil
    var backgroundBlur: Double? = nil
    var resolvedBackground: String { ["None","Blur","Remove"].contains(background ?? "None") ? (background ?? "None"):"None" }
    var resolvedBackgroundBlur: Double { let value=backgroundBlur ?? 14; return value.isFinite ? max(2,min(40,value)):14 }
    func normalized()->CameraStyle {
        var value=self
        if !["Floating","Split Left","Split Right","Camera Full","Screen Only"].contains(value.layout){value.layout="Floating"}
        if !["Top Left","Top","Top Right","Left","Center","Right","Bottom Left","Bottom","Bottom Right"].contains(value.position){value.position="Bottom Right"}
        value.size=max(8,min(55,value.size.isFinite ? value.size:19));value.roundness=max(0,min(100,value.roundness.isFinite ? value.roundness:36));value.borderWidth=max(0,min(16,value.borderWidth.isFinite ? value.borderWidth:3));value.zoomSize=max(25,min(150,value.zoomSize.isFinite ? value.zoomSize:78));value.margin=max(0,min(100,value.margin.isFinite ? value.margin:24));value.borderColor=value.borderColor.normalized()
        value.background=value.resolvedBackground == "None" ? nil:value.resolvedBackground
        value.backgroundBlur=value.background == "Blur" ? value.resolvedBackgroundBlur:nil
        return value
    }
}
struct MotionSettings: Codable, Equatable {
    var autoZoom = true
    var zoom = 1.5
    var cameraZoom = 1.4
    var keepZoomed = false
    var motion = "focused"
    var blurEnabled = true
    var blurAmount = 0.8
    var blurQuality = 1
    var blurCursor = 1.0
    var blurScreen = 0.8
    var blurZoom = 1.0
    var snap = 0.25
    var showCursor = true
    var style = "Classic Outline"
    var type = "Auto"
    var size = 100.0
    var color = RGB(0xFFFFFF)
    var smoothing = true
    var cursorAnimation = "Medium"
    var stiffness = 470.0
    var damping = 70.0
    var mass = 3.0
    var tilt = false
    var endMotion = "stop"
    var shakeFilter = true
    var threshold = 500.0
    var clickZoom = 0.35
    var clickDuration = 0.3
    var clickHighlight = false
    var clickSound = false
    var hideIdle = false
    var idleDelay = 1.5
    var hideTyping = false
    var cameraStyle: CameraStyle? = CameraStyle()
    var zoomOnTyping: Bool? = nil
    func normalized() -> MotionSettings {
        var value=self
        if ["Default","macOS","Tabler","Lucide","Pixel Outline","Bold Arrow","Thin Arrow","Tint"].contains(value.style) {value.style="Classic Outline"}
        if !["Classic Outline","Solid Arrow","Lavender","Neon","Pixel","3D","Color Pop","Cartoon","Minecraft Enchanted","Pop Cat","Rose Diamond","Among Us Batman","Among Us Joker","Harley Quinn"].contains(value.style) {value.style="Classic Outline"}
        value.zoom=min(6,max(1,value.zoom.isFinite ? value.zoom:1.5));value.cameraZoom=min(3,max(1,value.cameraZoom.isFinite ? value.cameraZoom:1.4))
        value.size=min(400,max(25,value.size.isFinite ? value.size:100));value.idleDelay=min(5,max(0.3,value.idleDelay.isFinite ? value.idleDelay:1.5))
        value.clickDuration=min(1,max(0.05,value.clickDuration.isFinite ? value.clickDuration:0.3));value.clickZoom=min(0.8,max(0,value.clickZoom.isFinite ? value.clickZoom:0.35))
        if !["Auto","Fixed"].contains(value.type){value.type="Auto"};if !["focused","fluid","spring"].contains(value.motion){value.motion="focused"};if !["Smooth","Medium","Rapid","None"].contains(value.cursorAnimation){value.cursorAnimation="Medium"};if !["hide","loop","stop"].contains(value.endMotion){value.endMotion="stop"}
        value.color=value.color.normalized();value.blurAmount=max(0,min(1,value.blurAmount.isFinite ? value.blurAmount:0.8));value.blurCursor=max(0,min(1,value.blurCursor.isFinite ? value.blurCursor:1));value.blurScreen=max(0,min(1,value.blurScreen.isFinite ? value.blurScreen:0.8));value.blurZoom=max(0,min(1,value.blurZoom.isFinite ? value.blurZoom:1));value.snap=max(0,min(1,value.snap.isFinite ? value.snap:0.25));value.blurQuality=max(0,min(2,value.blurQuality))
        value.stiffness=max(20,min(1000,value.stiffness.isFinite ? value.stiffness:470));value.damping=max(1,min(150,value.damping.isFinite ? value.damping:70));value.mass=max(0.2,min(10,value.mass.isFinite ? value.mass:3));value.threshold=max(0,min(1000,value.threshold.isFinite ? value.threshold:500))
        value.cameraStyle=(value.cameraStyle ?? CameraStyle()).normalized()
        return value
    }
}
struct PointerRecording: Codable {
    var samples: [PointerSample]
    var cursorEmbedded = false
}
func normalizedPointerSamples(_ samples:[PointerSample],sourceDuration:Double,limit:Int=200_000)->[PointerSample] {
    let shapes=Set(["arrow","ibeam","hand","crosshair","resizeHorizontal","resizeVertical","openHand","closedHand"])
    return samples.prefix(limit).compactMap { original in
        guard original.time.isFinite,original.x.isFinite,original.y.isFinite,original.time>=0,original.time<=max(0,sourceDuration),abs(original.x)<=10,abs(original.y)<=10 else{return nil}
        var value=original
        if !shapes.contains(value.shape){value.shape="arrow"}
        return value
    }.sorted{$0.time<$1.time}
}
func pointerAt(_ time:Double, samples:[PointerSample]) -> PointerSample? {
    guard let first = samples.first, let last = samples.last else { return nil }
    if time <= first.time { return first }; if time >= last.time { return last }
    var low = 0, high = samples.count-1
    while low+1 < high { let mid = (low+high)/2; if samples[mid].time <= time { low = mid } else { high = mid } }
    let a = samples[low], b = samples[high], u = max(0,min(1,(time-a.time)/max(0.00001,b.time-a.time)))
    return PointerSample(time:time,x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u,pressed:a.pressed,shape:a.shape)
}
func smoothPointer(_ samples:[PointerSample], settings:MotionSettings) -> [PointerSample] {
    guard settings.smoothing, settings.cursorAnimation != "None", let first = samples.first else { return samples }
    var x=first.x,y=first.y,vx=0.0,vy=0.0,previous=first.time
    return samples.map { input in
        var s=input
        let dt=max(0.001,min(0.1,s.time-previous)); previous=s.time
        if s.x < 0 || s.x > 1 || s.y < 0 || s.y > 1 { x=s.x;y=s.y;vx=0;vy=0;return s }
        var tx=s.x,ty=s.y
        if settings.shakeFilter && hypot(tx-x,ty-y)*1000 < settings.threshold*0.015 { tx=x;ty=y }
        let steps=max(1,Int(ceil(dt/0.004))), step=dt/Double(steps)
        for _ in 0..<steps {
            vx += (settings.stiffness*(tx-x)-settings.damping*vx)/max(0.1,settings.mass)*step
            vy += (settings.stiffness*(ty-y)-settings.damping*vy)/max(0.1,settings.mass)*step
            x += vx*step;y += vy*step
        }
        s.x=min(1,max(0,x));s.y=min(1,max(0,y));return s
    }
}
func autoZoomClips(samples:[PointerSample],settings:MotionSettings,duration:Double,typing:[Double]=[]) -> [ZoomClip] {
    guard settings.autoZoom, !samples.isEmpty else { return [] }
    if settings.keepZoomed { return [ZoomClip(start:0,end:duration,scale:settings.zoom,transition:0.45)] }
    func inside(_ s:PointerSample)->Bool { s.x >= 0 && s.x <= 1 && s.y >= 0 && s.y <= 1 }
    var events:[ZoomClip]=[], previous=false
    for s in samples {
        if s.pressed && !previous && inside(s) { events.append(ZoomClip(start:max(0,s.time-0.35),end:min(duration,s.time+1.8),scale:settings.zoom,x:s.x,y:s.y,transition:0.45)) }
        previous=s.pressed
    }
    if settings.zoomOnTyping ?? true {
        // A typing burst zooms toward the last click before it (usually the text field) and holds still instead of chasing the pointer.
        var burst:[Double]=[]
        func flush() {
            defer { burst=[] }
            guard burst.count>=3,let first=burst.first,let last=burst.last else{return}
            let anchor=samples.last(where:{$0.pressed && $0.time<=first && first-$0.time<30 && inside($0)}) ?? pointerAt(first,samples:samples)
            guard let anchor,inside(anchor) else{return}
            events.append(ZoomClip(start:max(0,first-0.3),end:min(duration,last+1.2),scale:settings.zoom,x:anchor.x,y:anchor.y,transition:0.45,follow:false))
        }
        for time in typing.sorted() { if let last=burst.last,time-last>1.2 {flush()};burst.append(time) }
        flush()
    }
    var clips:[ZoomClip]=[]
    for event in events.sorted(by:{$0.start<$1.start}) where event.end-event.start>=0.1 {
        if let i=clips.indices.last,event.start<clips[i].end {
            clips[i].end=max(clips[i].end,event.end)
            if event.follow ?? true { clips[i].follow=nil }
        } else { clips.append(event) }
    }
    return clips
}
/// Camera target for automatic zooms: follows the pointer with a dead zone and a critically damped spring,
/// so small pointer movements do not pan the zoomed view.
func cameraFollowPath(_ samples:[PointerSample],settings:MotionSettings,viewFraction:Double?=nil)->[PointerSample] {
    guard let first=samples.first else{return []}
    let dead=(viewFraction ?? 1/max(1,settings.zoom))*0.5*0.45
    var cx=min(1,max(0,first.x)),cy=min(1,max(0,first.y)),vx=0.0,vy=0.0,previous=first.time
    return samples.map { input in
        var s=input
        let dt=max(0.001,min(0.1,s.time-previous));previous=s.time
        guard s.x>=0,s.x<=1,s.y>=0,s.y<=1 else{s.x=cx;s.y=cy;return s}
        var tx=cx,ty=cy
        if abs(s.x-cx)>dead {tx=s.x-copysign(dead,s.x-cx)}
        if abs(s.y-cy)>dead {ty=s.y-copysign(dead,s.y-cy)}
        let steps=max(1,Int(ceil(dt/0.004))),step=dt/Double(steps)
        for _ in 0..<steps {
            vx+=(90*(tx-cx)-19*vx)*step;vy+=(90*(ty-cy)-19*vy)*step
            cx+=vx*step;cy+=vy*step
        }
        s.x=min(1,max(0,cx));s.y=min(1,max(0,cy));return s
    }
}
func motionPose(at time:Double,manual:[ZoomClip],auto:[ZoomClip],samples:[PointerSample],settings:MotionSettings) -> ZoomPose {
    let manualActive=manual.contains { time >= $0.start && time <= $0.end }
    let clips=manualActive ? manual:auto
    guard let z=clips.sorted(by:{$0.start < $1.start}).last(where:{time >= $0.start && time <= $0.end}) else { return ZoomPose() }
    let ramp=max(0.0001,min(z.transition,(z.end-z.start)/2))
    let u=min(1,max(0,min((time-z.start)/ramp,(z.end-time)/ramp)))
    var weight=u
    if z.smooth {
        if settings.motion == "fluid" { weight=(1-cos(.pi*u))/2 }
        else if settings.motion == "spring" { weight=u == 1 ? 1 : 1-pow(2,-8*u)*cos(10*u) }
        else { weight=u*u*(3-2*u) }
    }
    var x=z.x,y=z.y
    if !manualActive, z.follow ?? true, let p=pointerAt(time,samples:samples) {
        x=p.x;y=p.y
        let margin=settings.snap*0.4
        if x < margin { x=0 };if x > 1-margin { x=1 }
        if y < margin { y=0 };if y > 1-margin { y=1 }
    }
    return ZoomPose(scale:max(1,1+(z.scale-1)*weight),x:x,y:y,weight:weight)
}
/// In auto reframe the view follows the pointer when no zoom is active, and blends smoothly into a zoom's target.
func reframedPose(_ pose:ZoomPose,follow:PointerSample?)->ZoomPose {
    guard let follow else { return pose }
    var value=pose
    value.x=follow.x+(pose.x-follow.x)*pose.weight
    value.y=follow.y+(pose.y-follow.y)*pose.weight
    return value
}
/// Fraction of a 16×16 downsample that is mostly opaque; separates thin cursors (crosshair) from filled ones (hands).
func alphaCoverage(_ image:CGImage,side:Int=16)->Double {
    guard let context=CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return 0}
    context.draw(image,in:CGRect(x:0,y:0,width:side,height:side))
    guard let data=context.data else{return 0}
    let pixels=data.bindMemory(to:UInt8.self,capacity:side*side*4)
    var count=0
    for index in 0..<(side*side) where pixels[index*4+3]>100 {count+=1}
    return Double(count)/Double(side*side)
}
/// Share of opaque pixels lying on the centre row and column bands of a 24×24 downsample.
/// A crosshair measures 1.0; hand cursors stay below 0.75 (measured on the system cursors), while overall fill cannot tell them apart.
func cursorCrossness(_ image:NSImage)->Double {
    let side=24
    guard image.size.width>0,let cg=image.cgImage(forProposedRect:nil,context:nil,hints:nil),
          let context=CGContext(data:nil,width:side,height:side,bitsPerComponent:8,bytesPerRow:side*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{return 0}
    context.draw(cg,in:CGRect(x:0,y:0,width:side,height:side))
    guard let data=context.data else{return 0}
    let pixels=data.bindMemory(to:UInt8.self,capacity:side*side*4)
    let centre=Double(side-1)/2
    var total=0,onCross=0
    for y in 0..<side {
        for x in 0..<side where pixels[(y*side+x)*4+3]>100 {
            total+=1
            if abs(Double(x)-centre)<=1.5 || abs(Double(y)-centre)<=1.5 {onCross+=1}
        }
    }
    return total == 0 ? 0:Double(onCross)/Double(total)
}
/// NSCursor.currentSystem returns a new object every time, so it never equals NSCursor.iBeam and friends.
/// The shape is recognized from the hotspot position, aspect ratio and pixel layout instead, which survive cursor scaling.
func classifyCursorShape(size:CGSize,hotSpot:CGPoint,crossness:Double,pressed:Bool)->String {
    guard size.width>0,size.height>0 else{return "arrow"}
    let aspect=size.width/size.height,hx=hotSpot.x/size.width,hy=hotSpot.y/size.height
    if hx<0.32 && hy<0.32 {return "arrow"}
    if abs(hx-0.5)<0.15 && abs(hy-0.5)<0.15 {
        if aspect<0.62 {return "ibeam"}
        if aspect>1.12 {return "resizeHorizontal"}
        if aspect<0.93 {return "resizeVertical"}
        if crossness>0.9 {return "crosshair"}
        return pressed ? "closedHand":"openHand"
    }
    if hy<0.45 && abs(aspect-1)<0.2 {return "hand"}
    return "arrow"
}
/// Moves samples from the capture clock onto the recording file's clock.
func shiftedPointerSamples(_ samples:[PointerSample],by offset:Double)->[PointerSample] {
    samples.compactMap { sample in
        var copy=sample;copy.time-=offset
        guard copy.time >= -0.05 else{return nil}
        copy.time=max(0,copy.time);return copy
    }
}
@MainActor final class PointerCapture {
    var timer:Timer?
    var samples:[PointerSample]=[]
    var rect=CGRect.zero
    var startUptime=ProcessInfo.processInfo.systemUptime
    private var crossnessCache:[String:Double]=[:]
    func start(rect:CGRect) {
        timer?.invalidate()
        self.rect=rect;samples=[];startUptime=ProcessInfo.processInfo.systemUptime
        // Common run loop mode keeps sampling while menus or popovers are tracking the mouse.
        let timer=Timer(timeInterval:1.0/60,repeats:true) { [weak self] _ in MainActor.assumeIsolated { self?.sample() } }
        RunLoop.main.add(timer,forMode:.common);self.timer=timer
        sample()
    }
    func sample() {
        guard rect.width > 0, rect.height > 0, let point=CGEvent(source:nil)?.location else { return }
        let pressed=CGEventSource.buttonState(.combinedSessionState,button:.left)
        samples.append(PointerSample(time:ProcessInfo.processInfo.systemUptime-startUptime,x:(point.x-rect.minX)/rect.width,y:(point.y-rect.minY)/rect.height,pressed:pressed,shape:currentShape(pressed:pressed)))
    }
    func currentShape(pressed:Bool)->String {
        guard let cursor=NSCursor.currentSystem else{return "arrow"}
        let image=cursor.image,size=image.size,hot=cursor.hotSpot
        let key="\(Int(size.width*8))x\(Int(size.height*8))@\(Int(hot.x*8)),\(Int(hot.y*8))"
        let crossness:Double
        if let cached=crossnessCache[key] {crossness=cached} else {crossness=cursorCrossness(image);crossnessCache[key]=crossness}
        return classifyCursorShape(size:size,hotSpot:hot,crossness:crossness,pressed:pressed)
    }
    func stop() -> [PointerSample] { timer?.invalidate();timer=nil;return samples }
}
