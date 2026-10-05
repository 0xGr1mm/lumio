import AVFoundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ExportSettings: Codable, Equatable {
    var format: String? = "MP4"
    var codec: String? = "H.264"
    var fps: Int? = 60
    var copyToClipboard: Bool? = false
    var resolvedFormat: String { ["MP4","MOV","GIF"].contains(format ?? "") ? format! : "MP4" }
    var resolvedCodec: String { ["HEVC","ProRes 4444"].contains(codec ?? "") ? codec! : "H.264" }
    /// ProRes 4444 keeps transparency; it is only offered for MOV.
    var keepsTransparency: Bool { resolvedFormat == "MOV" && resolvedCodec == "ProRes 4444" }
    var resolvedFPS: Int { [24,30,60].contains(fps ?? 0) ? fps! : 60 }
    var contentType: UTType { resolvedFormat == "MOV" ? .quickTimeMovie : resolvedFormat == "GIF" ? .gif : .mpeg4Movie }
    var fileExtension: String { resolvedFormat.lowercased() }
    static func stored() -> ExportSettings {
        guard let data = UserDefaults.standard.data(forKey:"exportSettings"), let value = try? JSONDecoder().decode(ExportSettings.self,from:data) else { return ExportSettings() }
        return value
    }
    func store() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data,forKey:"exportSettings") } }
}

/// Resumes a continuation once, whichever of the export's completion handler or the cancellation fallback comes first.
private final class ExportResumer:@unchecked Sendable {
    private let lock=NSLock()
    private var continuation:CheckedContinuation<Void,Error>?
    func arm(_ continuation:CheckedContinuation<Void,Error>) { lock.lock();self.continuation=continuation;lock.unlock() }
    func resume(_ result:Result<Void,Error>) {
        lock.lock();let pending=continuation;continuation=nil;lock.unlock()
        pending?.resume(with:result)
    }
}

/// Runs an export so cancelling the task always ends it. The async `export(to:as:)` can fail to return
/// when its task is cancelled mid-export, and `cancelExport()` sometimes never calls the completion handler either,
/// so a cancelled export also ends on its own two seconds after cancelling.
func runExport(_ session:AVAssetExportSession,to url:URL,as fileType:AVFileType) async throws {
    try Task.checkCancellation()
    session.outputURL = url
    session.outputFileType = fileType
    let resumer = ExportResumer()
    try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
            resumer.arm(continuation)
            session.exportAsynchronously {
                switch session.status {
                case .completed: resumer.resume(.success(()))
                case .cancelled: resumer.resume(.failure(CancellationError()))
                default: resumer.resume(.failure(session.error ?? NSError(domain:"Lumio",code:70,userInfo:[NSLocalizedDescriptionKey:"The export did not finish."])))
                }
            }
            // Cancelled between the check above and starting: the cancellation handler has already run.
            if Task.isCancelled { session.cancelExport();resumer.resume(.failure(CancellationError())) }
        }
    } onCancel: {
        session.cancelExport()
        DispatchQueue.global().asyncAfter(deadline:.now()+2) { resumer.resume(.failure(CancellationError())) }
    }
}

func srtTimestamp(_ seconds:Double)->String {
    let total = Int((max(0,seconds.isFinite ? seconds : 0)*1000).rounded())
    return String(format:"%02d:%02d:%02d,%03d",total/3_600_000,(total/60_000)%60,(total/1000)%60,total%1000)
}

func srtDocument(_ cues:[CaptionCue])->String {
    cues.sorted { $0.start < $1.start }.enumerated().map { index, cue in
        "\(index+1)\n\(srtTimestamp(cue.start)) --> \(srtTimestamp(cue.end))\n\(cue.text)\n"
    }.joined(separator:"\n")
}

