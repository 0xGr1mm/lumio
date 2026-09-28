import SwiftUI

struct ZoomClip: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var scale = 2.0
    var x = 0.5
    var y = 0.5
    var transition = 0.5
    var smooth = true
    /// Automatic zooms follow the pointer unless false (typing zooms hold on the field).
    var follow: Bool? = nil
}
struct ZoomPose: Equatable {
    var scale = 1.0
    var x = 0.5
    var y = 0.5
    /// How far the active zoom has ramped in (0…1); blends auto reframe into zoom targets.
    var weight = 0.0
    /// Offset of content (sized at scale 1) inside a view so the pose centre is shown,
    /// clamped so the content keeps covering the view; content smaller than the view stays centred.
    func placement(viewWidth:Double,viewHeight:Double,contentWidth:Double,contentHeight:Double,flipped:Bool=false)->CGPoint {
        let sw=contentWidth*scale,sh=contentHeight*scale
        let hx=sw>0 ? viewWidth/(2*sw):0.5,hy=sh>0 ? viewHeight/(2*sh):0.5
        let cx=hx>=0.5 ? 0.5:min(max(x,hx),1-hx)
        let cy=hy>=0.5 ? 0.5:min(max(flipped ? 1-y:y,hy),1-hy)
        return CGPoint(x:viewWidth/2-cx*sw,y:viewHeight/2-cy*sh)
    }
    func offset(width: Double, height: Double, flipped: Bool = false) -> CGPoint {
        let cx = min(max(x,0.5/scale),1-0.5/scale)
        let cy = min(max(flipped ? 1-y : y,0.5/scale),1-0.5/scale)
        return CGPoint(x:width*(0.5-cx*scale),y:height*(0.5-cy*scale))
    }
}
func normalizedZoomClips(_ clips:[ZoomClip],duration:Double,limit:Int=10_000)->[ZoomClip] {
    guard duration.isFinite,duration>0 else{return []}
    var result:[ZoomClip]=[],ids=Set<UUID>()
    for original in clips.prefix(limit) {
        guard original.start.isFinite,original.end.isFinite,original.scale.isFinite,original.x.isFinite,original.y.isFinite,original.transition.isFinite else{continue}
        var value=original
        value.start=max(0,min(duration,value.start));value.end=max(0,min(duration,value.end))
        guard value.end-value.start>=0.1 else{continue}
        value.scale=max(1,min(6,value.scale));value.x=max(0,min(1,value.x));value.y=max(0,min(1,value.y))
        value.transition=max(0,min(2,min((value.end-value.start)/2,value.transition)))
        if ids.contains(value.id){value.id=UUID()}
        ids.insert(value.id);result.append(value)
    }
    return result
}
func zoomPose(at time: Double, clips: [ZoomClip]) -> ZoomPose {
    guard let z = clips.sorted(by:{$0.start < $1.start}).last(where: { time >= $0.start && time <= $0.end }) else { return ZoomPose() }
    let ramp = max(0,min(z.transition,(z.end-z.start)/2))
    var weight = ramp > 0 ? min(1,max(0,min((time-z.start)/ramp,(z.end-time)/ramp))) : 1
    if z.smooth { weight = weight*weight*(3-2*weight) }
    return ZoomPose(scale:1+(max(1,min(6,z.scale))-1)*weight,x:z.x,y:z.y)
}
@MainActor extension Studio {
    func selectAutomaticZoom(_ clip:ZoomClip) {
        let generated=autoZoomClips(samples:timelinePointerSamples,settings:motion,duration:duration,typing:timelineTypingTimes)
        zooms.append(contentsOf:generated)
        selectedZoom=generated.first(where:{abs($0.start-clip.start)<0.001 && abs($0.end-clip.end)<0.001})?.id
        timelineFocus = .zoom
        motion.autoZoom=false
        player.pause();playing=false;position=(clip.start+clip.end)/2;seek(position)
    }
    /// Length a click on an empty spot of the zoom track adds, so the hover preview and the click agree.
    static let draftZoomLength = 1.0
    /// The zoom a click at this time would add: a short slice that starts there and stays inside the timeline.
    func draftZoomRange(at time:Double)->TimelineRange {
        let length=min(Studio.draftZoomLength,max(0.2,duration))
        let start=max(0,min(max(0,duration-length),time))
        return TimelineRange(start:start,end:min(duration,start+length))
    }
    /// Adds a zoom drawn on the timeline and selects it.
    @discardableResult func addZoom(over range:TimelineRange)->UUID? {
        guard duration > 0, stillImage == nil else { return nil }
        let start=max(0,min(duration-0.1,range.start)),end=min(duration,max(start+0.1,range.end))
        let clip=ZoomClip(start:start,end:end,transition:min(0.5,(end-start)/2))
        zooms.append(clip); focusTimeline(.zoom,id:clip.id)
        player.pause(); playing=false
        position=start+min(clip.transition,(end-start)/2); seek(position)
        return clip.id
    }
    func addZoom() {
        guard duration > 0, stillImage == nil else { return }
        let start = min(max(position,trimStart),max(trimStart,trimEnd-0.2))
        let end = min(start+3,trimEnd)
        guard end > start else { return }
        let clip = ZoomClip(start:start,end:end)
        zooms.append(clip); selectedZoom = clip.id; timelineFocus = .zoom
        player.pause(); playing = false
        position = min(end,start+min(0.5,(end-start)/2)); seek(position)
        flash("Zoom added · drag its edges in the timeline")
    }
}
struct ZoomInspector: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Button("Add Zoom at Playhead") { studio.addZoom() }.disabled(studio.stillImage != nil || studio.duration <= 0)
            // Every control binds by id: deleting the selected zoom while the panel is open would leave a stale index behind.
            if let zoom = studio.zooms.first(where:{$0.id == studio.selectedZoom}) {
                let id = zoom.id
                Text("Choose the target by clicking the video or dragging in the area below.").font(.caption).foregroundStyle(.secondary)
                GeometryReader { geo in
                    ZStack {
                        RoundedRectangle(cornerRadius:8).fill(.white.opacity(0.07))
                        Path { p in p.move(to:CGPoint(x:0,y:geo.size.height/2));p.addLine(to:CGPoint(x:geo.size.width,y:geo.size.height/2));p.move(to:CGPoint(x:geo.size.width/2,y:0));p.addLine(to:CGPoint(x:geo.size.width/2,y:geo.size.height)) }.stroke(.white.opacity(0.15))
                        RoundedRectangle(cornerRadius:3).stroke(accent,lineWidth:2)
                            .frame(width:geo.size.width/zoom.scale,height:geo.size.height/zoom.scale)
                            .position(x:geo.size.width*zoom.x,y:geo.size.height*zoom.y)
                    }.clipped().contentShape(Rectangle()).gesture(DragGesture(minimumDistance:0).onChanged { v in
                        studio.update(\.zooms,id:id) { $0.x=min(1,max(0,v.location.x/geo.size.width));$0.y=min(1,max(0,v.location.y/geo.size.height)) }
                    })
                }.frame(height:125)
                field("Start (s)",value:studio.binding(\.zooms,id:id,\.start,fallback:zoom.start,clamp:{ [weak studio] in max(0,min($0,(studio?.zooms.first{$0.id == id}?.end ?? 0)-0.1)) }))
                field("End (s)",value:studio.binding(\.zooms,id:id,\.end,fallback:zoom.end,clamp:{ [weak studio] in min(studio?.duration ?? 0,max($0,(studio?.zooms.first{$0.id == id}?.start ?? 0)+0.1)) }))
                Text(String(format:"Scale · %.2f×",zoom.scale)).font(.caption)
                Slider(value:studio.binding(\.zooms,id:id,\.scale,fallback:zoom.scale),in:1...6)
                Text(String(format:"Transition · %.2f s",zoom.transition)).font(.caption)
                Slider(value:studio.binding(\.zooms,id:id,\.transition,fallback:zoom.transition),in:0...2)
                Toggle("Smooth Transition",isOn:studio.binding(\.zooms,id:id,\.smooth,fallback:zoom.smooth))
                Button("Center Target") { studio.update(\.zooms,id:id) { $0.x=0.5;$0.y=0.5 } }
                Button("Delete Zoom",role:.destructive) { studio.deleteTimelineItem(.zoom,id:id) }
            } else { Text("Select a purple zoom block in the timeline to edit it.").font(.caption).foregroundStyle(.secondary) }
        }
    }
    func field(_ label:String,value:Binding<Double>) -> some View {
        HStack { Text(label).font(.caption); TextField(label,value:value,format:.number.precision(.fractionLength(2))).textFieldStyle(.roundedBorder).frame(width:85) }
    }
}
