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
    return ["PASS region camera stays steady and motion agrees across 30/120 Hz recording traces",
            "PASS playhead updates reuse motion paths and automatic zoom identities; new samples invalidate them",
            String(format:"PASS planned motion exports 720p / 60 fps / %.2f s in %.2f s",duration,elapsed)]
}