@MainActor extension Studio {
    func writeGIF(asset:AVAsset,composition:AVVideoComposition,size:CGSize,to url:URL) async throws {
        let span = exportRange ?? (0,duration)
        let length = max(0.04,span.end-span.start)
        let fps = length > 30 ? 10.0 : 15.0
        let frames = max(1,Int((length*fps).rounded(.up)))
        guard frames <= 1_800 else { throw failure("GIF export is limited to 3 minutes. Trim the timeline or export a video.") }
        let scale = min(1,960/max(1,size.width))
        let generator = AVAssetImageGenerator(asset:asset)
        generator.videoComposition = composition
        generator.maximumSize = CGSize(width:(size.width*scale).rounded(),height:(size.height*scale).rounded())
        let tolerance = CMTime(seconds:0.5/fps,preferredTimescale:600)
        generator.requestedTimeToleranceBefore = tolerance; generator.requestedTimeToleranceAfter = tolerance
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.gif.identifier as CFString,frames,nil) else { throw failure("The GIF file could not be created.") }
        CGImageDestinationSetProperties(destination,[kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFLoopCount:0]] as CFDictionary)
        let delay = 1/fps
        let frameProperties = [kCGImagePropertyGIFDictionary:[kCGImagePropertyGIFDelayTime:delay,kCGImagePropertyGIFUnclampedDelayTime:delay]] as CFDictionary
        for index in 0..<frames {
            try Task.checkCancellation()
            let time = CMTime(seconds:span.start+min(max(0,length-0.001),Double(index)/fps),preferredTimescale:600)
            let image = try await generator.image(at:time).image
            CGImageDestinationAddImage(destination,image,frameProperties)
            exportProgress = Double(index+1)/Double(frames)
        }
        guard CGImageDestinationFinalize(destination) else { throw failure("The GIF could not be finalized.") }
    }
    func exportCaptions() {
        guard !captions.isEmpty else { message = "Generate or add captions before exporting subtitles."; return }
        let save = NSSavePanel(); save.allowedContentTypes = [UTType(filenameExtension:"srt") ?? .plainText]
        save.nameFieldStringValue = "\(source?.deletingPathExtension().lastPathComponent ?? "Lumio").srt"
        guard save.runModal() == .OK, let url = save.url else { return }
        do { try srtDocument(captions).write(to:url,atomically:true,encoding:.utf8) } catch { message = error.localizedDescription }
    }
}

/// Ready-made settings for where a recording is going: canvas shape, size, file type and frame rate.
struct ExportPreset: Identifiable {
    var id: String
    var detail: String
    var aspect: String
    var height: Int
    var format: String
    var codec: String
    var fps: Int
    var autoReframe: Bool
}

let exportPresets: [ExportPreset] = [
    ExportPreset(id:"YouTube · 1080p",detail:"16:9 · MP4 · 60 fps",aspect:"16:9",height:1080,format:"MP4",codec:"H.264",fps:60,autoReframe:false),
    ExportPreset(id:"YouTube · 4K",detail:"16:9 · MP4 · HEVC · 60 fps",aspect:"16:9",height:2160,format:"MP4",codec:"HEVC",fps:60,autoReframe:false),
    ExportPreset(id:"TikTok, Reels & Shorts",detail:"9:16 · 1080 × 1920 · 30 fps",aspect:"9:16",height:1920,format:"MP4",codec:"H.264",fps:30,autoReframe:true),
    ExportPreset(id:"Instagram Feed",detail:"1:1 · 1080 × 1080 · 30 fps",aspect:"1:1",height:1080,format:"MP4",codec:"H.264",fps:30,autoReframe:true),
    ExportPreset(id:"LinkedIn & X",detail:"16:9 · 1080p · 30 fps",aspect:"16:9",height:1080,format:"MP4",codec:"H.264",fps:30,autoReframe:false),
    ExportPreset(id:"Looping GIF",detail:"16:9 · 720p",aspect:"16:9",height:720,format:"GIF",codec:"H.264",fps:30,autoReframe:false)
]

