import AVFoundation
import Foundation

@MainActor func verifyFocusExperience(folder:URL) async throws->[String] {
    func require(_ condition:Bool,_ message:String) throws {
        if !condition {throw NSError(domain:"Lumio",code:91,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    let settings=MotionSettings(),viewport=CGSize(width:0.5,height:0.5)
    func trace(_ fps:Int)->[PointerSample] {
        (0...fps*4).map {i in
            let t=Double(i)/Double(fps)
            return PointerSample(time:t,x:t<1 ? 0.2:t<2 ? 0.2+(t-1)*0.6:0.8,y:0.5,pressed:false)
        }
    }
    let camera30=plannedCameraPath(trace(30),settings:settings,viewport:viewport)
    let camera120=plannedCameraPath(trace(120),settings:settings,viewport:viewport)
    let cursor30=smoothPointer(trace(30),settings:settings),cursor120=smoothPointer(trace(120),settings:settings)
    for i in 0...240 {
        let t=Double(i)/60
        try require(abs(pointerAt(t,samples:camera30)!.x-pointerAt(t,samples:camera120)!.x)<0.001,"camera planning changed with event sampling rate")
        try require(abs(pointerAt(t,samples:cursor30)!.x-pointerAt(t,samples:cursor120)!.x)<0.001,"cursor smoothing changed with event sampling rate")
    }
    let jitter=(0...240).map {i in PointerSample(time:Double(i)/60,x:0.5+sin(Double(i))*0.007,y:0.5,pressed:false)}
    let stable=plannedCameraPath(jitter,settings:settings,viewport:viewport)
    try require(stable.allSatisfy{abs($0.x-0.5)<0.001},"local jitter moved the camera")
    let studio=Studio();studio.preferences.revealExport=false
    await studio.load(folder.appendingPathComponent("sample.mp4"))
    defer {studio.previewTask?.cancel()}
    studio.look=Look();studio.look.exportHeight=720;studio.motion=settings
    studio.pointerSamples=(0...180).map {i in
        let t=Double(i)/60
        return PointerSample(time:t,x:t<1 ? 0.2:min(0.8,0.2+(t-1)*0.6),y:0.5,pressed:i==30 || i==96)
    }
    let automatic=studio.plannedAutomaticZooms
    studio.position=1.2
    try require(!automatic.isEmpty && automatic==studio.plannedAutomaticZooms,"playhead updates rebuilt automatic block identities")
    let paths=studio.motionPaths(viewport:viewport)
    let reused=studio.motionPaths(viewport:viewport)
    let sameStorage=paths.camera.withUnsafeBufferPointer {a in reused.camera.withUnsafeBufferPointer {b in a.baseAddress==b.baseAddress}}
    try require(sameStorage,"unchanged motion paths were rebuilt")
    studio.pointerSamples[0].x=0.15
    try require(studio.motionPaths(viewport:viewport).generation != paths.generation,"changed pointer data used an old motion path")
    let begin=ProcessInfo.processInfo.systemUptime
    studio.exportSettings=ExportSettings(format:"MP4",codec:"H.264",fps:60,copyToClipboard:false)
    let url=folder.appendingPathComponent("verified-focus-60fps.mp4")
    await studio.export(to:url)
    try require(studio.message==nil,"planned motion export failed: \(studio.message ?? "unknown")")
    let asset=AVURLAsset(url:url)
    guard let track=try await asset.loadTracks(withMediaType:.video).first else {throw studio.failure("focus export has no video")}
    let rate=try await track.load(.nominalFrameRate),duration=try await asset.load(.duration).seconds
    try require(rate>=59 && abs(duration-3)<0.05,"focus export lost its 60 fps presentation clock or duration")
    let elapsed=ProcessInfo.processInfo.systemUptime-begin
    // What "smooth" actually means here, in numbers: the camera must leave early, arrive without
    // swinging past its target, and settle in a time a viewer reads as deliberate rather than abrupt.
    // A jump between two resting places is the move the whole feature is built around.
    func step(_ hold:Double=1.2)->[PointerSample] {
        var path:[PointerSample]=[]
        var time=0.0
        while time<hold { path.append(PointerSample(time:time,x:0.25,y:0.5,pressed:false));time+=1/60 }
        path.append(PointerSample(time:time,x:0.25,y:0.5,pressed:true,shape:"arrow",clickEdge:true))
        time+=1/60
        while time<hold*2.6 { path.append(PointerSample(time:time,x:0.78,y:0.5,pressed:false));time+=1/60 }
        return path
    }
    func describe(_ motionStyle:String)->(lead:Double,settle:Double,overshoot:Double,jerk:Double) {
        var tuned=MotionSettings();tuned.motion=motionStyle
        let planned=plannedCameraPath(step(),settings:tuned,viewport:viewport)
        let jump=1.2, target=0.78, from=0.25
        let moving=planned.filter{ $0.time>=jump-0.6 }
        // When it starts: the first sample that has covered a fiftieth of the distance.
        let lead=(moving.first{ abs($0.x-from)>(target-from)*0.02 }?.time ?? jump)-jump
        // When it is there: the last moment it is still more than two percent away.
        let settle=((moving.last{ abs($0.x-target)>(target-from)*0.02 }?.time ?? jump)-jump)
        let overshoot=max(0,(moving.map(\.x).max() ?? target)-target)/(target-from)
        // Jerk is read off an evenly spaced resampling of the path. The planned path deliberately keeps
        // the recording's own event times as well as its fixed clock, so differencing it as-is measures
        // the uneven spacing rather than the motion.
        var jerk=0.0
        let dt=1.0/60
        var xs:[Double]=[]
        var clock=(moving.first?.time ?? 0)
        let endTime=(moving.last?.time ?? 0)
        while clock<=endTime { xs.append(pointerAt(clock,samples:planned)?.x ?? target);clock+=dt }
        if xs.count>3 {
            for index in 3..<xs.count {
                let third=(xs[index]-3*xs[index-1]+3*xs[index-2]-xs[index-3])/(dt*dt*dt)
                jerk=max(jerk,abs(third))
            }
        }
        return (lead,settle,overshoot,jerk)
    }
    let focused=describe("focused"), fluid=describe("fluid")
    try require(focused.lead < -0.05,"the focused camera does not leave before the pointer does: \(focused.lead) s")
    try require(fluid.lead < -0.05,"the fluid camera does not leave before the pointer does: \(fluid.lead) s")
    try require(focused.overshoot<0.005 && fluid.overshoot<0.005,"the camera swings past its target: \(focused.overshoot) / \(fluid.overshoot)")
    // The move is measured from the moment it leaves to the moment it arrives, because the camera sets
    // off before the pointer does; counting only from the jump would call an anticipated move instant.
    let focusedMove=focused.settle-focused.lead, fluidMove=fluid.settle-fluid.lead
    try require(focusedMove>0.3 && focusedMove<1.2,"the focused move takes \(focusedMove) s, outside the range that reads as deliberate")
    try require(fluidMove>focusedMove+0.08,"fluid is not calmer than focused: \(fluidMove) vs \(focusedMove) s")
    try require(fluidMove<2.0,"the fluid move takes \(fluidMove) s, which reads as lag")
    // Handing the spring a stepped goal measures about 2500 per s³ here; the eased goal has to stay far
    // below that, because the opening yank is the part of the move that reads as abrupt.
    try require(focused.jerk<700 && fluid.jerk<700,"the camera starts too sharply: \(focused.jerk) / \(fluid.jerk) per s³")
    // Clicks spaced so that their zooms almost touch must not make the view bounce out and back in.
    var pumping=MotionSettings()
    let clicks=[0.6,3.4,6.0].map { at in PointerSample(time:at,x:0.3,y:0.4,pressed:true,shape:"arrow",clickEdge:true) }
    var pumpTrace:[PointerSample]=[]
    var tick=0.0
    while tick<8 {
        if let click=clicks.first(where:{ abs($0.time-tick)<0.009 }) { pumpTrace.append(click) }
        else { pumpTrace.append(PointerSample(time:tick,x:0.3,y:0.4,pressed:false)) }
        tick+=1/60
    }
    let automaticZooms=autoZoomClips(samples:pumpTrace,settings:pumping,duration:8)
    for pair in zip(automaticZooms,automaticZooms.dropFirst()) {
        try require(pair.1.start-pair.0.end>=0.8-0.0001,"two automatic zooms sit \(pair.1.start-pair.0.end) s apart, which pumps the view out and back in")
    }
    pumping.autoZoom=false
    try require(autoZoomClips(samples:pumpTrace,settings:pumping,duration:8).isEmpty,"automatic zooms were planned with the feature off")
    return [String(format:"PASS camera leaves %.0f/%.0f ms early and completes the move in %.2f/%.2f s with no overshoot, peak jerk %.0f/%.0f per s³ (focused/fluid)",
                   -focused.lead*1000,-fluid.lead*1000,focusedMove,fluidMove,focused.jerk,fluid.jerk),
            "PASS region camera stays steady and motion agrees across 30/120 Hz recording traces",
            "PASS playhead updates reuse motion paths and automatic zoom identities; new samples invalidate them",
            String(format:"PASS planned motion exports 720p / 60 fps / %.2f s in %.2f s",duration,elapsed)]
}
