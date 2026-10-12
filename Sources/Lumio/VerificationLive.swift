import AVFoundation
import AppKit

@MainActor func verifyLivePreview(folder:URL) async throws->[String] {
    func require(_ condition:Bool,_ message:String) throws {
        if !condition {throw NSError(domain:"Lumio.live",code:93,userInfo:[NSLocalizedDescriptionKey:message])}
    }
    let studio=Studio(),probe=PreviewFrameProbe()
    studio.previewProbe=probe;studio.previewQuality=1
    await studio.load(folder.appendingPathComponent("sample.mp4"))
    studio.captions=[CaptionCue(start:0,end:3,text:"Initial live caption")]
    studio.refreshComposition()
    await studio.previewTask?.value
    guard let item=studio.player.currentItem else {throw studio.failure("live preview has no player item")}
    let output=AVPlayerItemVideoOutput(pixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    item.add(output)
    let layer=AVPlayerLayer(player:studio.player)
    layer.frame=CGRect(x:0,y:0,width:640,height:360)
    let window=NSWindow(contentRect:layer.frame,styleMask:[.borderless],backing:.buffered,defer:false)
    window.contentView?.wantsLayer=true;window.contentView?.layer?.addSublayer(layer)
    window.orderBack(nil)
    defer {studio.player.pause();studio.previewTask?.cancel();window.close()}
    for _ in 0..<150 {
        if item.status == .readyToPlay {break}
        try await Task.sleep(for:.milliseconds(20))
    }
    try require(item.status == .readyToPlay,"live preview did not become ready")
    await studio.player.seek(to:CMTime(seconds:1,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)
    studio.position=1;studio.previousSnapshot=studio.snapshot
    try await Task.sleep(for:.milliseconds(150))
    let firstRevision=studio.previewVisualRevision
    var preparation:[Double]=[]
    for step in 0..<60 {
        let begin=ProcessInfo.processInfo.systemUptime
        studio.look.padding=4+Double(step%30)*0.55
        studio.look.radius=Double(step%20)*3
        studio.recordEdit()
        preparation.append(ProcessInfo.processInfo.systemUptime-begin)
        try require(studio.player.currentItem === item && studio.previewTask == nil,"a visual slider rebuilt or replaced the media timeline")
        try await Task.sleep(for:.milliseconds(16))
    }
    try await Task.sleep(for:.milliseconds(180))
    let frames=probe.samples.filter{$0.revision>firstRevision}
    let revisions=Set(frames.map(\.revision))
    try require(revisions.count>=10,"continuous slider changes rendered only \(revisions.count) intermediate frames")
    try require(frames.contains{$0.revision==studio.previewVisualRevision},"the last slider value did not render while paused")
    try require(abs(studio.player.currentTime().seconds-1)<0.04,"visual editing moved the paused playhead")
    studio.captions=[CaptionCue(start:0,end:3,text:"First live caption")]
    studio.refreshComposition()
    let withCaption=item.videoComposition!.instructions.first as! FrameInstruction
    studio.captions[0].text="Changed live caption";studio.refreshComposition()
    let changedCaption=item.videoComposition!.instructions.first as! FrameInstruction
    try require(studio.player.currentItem === item && withCaption.design.overlays !== changedCaption.design.overlays,"edited caption text used stale artwork or rebuilt the timeline")
    let automaticIDs=studio.plannedAutomaticZooms.map(\.id)
    let pathKey=studio.motion.pathPlanningSettings
    studio.motion.size=150;studio.look.shadow=70;studio.look.glow=25;studio.keyboardStyle.size=120
    studio.refreshComposition()
    try require(studio.motion.pathPlanningSettings==pathKey && studio.plannedAutomaticZooms.map(\.id)==automaticIDs,"appearance controls invalidated motion planning or automatic block identities")
    let changed=item.videoComposition!.instructions.first as! FrameInstruction
    try require(changed.design.settings.size==150 && changed.design.keyboardStyle.size==120,"live visual state did not reach the compositor")
    let playingStart=studio.player.currentTime().seconds
    studio.playing=true;studio.player.play()
    for step in 0..<15 {
        studio.look.padding=Double(step)+5;studio.refreshComposition()
        try require(studio.player.currentItem === item,"playing visual edits replaced the player")
        try await Task.sleep(for:.milliseconds(20))
    }
    studio.player.pause();studio.playing=false
    try require(studio.player.currentTime().seconds>playingStart+0.1,"visual edits stalled playback")
    studio.videoClips[0].speed=2;studio.synchronizeVideoSequence(refresh:false);studio.refreshComposition()
    await studio.previewTask?.value
    try require(studio.player.currentItem !== item,"a speed edit incorrectly reused the old media timeline")
    let times=frames.map(\.latency).sorted(),prepare=preparation.sorted()
    let p95=times[min(times.count-1,Int(Double(times.count)*0.95))]
    return [String(format:"PASS paused 720p preview rendered %d intermediate revisions during 60 slider changes; p95 compositor latency %.1f ms, p95 preparation %.1f ms",revisions.count,p95*1000,prepare[Int(Double(prepare.count)*0.95)]*1000),
        "PASS live caption, cursor, shadow, glow and shortcut updates reuse the player and invalidate changed artwork",
        "PASS playing visual edits advance without replacing the player; speed edits rebuild their media timeline"]
}

@MainActor func verifyLivePreviewOnly(folder:URL) async {
    do {for line in try await verifyLivePreview(folder:folder) {print(line)};exit(0)}
    catch {print("FAIL \(error.localizedDescription)");exit(2)}
}