@MainActor extension Studio {
    /// The stretch to export, once both ends are set and they make sense. Nil means the whole timeline.
    var exportRange:(start:Double,end:Double)? {
        guard duration>0,let first=exportStart,let last=exportEnd,first.isFinite,last.isFinite else { return nil }
        let start=max(0,min(duration,min(first,last))),end=max(0,min(duration,max(first,last)))
        return end-start>=0.2 ? (start,end):nil
    }
    var exportLength:Double { exportRange.map { $0.end-$0.start } ?? duration }
    func setExportIn() {
        guard duration>0 else { return }
        exportStart=max(0,min(duration,position))
        if let end=exportEnd,end<=exportStart!+0.2 { exportEnd=nil }
        flash(String(format:"In at %.1f s",exportStart ?? 0))
    }
    func setExportOut() {
        guard duration>0 else { return }
        exportEnd=max(0,min(duration,position))
        if let start=exportStart,start>=exportEnd!-0.2 { exportStart=nil }
        flash(String(format:"Out at %.1f s",exportEnd ?? 0))
    }
    func clearExportRange() { exportStart=nil;exportEnd=nil;flash("Exporting the whole timeline again") }

    /// Applies a preset. Auto reframe is only turned on for a tall or square canvas holding a wide recording,
    /// where it is the difference between filling the frame and bars on both sides.
    func applyExportPreset(_ preset:ExportPreset) {
        look.aspect = preset.aspect
        look.exportHeight = preset.height
        exportSettings.format = preset.format
        exportSettings.codec = preset.codec
        exportSettings.fps = preset.fps
        exportSettings.store()
        if stillImage == nil { look.autoReframe = preset.autoReframe && mediaAspect > 1.2 }
        refreshComposition()
        flash("Set up for \(preset.id)")
    }
}

