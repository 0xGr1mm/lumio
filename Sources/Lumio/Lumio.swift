import SwiftUI
import AVKit
import ScreenCaptureKit
import UniformTypeIdentifiers

let accent = Color(red: 0.75, green: 0.93, blue: 0.39)
let panel = Color(white: 0.105)
func stamp(_ value: Double) -> String { let n = Int(max(0, value.isFinite ? value : 0)); return String(format: "%02d:%02d", n / 60, n % 60) }

/// H.264 hardware encoders stop at 4096 pixels, so larger captures use HEVC or are scaled down.
func captureEncoding(width:Int,height:Int,preferHEVC:Bool,available:[AVVideoCodecType])->(codec:AVVideoCodecType,width:Int,height:Int) {
    let longest=max(width,height)
    if (preferHEVC || longest>4096) && available.contains(.hevc) { return (.hevc,width,height) }
    guard longest>4096 else { return (.h264,width,height) }
    let scale=4096.0/Double(longest)
    return (.h264,max(2,Int(Double(width)*scale)/2*2),max(2,Int(Double(height)*scale)/2*2))
}

@MainActor final class Studio: NSObject, ObservableObject, SCRecordingOutputDelegate, SCStreamDelegate {
    @Published var player = AVPlayer()
    @Published var source: URL?
    @Published var duration = 0.0
    @Published var mediaAspect = 16.0 / 9.0
    @Published var position = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var playing = false
    @Published var recording = false {didSet {onRecordingStateChanged?(recording)}}
    @Published var busy = false
    @Published var message: String?
    @Published var motion = MotionSettings()
    @Published var pointerSamples:[PointerSample] = [] { didSet { sampleGeneration &+= 1 } }
    @Published var cursorEmbedded = true
    @Published var cameraPath:String?
    @Published var captions:[CaptionCue] = []
    @Published var selectedCaption:UUID?
    @Published var captionStyle = CaptionStyle()
    @Published var captionGenerating = false
    @Published var audioTracks:[AudioTrackEdit] = []
    @Published var selectedAudioTrack:UUID?
    @Published var audioSettings = AudioMixSettings()
    @Published var voiceoverRecording = false
    @Published var keyboardSamples:[KeySample] = [] { didSet { sampleGeneration &+= 1 } }
    /// Bumped whenever recorded samples change, so their timeline mapping is recomputed only when needed.
    var sampleGeneration = 0
    var timelineSampleCache: TimelineSampleCache?
    @Published var keyboardStyle = KeyboardOverlayStyle()
    @Published var previewQuality = 1
    @Published var previewSpeed = 1.0
    @Published var retakes:[RetakeMarker]=[]
    @Published var cleanupCandidates:[CleanupCandidate]=[]
    @Published var privacyFinds:[SensitiveFind]=[]
    @Published var privacyScanning=false
    @Published var privacyScanned=false
    @Published var privacyProgress:Double?
    @Published var privacyAddresses=true
    @Published var privacyEmails=true
    @Published var privacyBalances=false
    @Published var quickSteps:[QuickEditStep]=[]
    @Published var quickRunning=false
    @Published var quickEditFinished:Date?
    /// A short confirmation shown over the picture; see flash(_:).
    /// In and out points: when both are set, only that stretch is exported.
    @Published var exportStart:Double?
    @Published var exportEnd:Double?
    @Published var toast:String?
    var toastTask:Task<Void,Never>?
    @Published var cleanupScanning=false
    @Published var cleanupThreshold = -45.0
    @Published var cleanupMinimumDuration = 0.7
    @Published var cleanupPadding = 0.12
    @Published var activeRetake:RetakeMarker?
    @Published var retakeLookback=10.0
    var recordingRetakes:[RetakeMarker]=[]
    var recordingUptime:TimeInterval?
    @Published var pausedAt:Double?
    var recordingPauses:[VideoCut]=[]
    /// Uptime when pointer and keyboard capture began; the recording file starts slightly later.
    var captureStartUptime:TimeInterval=0
    var fileStartUptime:TimeInterval?
    var captureDataPending=false
    var countdownCancelled=false
    var discardRecording=false
    var restartAfterDiscard=false
    /// Camera clock minus recording clock for a camera recorded with the screen; nil for an imported camera video.
    @Published var cameraOffset:Double?
    let cameraRecorder=CaptureRecorder.camera()
    let microphoneRecorder=CaptureRecorder.microphone()
    let deviceRecorder=CaptureRecorder.mobileDevice()
    var cameraStartUptime:TimeInterval?
    var microphoneStartUptime:TimeInterval?
    /// A microphone recorded to its own file next to the screen recording, and its clock offset.
    @Published var microphonePath:String?
    @Published var microphoneOffset:Double?
    @Published var mobileDevices:[AVCaptureDevice]=[]
    @Published var mobileDeviceID=""
    var deviceRecording=false
    @Published var lastExportURL:URL?
    @Published var voiceProcessing=false
    var voiceTask:Task<Void,Never>?
    var onCameraPreviewChanged:((Bool)->Void)?
    @Published var camera = UserDefaults.standard.bool(forKey:"cameraEnabled") {
        didSet { UserDefaults.standard.set(camera,forKey:"cameraEnabled") }
    }
    @Published var cameraID = UserDefaults.standard.string(forKey:"cameraDeviceID") ?? "" {
        didSet { UserDefaults.standard.set(cameraID,forKey:"cameraDeviceID") }
    }
    @Published var savedVersions:[SavedEditVersion]=[]
    @Published var undoStack:[EditSnapshot]=[]
    @Published var redoStack:[EditSnapshot]=[]
    var previousSnapshot:EditSnapshot?
    var lastEdit=Date.distantPast
    var restoringUntil=Date.distantPast
    var previewTask:Task<Void,Never>?
    let pointerCapture=PointerCapture()
    let keyboardCapture=KeyboardCapture()
    var voiceRecorder:AVAudioRecorder?
    var voiceoverTimer:Timer?
    var voiceoverTimelineStart=0.0
    var musicPreviewPlayer:AVAudioPlayer?
    var captureGlobalRect=CGRect.zero
    @Published var look = Look()
    @Published var zooms: [ZoomClip] = []
    @Published var selectedZoom: UUID?
    @Published var markers: [TimelineMarker] = []
    @Published var selectedMarker: UUID?
    /// Loudness envelope per recording: "" is the opened one, other keys are added files.
    @Published var waveforms: [String:[Float]] = [:]
    var waveformTask: Task<Void,Never>?
    /// Recordings added to this project besides the one it was opened with: file path to its length.
    @Published var addedSources: [String:Double] = [:]
    @Published var annotations: [Annotation] = []
    @Published var selectedAnnotation: UUID?
    /// True while the Annotate inspector is open, so drags on the preview place the selected annotation.
    @Published var annotationEditing = false
    @Published var sourceDuration = 0.0
    @Published var videoClips:[VideoClip]=[]
    @Published var selectedClip:UUID?
    @Published var timelineTool = "select"
    /// The track Delete, Copy, Cut and Duplicate act on: the kind of item clicked last.
    @Published var timelineFocus:TimelineItemKind = .clip
    @Published var timelineClipboard:TimelineClipboardItem?
    @Published var stillImage: NSImage?
    @Published var windows: [SCWindow] = []
    @Published var windowID: UInt32 = 0
    @Published var mode = "Screen"
    @Published var area: CGRect?
    @Published var countdownRemaining = 0
    @Published var recordingStarted: Date?
    @Published var preferences = RecorderPreferences()
    @Published var exportSettings = ExportSettings.stored()
    @Published var exportProgress:Double?
    var exportTask:Task<Void,Never>?
    var onRecordingStateChanged:((Bool)->Void)?
    var onOpenEditor: (() -> Void)?
    var onShowRecorder: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onSelectArea: (() -> Void)?
    @Published var mic = UserDefaults.standard.bool(forKey: "microphoneEnabled") {
        didSet { UserDefaults.standard.set(mic, forKey: "microphoneEnabled") }
    }
    @Published var systemAudio = UserDefaults.standard.object(forKey: "systemAudioEnabled") as? Bool ?? true {
        didSet { UserDefaults.standard.set(systemAudio, forKey: "systemAudioEnabled") }
    }
    @Published var microphoneID = UserDefaults.standard.string(forKey:"microphoneDeviceID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneID,forKey:"microphoneDeviceID") }
    }
    @Published var displays: [SCDisplay] = []
    @Published var displayID: UInt32 = 0
    @Published var captureSheet = false
    var stream: SCStream?
    var output: SCRecordingOutput?
    var recordingURL: URL?
    var observer: Any?
    override init() {
        super.init()
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0/60, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if self.position >= self.trimEnd {
                    self.player.pause();self.playing=false
                    if self.voiceoverRecording {self.stopVoiceover()}
                    return
                }
            }
        }
    }
    func importVideo() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.movie, .image]; picker.allowsMultipleSelection = false
        if picker.runModal() == .OK, let url = picker.url {
            if NSImage(contentsOf:url) != nil { loadImage(url) } else { Task { await load(url) } }
        }
    }
    func load(_ url: URL) async {
        if voiceoverRecording {stopVoiceover()}
        do {
            let asset = AVURLAsset(url: url)
            let length = try await asset.load(.duration).seconds
            guard length.isFinite, length > 0, !(try await asset.loadTracks(withMediaType: .video)).isEmpty else { throw NSError(domain: "Lumio", code: 1, userInfo: [NSLocalizedDescriptionKey: "This file does not contain a readable video."]) }
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let naturalSize = try await track.load(.naturalSize)
                let preferredTransform = try await track.load(.preferredTransform)
                let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform)
                mediaAspect = abs(bounds.width / bounds.height)
            }
            sourceDuration=length
            zooms = []; selectedZoom = nil; cameraPath=nil;cameraOffset=nil;captions=[];selectedCaption=nil;captionStyle=CaptionStyle();audioTracks=[];selectedAudioTrack=nil;audioSettings=AudioMixSettings();cleanupCandidates=[];privacyFinds=[];privacyScanned=false;quickSteps=[];quickEditFinished=nil;exportStart=nil;exportEnd=nil;loadPointerData(url);loadKeyboardData(url);await loadRetakes(url);savedVersions=[];undoStack=[];redoStack=[];previousSnapshot=nil
            microphonePath=nil;microphoneOffset=nil
            loadCameraSidecar(url);loadMicrophoneSidecar(url)
            player.pause(); playing = false; stillImage = nil; source = url; duration = length; trimStart = 0; trimEnd = length; position = 0
            let firstClip=VideoClip(sourceStart:0,sourceEnd:length);videoClips=[firstClip];selectedClip=firstClip.id;timelineTool="select"
            let pauses=loadRecordingPauses(url)
            if !pauses.isEmpty { migrateLegacyVideoEdits(start:0,end:length,cuts:pauses) }
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset)); refreshComposition(); loadWaveforms(); onOpenEditor?()
        } catch { message = error.localizedDescription }
    }
    func togglePlay() {
        guard source != nil, stillImage == nil else { return }
        if playing { player.pause() } else {
            if position >= trimEnd || position < trimStart { seek(trimStart) }
            player.playImmediately(atRate:Float(previewSpeed))
        }
        playing.toggle()
    }
    func seek(_ value: Double) { player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func stepFrame(_ direction:Int) {
        guard duration > 0 else { return }
        player.pause(); playing = false
        position = max(0,min(duration,position+Double(direction)/Double(exportSettings.resolvedFPS))); seek(position)
    }
    func prepareCapture() async {
        guard !busy && !recording else { return }
        busy = true
        defer { busy = false }
        if mode == "Device" { await prepareDeviceCapture(); return }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly:true)
            displays = content.displays
            windows = content.windows.filter { $0.windowLayer == 0 && $0.frame.width > 80 && $0.frame.height > 60 && $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
            if !displays.contains(where: { $0.displayID == displayID }) { displayID = displays.first?.displayID ?? 0;area=nil }
            if !windows.contains(where: { $0.windowID == windowID }) { windowID = windows.first?.windowID ?? 0 }
            captureSheet = true
        } catch { message = "Screen recording permission is required. Open System Settings → Privacy & Security → Screen & System Audio Recording, allow Lumio, then reopen it.\n\n\(error.localizedDescription)" }
    }
    func captureSetup() async throws -> (SCContentFilter, SCStreamConfiguration) {
        let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
        let config = SCStreamConfiguration()
        let filter: SCContentFilter
        var selectedRect:CGRect?
        if mode == "Window" {
            guard let selected = content.windows.first(where: { $0.windowID == windowID }) else { throw failure("The selected window was closed. Choose it again.") }
            filter = SCContentFilter(desktopIndependentWindow:selected)
            captureGlobalRect=selected.frame
        } else {
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw failure("Choose a display.") }
            captureGlobalRect=display.frame
            if preferences.hideDesktopIcons ?? false {
                // Excluding windows (instead of the whole app) lets Finder's desktop icons disappear while its windows stay visible.
                let hidden = content.windows.filter { window in
                    let app = window.owningApplication?.bundleIdentifier
                    return (app == "com.apple.finder" && window.windowLayer < 0) || (preferences.hideLumio && app == Bundle.main.bundleIdentifier)
                }
                filter = SCContentFilter(display:display,excludingWindows:hidden)
            } else {
                let excluded = content.applications.filter { preferences.hideLumio && $0.bundleIdentifier == Bundle.main.bundleIdentifier }
                filter = SCContentFilter(display:display,excludingApplications:excluded,exceptingWindows:[])
            }
            filter.includeMenuBar = preferences.includeMenuBar
            if mode == "Area" {
                guard let area, area.width >= 16, area.height >= 16 else { throw failure("Draw the area to record first.") }
                let bounded=area.intersection(CGRect(origin:.zero,size:display.frame.size))
                guard bounded.width>=16,bounded.height>=16 else{throw failure("The selected area is outside the current display. Draw it again.")}
                config.sourceRect=bounded;selectedRect=bounded
                captureGlobalRect=CGRect(x:display.frame.minX+bounded.minX,y:display.frame.minY+bounded.minY,width:bounded.width,height:bounded.height)
            }
        }
        let rect=selectedRect ?? filter.contentRect
        let pixelScale = preferences.retina ? CGFloat(filter.pointPixelScale) : 1
        config.width = max(2,Int(rect.width*pixelScale)/2*2); config.height = max(2,Int(rect.height*pixelScale)/2*2)
        config.minimumFrameInterval = CMTime(value:1,timescale:Int32(preferences.fps))
        config.showsCursor = false
        // The microphone is recorded to its own file (see startMicrophoneIfNeeded) so voice and system audio stay separately adjustable.
        config.capturesAudio = systemAudio; config.captureMicrophone = false; config.excludesCurrentProcessAudio = true
        if mic && !microphoneID.isEmpty && !microphoneRecorder.devices().contains(where: { $0.uniqueID == microphoneID }) {
            throw failure("The selected microphone is unavailable. Choose another microphone from Audio Devices.")
        }
        return (filter,config)
    }
    func failure(_ text: String) -> NSError { NSError(domain:"Lumio",code:1,userInfo:[NSLocalizedDescriptionKey:text]) }
    func startRecording() async {
        guard !busy && !recording else { return }
        if mode == "Device" { await startDeviceRecording(); return }
        busy = true
        do {
            if mic {
                let granted = await AVCaptureDevice.requestAccess(for:.audio)
                if !granted { throw failure("Microphone permission was not granted.") }
            }
            let (filter,config) = try await captureSetup()
            let folder = preferences.folder
            try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url = folder.appendingPathComponent("Lumio-\(UUID().uuidString.prefix(8)).mp4")
            recordingURL = url
            let settings = SCRecordingOutputConfiguration(); settings.outputURL = url
            let encoding = captureEncoding(width:config.width,height:config.height,preferHEVC:preferences.hevc ?? false,available:settings.availableVideoCodecTypes)
            settings.videoCodecType = encoding.codec; config.width = encoding.width; config.height = encoding.height
            let out = SCRecordingOutput(configuration:settings,delegate:self)
            let capture = SCStream(filter:filter,configuration:config,delegate:self)
            try capture.addRecordingOutput(out); stream = capture; output = out
            captureSheet = false
            countdownCancelled = false
            for n in stride(from:preferences.countdown,through:1,by:-1) {
                countdownRemaining = n
                try await Task.sleep(for:.seconds(1))
                if countdownCancelled { break }
            }
            countdownRemaining = 0
            if countdownCancelled { stream = nil; output = nil; recordingURL = nil; busy = false; return }
            try await startCameraIfNeeded(for:url)
            try await startMicrophoneIfNeeded(for:url)
            recordingRetakes=[];activeRetake=nil;recordingPauses=[];pausedAt=nil;discardRecording=false;fileStartUptime=nil
            captureStartUptime=ProcessInfo.processInfo.systemUptime
            pointerCapture.start(rect:captureGlobalRect);keyboardCapture.start();captureDataPending=true
            try await capture.startCapture()
            recording = true; recordingStarted = Date(); recordingUptime=fileStartUptime ?? ProcessInfo.processInfo.systemUptime
        } catch {
            if captureDataPending { _ = pointerCapture.stop(); _ = keyboardCapture.stop(); captureDataPending = false }
            await stopSidecarRecorders()
            message = error.localizedDescription; stream = nil; output = nil; countdownRemaining = 0
        }
        busy = false
    }
    func takeScreenshot() async {
        guard !busy && !recording else { return }
        busy = true
        defer { busy = false }
        do {
            let (filter,config) = try await captureSetup()
            config.showsCursor = preferences.screenshotCursor
            captureSheet = false
            countdownCancelled = false
            for n in stride(from:preferences.countdown,through:1,by:-1) { countdownRemaining = n; try await Task.sleep(for:.seconds(1)); if countdownCancelled { break } }
            countdownRemaining = 0
            if countdownCancelled { return }
            let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)
            guard let data=NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:]) else{throw failure("The screenshot could not be encoded as PNG.")}
            try FileManager.default.createDirectory(at:preferences.folder,withIntermediateDirectories:true)
            let url = preferences.folder.appendingPathComponent("Lumio-\(UUID().uuidString.prefix(8)).png")
            try data.write(to:url)
            if preferences.copyScreenshot { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([NSImage(cgImage:image,size:.zero)]) }
            loadImage(url)
        } catch { message = error.localizedDescription; countdownRemaining = 0 }
    }
    func loadImage(_ url:URL) {
        guard let image = NSImage(contentsOf:url), image.size.width > 0, image.size.height > 0 else { message = "The image could not be read."; return }
        if voiceoverRecording {stopVoiceover()}
        player.pause(); player.replaceCurrentItem(with:nil); playing = false
        zooms=[];selectedZoom=nil;annotations=[];selectedAnnotation=nil;addedSources=[:];markers=[];selectedMarker=nil;waveforms=[:];waveformTask?.cancel();cameraPath=nil;cameraOffset=nil;microphonePath=nil;microphoneOffset=nil;pointerSamples=[];cursorEmbedded=true;keyboardSamples=[]
        captions=[];selectedCaption=nil;captionStyle=CaptionStyle();audioTracks=[];selectedAudioTrack=nil;audioSettings=AudioMixSettings()
        retakes=[];cleanupCandidates=[];privacyFinds=[];privacyScanned=false;quickSteps=[];quickEditFinished=nil;exportStart=nil;exportEnd=nil;savedVersions=[];undoStack=[];redoStack=[];previousSnapshot=nil;timelineTool="select"
        source = url; stillImage = image; mediaAspect = image.size.width/image.size.height
        sourceDuration=0;videoClips=[];selectedClip=nil;duration = 0; position = 0; trimStart = 0; trimEnd = 0; onOpenEditor?()
    }
    func chooseBackground() {
        let picker = NSOpenPanel(); picker.allowedContentTypes = [.image]
        if picker.runModal() == .OK, let url = picker.url, NSImage(contentsOf:url) != nil { look.imagePath = url.path; look.mode = "Image" }
    }
    func useDesktopBackground() {
        guard let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for:screen), NSImage(contentsOf:url) != nil else { message = "The desktop wallpaper could not be read. Use Choose Image instead."; return }
        look.imagePath = url.path; look.mode = "Image"
    }
    func chooseWatermark() {
        let picker=NSOpenPanel();picker.allowedContentTypes=[.png,.jpeg,.tiff,.image];picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let url=picker.url,NSImage(contentsOf:url) != nil else { return }
        look.watermarkPath=url.path
        if look.watermarkPosition == nil { look.watermarkPosition="Bottom Right" }
        refreshComposition()
    }
    /// Uses a frame of the recording itself, blurred, as the background. FocuSee-style: the colours always match the video.
    func useRecordingBackground() async {
        guard let source,stillImage == nil else {
            if let still=stillImage,let data=still.tiffRepresentation,let rep=NSBitmapImageRep(data:data),let png=rep.representation(using:.png,properties:[:]) {
                let url=cachedBackgroundURL(for:"still")
                try? png.write(to:url);look.imagePath=url.path;look.mode="Image";look.blur=max(look.blur,34);refreshComposition()
            } else { message="Open a recording first." }
            return
        }
        let time=placement(containing:position).map { $0.clip.sourceTime(forTimeline:position) } ?? max(0,sourceDuration/3)
        let generator=AVAssetImageGenerator(asset:AVURLAsset(url:source))
        generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:960,height:960)
        guard let frame=try? await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image else {
            message="That moment of the recording could not be read for the background.";return
        }
        let url=cachedBackgroundURL(for:"\(source.lastPathComponent)-\(Int(time*100))")
        let image=NSBitmapImageRep(cgImage:frame)
        guard let png=image.representation(using:.png,properties:[:]) else { message="The background could not be prepared.";return }
        do { try png.write(to:url) } catch { message=error.localizedDescription;return }
        look.imagePath=url.path;look.mode="Image"
        if look.blur<20 { look.blur=34 }
        refreshComposition()
    }
    /// Picks two colours out of the recording and builds the background from them, so it always matches the video.
    func matchBackgroundToRecording() async {
        var frame:CGImage?
        if let still=stillImage { frame=still.cgImage(forProposedRect:nil,context:nil,hints:nil) }
        else if let source {
            let time=placement(containing:position).map { $0.clip.sourceTime(forTimeline:position) } ?? max(0,sourceDuration/3)
            let generator=AVAssetImageGenerator(asset:AVURLAsset(url:source))
            generator.appliesPreferredTrackTransform=true;generator.maximumSize=CGSize(width:320,height:320)
            frame=try? await generator.image(at:CMTime(seconds:time,preferredTimescale:600)).image
        }
        guard let frame,let pair=dominantColors(of:frame) else { message="The colours of this recording could not be read.";return }
        look.first=pair.dark;look.second=pair.light
        if ["Color","düz renk","Image","görsel"].contains(look.mode) { look.mode="Mesh" }
        look.imagePath=nil
        refreshComposition()
    }
    private func cachedBackgroundURL(for name:String)->URL {
        let folder=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Lumio/Background",isDirectory:true)
        try? FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let safe=name.replacingOccurrences(of:"/",with:"-").prefix(80)
        return folder.appendingPathComponent("\(safe).png")
    }
    /// Time on the recording file's clock, excluding nothing; pauses are cut when the recording opens.
    var recordedElapsed:Double {
        let now=retakeElapsed
        let paused=recordingPauses.reduce(0){$0+$1.end-$1.start}+(pausedAt.map{max(0,now-$0)} ?? 0)
        return max(0,now-paused)
    }
    func togglePause() {
        guard recording, !busy else { return }
        if deviceRecording {
            // The device file output pauses natively, so nothing needs to be cut later.
            if let start = pausedAt { deviceRecorder.resume(); recordingPauses.append(VideoCut(start:start,end:retakeElapsed)); pausedAt = nil }
            else { deviceRecorder.pause(); pausedAt = retakeElapsed }
            return
        }
        if let start = pausedAt {
            let end = retakeElapsed
            if end-start >= 0.05 { recordingPauses.append(VideoCut(start:start,end:end)) }
            pausedAt = nil
        } else {
            if activeRetake != nil { finishActiveRetake(); saveRecordingRetakes() }
            pausedAt = retakeElapsed
        }
        saveRecordingPauses()
    }
    /// Writes pointer, keyboard, retake and pause data once, on the recording file's clock.
    func finishCaptureData() {
        guard captureDataPending else { return }
        captureDataPending = false
        finishActiveRetake(); saveRecordingRetakes()
        if let start = pausedAt { let end = retakeElapsed; if end-start >= 0.05 { recordingPauses.append(VideoCut(start:start,end:end)) }; pausedAt = nil }
        saveRecordingPauses()
        let offset = max(0,(fileStartUptime ?? captureStartUptime)-captureStartUptime)
        let samples = shiftedPointerSamples(pointerCapture.stop(),by:offset)
        let keys = shiftedKeySamples(keyboardCapture.stop(),by:offset)
        guard let url = recordingURL else { return }
        do { try JSONEncoder().encode(PointerRecording(samples:samples)).write(to:url.appendingPathExtension("pointer.json"),options:.atomic) }
        catch { message="Pointer data could not be saved: \(error.localizedDescription)" }
        try? JSONEncoder().encode(KeyboardRecording(samples:keys)).write(to:url.appendingPathExtension("keys.json"),options:.atomic)
    }
    func stopRecording() async {
        guard recording,!busy else{return}
        if deviceRecording { finishActiveRetake(); await stopDeviceRecording(); return }
        busy = true
        finishCaptureData()
        await stopSidecarRecorders()
        do { try await stream?.stopCapture() } catch { message = error.localizedDescription; busy = false }
        recording = false
    }
    /// Stops the recording and moves the file and its sidecars to the Trash.
    func discardActiveRecording(restart:Bool) async {
        guard recording, !busy else { return }
        discardRecording = true; restartAfterDiscard = restart
        await stopRecording()
    }
    func trashRecording(_ url:URL) {
        let related = ["","pointer.json","keys.json","retakes.json","pauses.json","camera.json","mic.json"].map { $0.isEmpty ? url : url.appendingPathExtension($0) }
        for file in related + [cameraRecordingURL(for:url),microphoneRecordingURL(for:url)] where FileManager.default.fileExists(atPath:file.path) {
            try? FileManager.default.trashItem(at:file,resultingItemURL:nil)
        }
    }
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        let now = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in self.fileStartUptime = now; self.recordingUptime = now }
    }
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            self.finishCaptureData()
            await self.stopSidecarRecorders()
            self.busy = false; self.recording = false; self.stream = nil; self.output = nil
            guard let url = self.recordingURL else { return }
            if self.discardRecording {
                self.discardRecording = false
                self.trashRecording(url); self.recordingURL = nil
                if self.restartAfterDiscard { self.restartAfterDiscard = false; await self.startRecording() }
                return
            }
            self.motion.showCursor = self.preferences.showCursor
            await self.load(url)
        }
    }
    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor in self.finishCaptureData(); await self.stopSidecarRecorders(); self.message = error.localizedDescription; self.busy = false; self.recording = false; self.stream = nil; self.output = nil }
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let userStopped = (error as NSError).domain == SCStreamErrorDomain && (error as NSError).code == SCStreamError.Code.userStopped.rawValue
        Task { @MainActor in
            // The system can end capture (menu bar Stop, display change); keep pointer and keyboard data for the finished file.
            self.finishCaptureData()
            await self.stopSidecarRecorders()
            if !userStopped { self.message = error.localizedDescription }
            self.recording = false
            if self.output == nil { self.busy = false }
        }
    }
    func startExport() {
        guard exportTask == nil, !busy, source != nil else { return }
        exportTask = Task { await export(); exportTask = nil }
    }
    func cancelExport() { exportTask?.cancel() }
    func export(to requested: URL? = nil) async {
        guard let source, !busy else { return }
        if stillImage != nil { exportImage(to: requested); return }
        let settings = exportSettings
        let destination: URL
        if let requested { destination = requested }
        else {
            let save = NSSavePanel(); save.allowedContentTypes = [settings.contentType]; save.nameFieldStringValue = "Lumio-export.\(settings.fileExtension)"
            guard save.runModal() == .OK, let selected = save.url else { return }
            destination = selected
        }
        guard destination.standardizedFileURL != source.standardizedFileURL else { message = "Choose a different file name to preserve the raw recording."; return }
        // Voice enhancement must finish first, or the export would silently use the unprocessed audio.
        if let pending = voiceTask { await pending.value }
        busy = true; player.pause(); playing = false; exportProgress = 0
        defer { busy = false; exportProgress = nil }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + settings.fileExtension)
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            let asset = AVURLAsset(url: source)
            let (editAsset,composition,audioMix)=try await makeEditingComposition(asset:asset,size:look.canvas,fps:settings.resolvedFPS)
            if settings.resolvedFormat == "GIF" {
                try await writeGIF(asset:editAsset,composition:composition,size:look.canvas,to:temporary)
            } else if settings.keepsTransparency {
                try await writeTransparentMovie(asset:editAsset,composition:composition,audioMix:audioMix,duration:duration,to:temporary) { [weak self] value in
                    self?.exportProgress=value
                }
            } else {
                let preset = settings.resolvedCodec == "HEVC" ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
                guard let session=AVAssetExportSession(asset:editAsset,presetName:preset) else { throw failure("Export could not be started") }
                session.videoComposition = composition
                session.audioMix = audioMix
                session.audioTimePitchAlgorithm = .spectral
                let span = exportRange ?? (0,duration)
                session.timeRange = CMTimeRange(start:CMTime(seconds:span.start,preferredTimescale:600),duration:CMTime(seconds:span.end-span.start,preferredTimescale:600))
                let progress = Task { @MainActor in
                    for await state in session.states(updateInterval:0.2) { if case .exporting(let value) = state { self.exportProgress = value.fractionCompleted } }
                }
                defer { progress.cancel() }
                try await runExport(session, to: temporary, as: settings.resolvedFormat == "MOV" ? .mov : .mp4)
            }
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: temporary) }
            else { try FileManager.default.moveItem(at: temporary, to: destination) }
            lastExportURL = destination
            if settings.copyToClipboard ?? false { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([destination as NSURL]) }
            if preferences.revealExport { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch is CancellationError {
        } catch {
            if !Task.isCancelled { message="Export could not be completed: \(error.localizedDescription)" }
        }
    }
}
