import Foundation

/// A fixed presentation clock makes sparse event recordings and dense mouse traces behave alike.
/// Real cut boundaries are retained exactly; a gap ending in a reset is never filled with motion.
func presentationPointerSamples(_ samples:[PointerSample],fps:Double=60)->[PointerSample] {
    guard let first=samples.first,let last=samples.last,samples.count>1 else{return samples}
    let step=max(1/max(1,fps),max(0,last.time-first.time)/500_000)
    var result=[first],tick=first.time+step
    for index in 1..<samples.count {
        let a=samples[index-1],b=samples[index]
        guard b.time>a.time else{continue}
        if b.motionReset == true {
            // Keep the outgoing tail and incoming cut, without interpolating through missing footage.
            if result.last!.time<a.time {result.append(a)}
            result.append(b);tick=b.time+step;continue
        }
        while tick<b.time-0.0000001 {
            let u=max(0,min(1,(tick-a.time)/(b.time-a.time)))
            result.append(PointerSample(time:tick,x:a.x+(b.x-a.x)*u,y:a.y+(b.y-a.y)*u,pressed:a.pressed,shape:a.shape,clickEdge:false))
            tick+=step
        }
        // Retain recorded event times/shapes. These samples are only positions; clicks use the raw path.
        if b.pressed != a.pressed || b.shape != a.shape || index == samples.count-1 {
            if result.last!.time<b.time {result.append(b)}
        }
    }
    return result
}

struct FocusRegion {
    var start:Double
    var x:Double
    var y:Double
    var reset:Bool
    var click:Bool
}

/// Offline planning: nearby activity shares one resting target, weighted by time spent there.
/// Camera travel begins before a new region and settles on clicks; no pointer spring is reused.
func focusRegions(_ samples:[PointerSample],viewport:CGSize)->[FocusRegion] {
    guard !samples.isEmpty else{return []}
    let width=max(0.025,min(1,viewport.width)),height=max(0.025,min(1,viewport.height))
    var regions:[FocusRegion]=[]
    var start=0,minX=0.0,maxX=0.0,minY=0.0,maxY=0.0,weightedX=0.0,weightedY=0.0,weight=0.0
    var first:PointerSample?
    var pendingReset=false
    func flush() {
        guard let first else{return}
        var x=weight>0 ? weightedX/weight:first.x,y=weight>0 ? weightedY/weight:first.y
        // Tiny local activity keeps the initial framing instead of shifting toward its average.
        if maxX-minX<width*0.18 && maxY-minY<height*0.18 {x=first.x;y=first.y}
        regions.append(FocusRegion(start:samples[start].time,x:x,y:y,reset:first.motionReset == true,click:first.clickEdge ?? first.pressed))
    }
    for (index,sample) in samples.enumerated() {
        if sample.motionReset == true {flush();first=nil;pendingReset=true}
        guard sample.x>=0,sample.x<=1,sample.y>=0,sample.y<=1 else{continue}
        if first != nil && (sample.motionReset == true || max(maxX,sample.x)-min(minX,sample.x)>width*0.58+0.000000001 || max(maxY,sample.y)-min(minY,sample.y)>height*0.58+0.000000001) {
            flush();first=nil
        }
        if first == nil {var anchor=sample;anchor.motionReset=pendingReset ? true:sample.motionReset;first=anchor;pendingReset=false;start=index;minX=sample.x;maxX=sample.x;minY=sample.y;maxY=sample.y;weightedX=0;weightedY=0;weight=0}
        minX=min(minX,sample.x);maxX=max(maxX,sample.x);minY=min(minY,sample.y);maxY=max(maxY,sample.y)
        let next=index+1<samples.count ? samples[index+1].time:sample.time+1/60
        let dwell=max(0.000001,next-sample.time)+(sample.clickEdge == true ? 0.12:0)
        weightedX+=sample.x*dwell;weightedY+=sample.y*dwell;weight+=dwell
    }
    flush();return regions
}