/// Writes a movie that keeps its transparency. ProRes 4444 carries an alpha channel, which the usual
/// H.264 and HEVC exports cannot, so this path reads the composed frames and writes them itself.
@MainActor func writeTransparentMovie(asset:AVAsset,composition:AVMutableVideoComposition,audioMix:AVAudioMix?,duration:Double,from start:Double=0,to url:URL,progress:@escaping @MainActor (Double)->Void) async throws {
    try? FileManager.default.removeItem(at:url)
    let reader=try AVAssetReader(asset:asset)
    let begin=CMTime(seconds:max(0,start),preferredTimescale:600)
    reader.timeRange=CMTimeRange(start:begin,duration:CMTime(seconds:max(0.04,duration),preferredTimescale:600))
    let videoTracks=try await asset.loadTracks(withMediaType:.video)
    guard !videoTracks.isEmpty else { throw NSError(domain:"Lumio",code:71,userInfo:[NSLocalizedDescriptionKey:"There is no video to export."]) }
    let videoOutput=AVAssetReaderVideoCompositionOutput(videoTracks:videoTracks,videoSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    videoOutput.videoComposition=composition
    // The writer holds each frame while it encodes; copying lets the compositor's buffer pool recycle instead of stalling.
    videoOutput.alwaysCopiesSampleData=true
    guard reader.canAdd(videoOutput) else { throw NSError(domain:"Lumio",code:72,userInfo:[NSLocalizedDescriptionKey:"The transparent export could not read the video."]) }
    reader.add(videoOutput)

    var audioOutput:AVAssetReaderAudioMixOutput?
    let audioTracks=try await asset.loadTracks(withMediaType:.audio)
    if !audioTracks.isEmpty {
        let output=AVAssetReaderAudioMixOutput(audioTracks:audioTracks,audioSettings:[
            AVFormatIDKey:kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey:16,
            AVLinearPCMIsFloatKey:false,
            AVLinearPCMIsBigEndianKey:false,
            AVLinearPCMIsNonInterleaved:false
        ])
        output.audioMix=audioMix
        if reader.canAdd(output) { reader.add(output);audioOutput=output }
    }

    let writer=try AVAssetWriter(outputURL:url,fileType:.mov)
    let videoInput=AVAssetWriterInput(mediaType:.video,outputSettings:[
        AVVideoCodecKey:AVVideoCodecType.proRes4444,
        AVVideoWidthKey:Int(composition.renderSize.width),
        AVVideoHeightKey:Int(composition.renderSize.height)
    ])
    videoInput.expectsMediaDataInRealTime=false
    guard writer.canAdd(videoInput) else { throw NSError(domain:"Lumio",code:73,userInfo:[NSLocalizedDescriptionKey:"ProRes 4444 is not available on this Mac."]) }
    writer.add(videoInput)
    var audioInput:AVAssetWriterInput?
    if audioOutput != nil {
        let input=AVAssetWriterInput(mediaType:.audio,outputSettings:[
            AVFormatIDKey:kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey:2,
            AVSampleRateKey:48_000,
            AVEncoderBitRateKey:192_000
        ])
        input.expectsMediaDataInRealTime=false
        if writer.canAdd(input) { writer.add(input);audioInput=input }
    }

    guard writer.startWriting(),reader.startReading() else {
        throw writer.error ?? reader.error ?? NSError(domain:"Lumio",code:74,userInfo:[NSLocalizedDescriptionKey:"The transparent export could not be started."])
    }
    writer.startSession(atSourceTime:begin)
    let queue=DispatchQueue(label:"studio.lumio.transparent")

    func pump(_ input:AVAssetWriterInput,_ output:AVAssetReaderOutput,video:Bool) async {
        await withCheckedContinuation { (continuation:CheckedContinuation<Void,Never>) in
            input.requestMediaDataWhenReady(on:queue) {
                while input.isReadyForMoreMediaData {
                    if Task.isCancelled { input.markAsFinished();continuation.resume();return }
                    guard let sample=output.copyNextSampleBuffer() else { input.markAsFinished();continuation.resume();return }
                    if video {
                        let seconds=CMSampleBufferGetPresentationTimeStamp(sample).seconds
                        Task { @MainActor in progress(max(0,min(1,seconds/max(0.04,duration)))) }
                    }
                    if !input.append(sample) { input.markAsFinished();continuation.resume();return }
                }
            }
        }
    }
    // Both outputs are drained at once: a reader whose other output is never read stops handing over frames.
    await withTaskGroup(of:Void.self) { group in
        group.addTask { await pump(videoInput,videoOutput,video:true) }
        if let audioInput,let audioOutput { group.addTask { await pump(audioInput,audioOutput,video:false) } }
        await group.waitForAll()
    }
    if Task.isCancelled { writer.cancelWriting();reader.cancelReading();throw CancellationError() }
    await writer.finishWriting()
    if writer.status != .completed {
        throw writer.error ?? NSError(domain:"Lumio",code:75,userInfo:[NSLocalizedDescriptionKey:"The transparent export did not finish."])
    }
}

@MainActor extension Studio {
    /// Writes the frame under the playhead as a PNG, through the same pipeline the video export uses,
    /// so a thumbnail carries the same background, zoom, captions and blocks as the video it belongs to.
    func exportFrame(to requested:URL?=nil) async {
        guard let source, stillImage == nil, !busy, duration > 0 else { return }
        let destination: URL
        if let requested { destination = requested }
        else {
            let save=NSSavePanel(); save.allowedContentTypes=[.png]
            save.nameFieldStringValue="\(source.deletingPathExtension().lastPathComponent)-frame.png"
            guard save.runModal() == .OK, let selected=save.url else { return }
            destination=selected
        }
        guard destination.standardizedFileURL != source.standardizedFileURL else { message="Choose a different file name to preserve the raw recording."; return }
        busy=true; player.pause(); playing=false
        defer { busy=false }
        do {
            let (asset,composition,_)=try await makeEditingComposition(asset:AVURLAsset(url:source),size:look.canvas,fps:30)
            let generator=AVAssetImageGenerator(asset:asset)
            generator.videoComposition=composition
            generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
            let at=max(0,min(duration-0.01,position))
            let frame=try await generator.image(at:CMTime(seconds:at,preferredTimescale:600)).image
            guard let data=NSBitmapImageRep(cgImage:frame).representation(using:.png,properties:[:]) else { throw failure("The frame could not be encoded as PNG.") }
            try data.write(to:destination,options:.atomic)
            lastExportURL=destination
            flash("Frame saved as \(destination.lastPathComponent)")
            if preferences.revealExport { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch { message=error.localizedDescription }
    }
}
