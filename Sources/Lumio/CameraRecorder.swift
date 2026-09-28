import AVFoundation
import AppKit
import CoreMediaIO

struct CameraSidecar: Codable {
    var file: String
    /// Device clock minus recording clock, in seconds. Negative when the device started first.
    var offset: Double
}

func cameraRecordingURL(for recording:URL)->URL { recording.deletingPathExtension().appendingPathExtension("camera.mov") }
func microphoneRecordingURL(for recording:URL)->URL { recording.deletingPathExtension().appendingPathExtension("mic.m4a") }

/// Lets iPhone and iPad screens connected by cable appear as capture devices for this app.
@discardableResult func allowScreenCaptureDevices()->Bool {
    var address=CMIOObjectPropertyAddress(mSelector:CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),mScope:CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),mElement:CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    var allow:UInt32=1
    return CMIOObjectSetPropertyData(CMIOObjectID(kCMIOObjectSystemObject),&address,0,nil,UInt32(MemoryLayout<UInt32>.size),&allow)==noErr
}

/// Device frame and canvas for a recorded iPhone or iPad screen, chosen from its shape.
func deviceFrameAndCanvas(mediaAspect:Double)->(frame:String,aspect:String) {
    if mediaAspect<0.62 {return ("iPhone","9:16")}
    if mediaAspect<1 {return ("iPad","4:5")}
    if mediaAspect>1.7 {return ("iPhone","16:9")}
    return ("iPad","4:3")
}

/// Records one capture device (camera, microphone or a connected iPhone) to its own file and reports
/// the uptime when the first sample was written, so the file can be placed on the screen recording's clock.
final class CaptureRecorder: NSObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    private let output: AVCaptureFileOutput
    private let mediaType: AVMediaType
    private let deviceTypes: [AVCaptureDevice.DeviceType]
    private let preset: AVCaptureSession.Preset?
    private let queue = DispatchQueue(label:"studio.lumio.capture")
    private let lock = NSLock()
    private var startWaiters:[CheckedContinuation<TimeInterval?,Never>] = []
    private var finishWaiter:CheckedContinuation<Error?,Never>?
    private var configuredDeviceID:String?

    init(output:AVCaptureFileOutput,mediaType:AVMediaType,deviceTypes:[AVCaptureDevice.DeviceType],preset:AVCaptureSession.Preset?=nil) {
        self.output=output;self.mediaType=mediaType;self.deviceTypes=deviceTypes;self.preset=preset
        super.init()
    }
    static func camera()->CaptureRecorder {
        CaptureRecorder(output:AVCaptureMovieFileOutput(),mediaType:.video,deviceTypes:[.builtInWideAngleCamera,.external,.continuityCamera],preset:.hd1280x720)
    }
    static func microphone()->CaptureRecorder {
        let output = AVCaptureAudioFileOutput()
        output.audioSettings = [AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48_000,AVNumberOfChannelsKey:1]
        return CaptureRecorder(output:output,mediaType:.audio,deviceTypes:[.microphone,.external])
    }
    static func mobileDevice()->CaptureRecorder {
        CaptureRecorder(output:AVCaptureMovieFileOutput(),mediaType:.muxed,deviceTypes:[.external])
    }
    func devices()->[AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes:deviceTypes,mediaType:mediaType,position:.unspecified).devices
    }
    var isRecording: Bool { output.isRecording }
    func configure(deviceID:String) throws {
        let devices = devices()
        let fallback = mediaType == .muxed ? nil : AVCaptureDevice.default(for:mediaType)
        guard let device = devices.first(where:{ $0.uniqueID == deviceID }) ?? fallback ?? devices.first else {
            let text = mediaType == .audio ? "No microphone is connected." : mediaType == .muxed ? "Connect an iPhone or iPad with a cable, unlock it and choose Trust This Computer." : "No camera is connected."
            throw NSError(domain:"Lumio",code:40,userInfo:[NSLocalizedDescriptionKey:text])
        }
        if configuredDeviceID == device.uniqueID && !session.inputs.isEmpty { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        let input = try AVCaptureDeviceInput(device:device)
        guard session.canAddInput(input) else { throw NSError(domain:"Lumio",code:41,userInfo:[NSLocalizedDescriptionKey:"\(device.localizedName) is in use by another app."]) }
        session.addInput(input)
        if let preset, session.canSetSessionPreset(preset) { session.sessionPreset = preset }
        if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
        configuredDeviceID = device.uniqueID
    }
    func startSession() async {
        await withCheckedContinuation { (done:CheckedContinuation<Void,Never>) in
            queue.async { if !self.session.isRunning { self.session.startRunning() }; done.resume() }
        }
    }
    func stopSession() { queue.async { if self.session.isRunning && !self.output.isRecording { self.session.stopRunning() } } }
    /// Returns the uptime when the first sample was written, or nil if recording did not start.
    func startRecording(to url:URL) async -> TimeInterval? {
        try? FileManager.default.removeItem(at:url)
        return await withCheckedContinuation { waiter in
            lock.lock(); startWaiters.append(waiter); lock.unlock()
            if let audio = output as? AVCaptureAudioFileOutput { audio.startRecording(to:url,outputFileType:.m4a,recordingDelegate:self) }
            else { output.startRecording(to:url,recordingDelegate:self) }
            queue.asyncAfter(deadline:.now()+4) { self.resumeStart(nil) }
        }
    }
    func stopRecording() async -> Error? {
        guard output.isRecording else { return nil }
        return await withCheckedContinuation { waiter in
            lock.lock(); finishWaiter = waiter; lock.unlock()
            output.stopRecording()
            queue.asyncAfter(deadline:.now()+6) { self.resumeFinish(nil) }
        }
    }
    func pause() { if output.isRecording && !output.isRecordingPaused { output.pauseRecording() } }
    func resume() { if output.isRecordingPaused { output.resumeRecording() } }
    private func resumeStart(_ value:TimeInterval?) {
        lock.lock(); let waiters = startWaiters; startWaiters = []; lock.unlock()
        for waiter in waiters { waiter.resume(returning:value) }
    }
    private func resumeFinish(_ error:Error?) {
        lock.lock(); let waiter = finishWaiter; finishWaiter = nil; lock.unlock()
        waiter?.resume(returning:error)
    }
    func fileOutput(_ output:AVCaptureFileOutput,didStartRecordingTo fileURL:URL,from connections:[AVCaptureConnection]) {
        resumeStart(ProcessInfo.processInfo.systemUptime)
    }
    func fileOutput(_ output:AVCaptureFileOutput,didFinishRecordingTo outputFileURL:URL,from connections:[AVCaptureConnection],error:Error?) {
        resumeStart(nil)
        let finished = (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false
        resumeFinish(finished ? nil : error)
    }
}

final class CameraPreviewView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer
    init(session:AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session:session)
        super.init(frame:.zero)
        wantsLayer = true; layer = CALayer(); layer?.masksToBounds = true
        layer?.borderWidth = 3; layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor
        previewLayer.videoGravity = .resizeAspectFill; layer?.addSublayer(previewLayer)
    }
    required init?(coder:NSCoder) { fatalError() }
    override func layout() { super.layout(); previewLayer.frame = bounds; layer?.cornerRadius = min(bounds.width,bounds.height)/2 }
    override var mouseDownCanMoveWindow: Bool { true }
}