func plannedCameraPath(_ samples:[PointerSample],settings:MotionSettings,viewport:CGSize)->[PointerSample] {
    let path=presentationPointerSamples(samples)
    let regions=focusRegions(path,viewport:viewport)
    guard !regions.isEmpty else{return samples}
    let omega=settings.motion == "fluid" ? 11.0:16.0
    let lead=settings.motion == "fluid" ? 0.28:0.22
    var region=0,x=regions[0].x,y=regions[0].y,vx=0.0,vy=0.0,previous=path[0].time
    return path.map {input in
        while region+1<regions.count && input.time>=regions[region+1].start {region+=1}
        var target=region
        while target+1<regions.count && !regions[target+1].reset && input.time+lead>=regions[target+1].start {target+=1}
        let goal=regions[target],dt=max(0,input.time-previous);previous=input.time
        if input.motionReset == true {x=input.x;y=input.y;vx=0;vy=0}
        else {
            // Exact critically damped spring step: independent of sampling cadence and never overshoots.
            let decay=exp(-omega*dt),dx=x-goal.x,dy=y-goal.y
            let ax=vx+omega*dx,ay=vy+omega*dy
            x=goal.x+(dx+ax*dt)*decay;y=goal.y+(dy+ay*dt)*decay
            vx=(vx-omega*ax*dt)*decay;vy=(vy-omega*ay*dt)*decay
        }
        var output=input;output.x=min(1,max(0,x));output.y=min(1,max(0,y));return output
    }
}

extension MotionSettings {
    /// Appearance controls do not change the recorded path or automatic block identities.
    var automaticPlanningSettings:MotionSettings {
        var key=MotionSettings()
        key.autoZoom=autoZoom;key.zoom=zoom;key.keepZoomed=keepZoomed;key.zoomOnTyping=zoomOnTyping
        return key
    }
    var pathPlanningSettings:MotionSettings {
        var key=automaticPlanningSettings
        key.motion=motion;key.smoothing=smoothing;key.cursorAnimation=cursorAnimation
        key.stiffness=stiffness;key.damping=damping;key.mass=mass
        key.shakeFilter=shakeFilter;key.threshold=threshold
        return key
    }
}

struct MotionPathCache {
    var generation:Int
    var clips:[VideoClip]
    var crop:CGRect
    var settings:MotionSettings
    var viewport:CGSize
    var duration:Double
    var cursor:[PointerSample]
    var camera:[PointerSample]
    var automatic:[ZoomClip]
}

@MainActor extension Studio {
    func motionPaths(viewport:CGSize)->MotionPathCache {
        let crop=(look.videoStyle ?? VideoStyle()).cropRect
        if let cache=motionPathCache,cache.generation==sampleGeneration,cache.clips==videoClips,cache.crop==crop,cache.settings==motion.pathPlanningSettings,cache.viewport==viewport,cache.duration==duration {return cache}
        let raw=timelinePointerSamples
        let cache=MotionPathCache(generation:sampleGeneration,clips:videoClips,crop:crop,settings:motion.pathPlanningSettings,viewport:viewport,duration:duration,
            cursor:smoothPointer(raw,settings:motion),camera:plannedCameraPath(raw,settings:motion,viewport:viewport),
            automatic:plannedAutomaticZooms)
        motionPathCache=cache;return cache
    }
}

struct AutomaticZoomCache {
    var generation:Int
    var clips:[VideoClip]
    var crop:CGRect
    var settings:MotionSettings
    var duration:Double
    var zooms:[ZoomClip]
}
@MainActor extension Studio {
    /// Keep automatic block identities and click analysis stable while the playhead advances.
    var plannedAutomaticZooms:[ZoomClip] {
        let crop=(look.videoStyle ?? VideoStyle()).cropRect
        if let cache=automaticZoomCache,cache.generation==sampleGeneration,cache.clips==videoClips,cache.crop==crop,cache.settings==motion.automaticPlanningSettings,cache.duration==duration {return cache.zooms}
        let zooms=autoZoomClips(samples:timelinePointerSamples,settings:motion,duration:duration,typing:timelineTypingTimes)
        automaticZoomCache=AutomaticZoomCache(generation:sampleGeneration,clips:videoClips,crop:crop,settings:motion.automaticPlanningSettings,duration:duration,zooms:zooms)
        return zooms
    }
}