@MainActor extension Studio {
    /// Starts the camera session and shows the floating preview. Returns false when the camera is off or unavailable.
    @discardableResult func prepareCameraPreview() async -> Bool {
        guard camera else { cameraRecorder.stopSession(); onCameraPreviewChanged?(false); return false }
        guard await AVCaptureDevice.requestAccess(for:.video) else {
            message = "Camera permission is required. Open System Settings → Privacy & Security → Camera and allow Lumio."
            camera = false; onCameraPreviewChanged?(false); return false
        }
        do {
            try cameraRecorder.configure(deviceID:cameraID)
            await cameraRecorder.startSession()
            onCameraPreviewChanged?(true)
            return true
        } catch {
            message = error.localizedDescription; camera = false; onCameraPreviewChanged?(false); return false
        }
    }
    func startCameraIfNeeded(for recording:URL) async throws {
        cameraStartUptime = nil
        guard camera, await prepareCameraPreview() else { return }
        guard let started = await cameraRecorder.startRecording(to:cameraRecordingURL(for:recording)) else {
            message = "The camera could not start recording. The screen recording continues without the camera."
            return
        }
        cameraStartUptime = started
    }
    /// The microphone is recorded to its own file so voice and system audio keep separate volume and enhancement.
    func startMicrophoneIfNeeded(for recording:URL) async throws {
        microphoneStartUptime = nil
        guard mic else { return }
        try microphoneRecorder.configure(deviceID:microphoneID)
        await microphoneRecorder.startSession()
        guard let started = await microphoneRecorder.startRecording(to:microphoneRecordingURL(for:recording)) else {
            microphoneRecorder.stopSession()
            throw failure("The microphone could not start recording. Check the selected microphone and try again.")
        }
        microphoneStartUptime = started
    }
    func stopSidecarRecorders() async {
        await stopCamera()
        await stopMicrophone()
    }
    func stopCamera() async {
        guard cameraRecorder.isRecording else { return }
        let error = await cameraRecorder.stopRecording()
        guard let url = recordingURL, let started = cameraStartUptime else { return }
        cameraStartUptime = nil
        writeSidecar(recording:url,file:cameraRecordingURL(for:url),name:"camera",started:started,error:error)
    }
    func stopMicrophone() async {
        guard microphoneRecorder.isRecording else { return }
        let error = await microphoneRecorder.stopRecording()
        microphoneRecorder.stopSession()
        guard let url = recordingURL, let started = microphoneStartUptime else { return }
        microphoneStartUptime = nil
        writeSidecar(recording:url,file:microphoneRecordingURL(for:url),name:"mic",started:started,error:error)
    }
    private func writeSidecar(recording url:URL,file:URL,name:String,started:TimeInterval,error:Error?) {
        guard FileManager.default.fileExists(atPath:file.path) else {
            if let error { message = "The \(name == "mic" ? "microphone" : name) recording could not be saved: \(error.localizedDescription)" }
            return
        }
        let sidecar = CameraSidecar(file:file.lastPathComponent,offset:started-(fileStartUptime ?? captureStartUptime))
        try? JSONEncoder().encode(sidecar).write(to:url.appendingPathExtension("\(name).json"),options:.atomic)
    }
    private func readSidecar(_ url:URL,name:String)->(file:URL,offset:Double)? {
        guard let data = try? readBoundedData(url.appendingPathExtension("\(name).json"),maxBytes:10_000),
              let info = try? JSONDecoder().decode(CameraSidecar.self,from:data),
              info.offset.isFinite, abs(info.offset) < 60 else { return nil }
        let file = url.deletingLastPathComponent().appendingPathComponent((info.file as NSString).lastPathComponent)
        return FileManager.default.fileExists(atPath:file.path) ? (file,info.offset) : nil
    }
    func loadCameraSidecar(_ url:URL) {
        guard let camera = readSidecar(url,name:"camera") else { return }
        cameraPath = camera.file.path; cameraOffset = camera.offset
        var style = motion.cameraStyle ?? CameraStyle(); style.enabled = true; motion.cameraStyle = style
    }
    func loadMicrophoneSidecar(_ url:URL) {
        guard let microphone = readSidecar(url,name:"mic") else { return }
        microphonePath = microphone.file.path; microphoneOffset = microphone.offset
    }
    func prepareDeviceCapture() async {
        allowScreenCaptureDevices()
        mobileDevices = deviceRecorder.devices()
        if mobileDevices.isEmpty { try? await Task.sleep(for:.milliseconds(800)); mobileDevices = deviceRecorder.devices() }
        if !mobileDevices.contains(where:{ $0.uniqueID == mobileDeviceID }) { mobileDeviceID = mobileDevices.first?.uniqueID ?? "" }
        captureSheet = true
    }
    /// Records a cable-connected iPhone or iPad screen with its audio.
    func startDeviceRecording() async {
        guard !busy && !recording else { return }
        busy = true
        do {
            guard await AVCaptureDevice.requestAccess(for:.video) else { throw failure("Camera permission is required to record a connected iPhone or iPad. Allow Lumio in System Settings → Privacy & Security → Camera.") }
            try deviceRecorder.configure(deviceID:mobileDeviceID)
            await deviceRecorder.startSession()
            try FileManager.default.createDirectory(at:preferences.folder,withIntermediateDirectories:true)
            let url = preferences.folder.appendingPathComponent("Lumio-Device-\(UUID().uuidString.prefix(8)).mov")
            captureSheet = false; countdownCancelled = false
            for n in stride(from:preferences.countdown,through:1,by:-1) {
                countdownRemaining = n
                try await Task.sleep(for:.seconds(1))
                if countdownCancelled { break }
            }
            countdownRemaining = 0
            if countdownCancelled { deviceRecorder.stopSession(); busy = false; return }
            guard let started = await deviceRecorder.startRecording(to:url) else {
                deviceRecorder.stopSession()
                throw failure("The device did not start recording. Unlock it, keep the cable connected and try again.")
            }
            recordingURL = url; deviceRecording = true; discardRecording = false
            recordingPauses = []; pausedAt = nil; recordingRetakes = []; activeRetake = nil
            recording = true; recordingStarted = Date(); recordingUptime = started
        } catch { message = error.localizedDescription; countdownRemaining = 0 }
        busy = false
    }
    func stopDeviceRecording() async {
        busy = true
        let error = await deviceRecorder.stopRecording()
        deviceRecorder.stopSession()
        recording = false; deviceRecording = false; pausedAt = nil; busy = false
        guard let url = recordingURL else { return }
        if discardRecording {
            discardRecording = false; trashRecording(url); recordingURL = nil
            if restartAfterDiscard { restartAfterDiscard = false; await startDeviceRecording() }
            return
        }
        guard FileManager.default.fileExists(atPath:url.path) else { message = "The device recording could not be saved: \(error?.localizedDescription ?? "no data was written")"; return }
        await load(url)
        guard source == url else { return }
        let device = deviceFrameAndCanvas(mediaAspect:mediaAspect)
        var style = look.videoStyle ?? VideoStyle(); style.frame = device.frame
        look.videoStyle = style; look.aspect = device.aspect; look.autoReframe = false
    }
}
