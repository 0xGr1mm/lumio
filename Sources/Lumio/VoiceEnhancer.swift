import AVFoundation
import AudioToolbox
import Accelerate
import CryptoKit

struct VoiceEnhancementReport {
    var lagSamples: Int
    var gain: Double
    var isolated: Bool
}

/// Reads up to `seconds` of a file as 48 kHz mono samples.
func readMono48k(url:URL,seconds:Double) throws -> [Float] {
    let file = try AVAudioFile(forReading:url)
    let format = file.processingFormat
    let frames = AVAudioFrameCount(min(Double(file.length),seconds*format.sampleRate))
    guard frames > 0, let source = AVAudioPCMBuffer(pcmFormat:format,frameCapacity:frames),
          let target = AVAudioFormat(standardFormatWithSampleRate:48_000,channels:1),
          let converter = AVAudioConverter(from:format,to:target),
          let output = AVAudioPCMBuffer(pcmFormat:target,frameCapacity:AVAudioFrameCount(Double(frames)*48_000/format.sampleRate)+4_096) else { return [] }
    try file.read(into:source,frameCount:frames)
    converter.downmix = true
    var delivered = false
    var error: NSError?
    converter.convert(to:output,error:&error) { _, status in
        if delivered { status.pointee = .endOfStream; return nil }
        delivered = true; status.pointee = .haveData; return source
    }
    if let error { throw error }
    return Array(UnsafeBufferPointer(start:output.floatChannelData![0],count:Int(output.frameLength)))
}

/// How many samples `output` trails `input`, found by cross-correlating the loudest stretch; nil when they do not correlate.
func measureLag(input:[Float],output:[Float],sampleRate:Double,maxLagSeconds:Double=0.25)->Int? {
    let maxLag = Int(sampleRate*maxLagSeconds), block = Int(sampleRate)
    let usable = min(input.count,output.count-maxLag)
    guard usable > block*2 else { return nil }
    var loudest = 0, loudestEnergy: Float = 0
    input.withUnsafeBufferPointer { samples in
        for start in stride(from:0,to:usable-block,by:block) {
            var energy: Float = 0
            vDSP_svesq(samples.baseAddress!+start,1,&energy,vDSP_Length(block))
            if energy > loudestEnergy { loudestEnergy = energy; loudest = start }
        }
    }
    guard loudestEnergy > 1e-4 else { return nil }
    let start = max(0,loudest-block*5), length = min(usable-start,block*20)
    func score(_ lag:Int)->Float {
        var value: Float = 0
        input.withUnsafeBufferPointer { a in output.withUnsafeBufferPointer { b in vDSP_dotpr(a.baseAddress!+start,1,b.baseAddress!+start+lag,1,&value,vDSP_Length(length)) } }
        return value
    }
    var best = 0, bestScore = -Float.infinity
    for lag in stride(from:0,through:maxLag,by:8) { let value = score(lag); if value > bestScore { bestScore = value; best = lag } }
    for lag in max(0,best-8)...min(maxLag,best+8) { let value = score(lag); if value > bestScore { bestScore = value; best = lag } }
    var inputEnergy: Float = 0, outputEnergy: Float = 0
    input.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!+start,1,&inputEnergy,vDSP_Length(length)) }
    output.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress!+start+best,1,&outputEnergy,vDSP_Length(length)) }
    guard inputEnergy > 0, outputEnergy > 0, bestScore/sqrt(inputEnergy*outputEnergy) > 0.2 else { return nil }
    return best
}

/// Removes background noise with Apple's on-device voice isolation, levels speech to a steady loudness and limits peaks.
/// The output keeps the input's timing: the isolation unit delays audio by about 90 ms without reporting it,
/// so the delay is measured on this file and removed.
func enhanceVoice(input:URL,output:URL,isolation:Double,level:Bool) throws -> VoiceEnhancementReport {
    let file = try AVAudioFile(forReading:input)
    let rate = 48_000.0
    guard let mono = AVAudioFormat(standardFormatWithSampleRate:rate,channels:1) else { throw NSError(domain:"Lumio",code:60) }
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), converter = AVAudioMixerNode()
    var description = AudioComponentDescription(componentType:kAudioUnitType_Effect,componentSubType:kAudioUnitSubType_AUSoundIsolation,componentManufacturer:kAudioUnitManufacturer_Apple,componentFlags:0,componentFlagsMask:0)
    let isolate = isolation > 0.001 && AudioComponentFindNext(nil,&description) != nil
    let highPass = AVAudioUnitEQ(numberOfBands:1)
    highPass.bands[0].filterType = .highPass; highPass.bands[0].frequency = 80; highPass.bands[0].bypass = false
    [player,converter,highPass].forEach { engine.attach($0) }
    engine.connect(player,to:converter,format:file.processingFormat)
    if isolate {
        let unit = AVAudioUnitEffect(audioComponentDescription:description)
        engine.attach(unit)
        engine.connect(converter,to:unit,format:mono)
        engine.connect(unit,to:highPass,format:mono)
        AudioUnitSetParameter(unit.audioUnit,AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent),kAudioUnitScope_Global,0,AudioUnitParameterValue(min(1,isolation)*100),0)
        AudioUnitSetParameter(unit.audioUnit,AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate),kAudioUnitScope_Global,0,AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice),0)
    } else {
        engine.connect(converter,to:highPass,format:mono)
    }
    engine.connect(highPass,to:engine.mainMixerNode,format:mono)
    try engine.enableManualRenderingMode(.offline,format:mono,maximumFrameCount:4_096)
    try engine.start()
    defer { engine.stop() }
    player.scheduleFile(file,at:nil)
    player.play()
    let inputFrames = AVAudioFramePosition((Double(file.length)*rate/file.processingFormat.sampleRate).rounded())
    let tail = AVAudioFramePosition(rate*0.25)
    let rendered = FileManager.default.temporaryDirectory.appendingPathComponent("Lumio-voice-\(UUID().uuidString).caf")
    defer { try? FileManager.default.removeItem(at:rendered) }
    guard let chunk = AVAudioPCMBuffer(pcmFormat:engine.manualRenderingFormat,frameCapacity:4_096) else { throw NSError(domain:"Lumio",code:61) }
    let headLength = Int(rate*120)+Int(tail)
    var head:[Float] = []
    var speechPower = 0.0, speechFrames = 0, framePower = 0.0, frameFill = 0
    let frameSize = Int(rate*0.02), gate = pow(10,-45.0/10)
    do {
        let writer = try AVAudioFile(forWriting:rendered,settings:mono.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        while engine.manualRenderingSampleTime < inputFrames+tail {
            let frames = AVAudioFrameCount(min(4_096,inputFrames+tail-engine.manualRenderingSampleTime))
            guard try engine.renderOffline(frames,to:chunk) == .success else { throw NSError(domain:"Lumio",code:62,userInfo:[NSLocalizedDescriptionKey:"The audio could not be processed."]) }
            try writer.write(from:chunk)
            let samples = chunk.floatChannelData![0]
            for index in 0..<Int(chunk.frameLength) {
                let value = Double(samples[index]); framePower += value*value; frameFill += 1
                if frameFill == frameSize { let power = framePower/Double(frameSize); if power > gate { speechPower += power; speechFrames += 1 }; framePower = 0; frameFill = 0 }
            }
            if head.count < headLength { head.append(contentsOf:UnsafeBufferPointer(start:samples,count:min(Int(chunk.frameLength),headLength-head.count))) }
        }
    }
    let lag = measureLag(input:try readMono48k(url:input,seconds:120),output:head,sampleRate:rate) ?? (isolate ? Int(rate*0.0925) : 0)
    // Speech is brought to about -20 dBFS RMS; gain stays between -12 and +18 dB.
    let gain = level && speechFrames > 0 ? min(8,max(0.25,pow(10,-20.0/20)/sqrt(speechPower/Double(speechFrames)))) : 1
    let ceiling: Float = 0.891
    do {
        let reader = try AVAudioFile(forReading:rendered)
        reader.framePosition = AVAudioFramePosition(lag)
        let writer = try AVAudioFile(forWriting:output,settings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:rate,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:128_000],commonFormat:.pcmFormatFloat32,interleaved:false)
        guard let buffer = AVAudioPCMBuffer(pcmFormat:reader.processingFormat,frameCapacity:16_384) else { throw NSError(domain:"Lumio",code:63) }
        var remaining = inputFrames
        while remaining > 0 {
            try reader.read(into:buffer,frameCount:AVAudioFrameCount(min(16_384,remaining)))
            guard buffer.frameLength > 0 else { break }
            let samples = buffer.floatChannelData![0]
            for index in 0..<Int(buffer.frameLength) {
                var value = samples[index]*Float(gain)
                let magnitude = abs(value)
                if magnitude > ceiling { value = copysign(ceiling+(1-ceiling)*tanh((magnitude-ceiling)/(1-ceiling)),value) }
                samples[index] = value
            }
            try writer.write(from:buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
    }
    return VoiceEnhancementReport(lagSamples:lag,gain:gain,isolated:isolate)
}

@MainActor extension Studio {
    var voiceSourceDescription: String { microphonePath != nil ? "microphone track" : "recording audio" }
    /// Cached result for the current media and enhancement settings; nil when enhancement is off.
    func voiceCacheURL()->URL? {
        guard audioSettings.enhanceVoice ?? false, let source, stillImage == nil else { return nil }
        let input = microphonePath ?? source.path
        let attributes = try? FileManager.default.attributesOfItem(atPath:input)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let key = "\(input)|\(modified)|\(size)|\(Int(((audioSettings.voiceIsolation ?? 1)*100).rounded()))|\(audioSettings.levelVoice ?? true)|1"
        let digest = SHA256.hash(data:Data(key.utf8)).map { String(format:"%02x",$0) }.joined().prefix(24)
        return FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent("Lumio/Voice/\(digest).m4a")
    }
    func readyEnhancedVoiceURL()->URL? {
        guard let url = voiceCacheURL(), FileManager.default.fileExists(atPath:url.path) else { return nil }
        return url
    }
    /// Processes the voice for the current settings in the background (after a short pause for slider drags), then refreshes the preview.
    func refreshVoiceEnhancement() {
        voiceTask?.cancel()
        guard let target = voiceCacheURL(), let source else { voiceProcessing = false; voiceTask = nil; return }
        guard !FileManager.default.fileExists(atPath:target.path) else { voiceProcessing = false; voiceTask = nil; return }
        let microphone = microphonePath.map { URL(fileURLWithPath:$0) }
        let isolation = audioSettings.voiceIsolation ?? 1, level = audioSettings.levelVoice ?? true
        voiceProcessing = true
        voiceTask = Task { @MainActor in
            do {
                try await Task.sleep(for:.milliseconds(600))
                var extracted: URL?
                defer { if let extracted { try? FileManager.default.removeItem(at:extracted) } }
                let input: URL
                if let microphone { input = microphone }
                else {
                    guard !(try await AVURLAsset(url:source).loadTracks(withMediaType:.audio)).isEmpty,
                          let exporter = AVAssetExportSession(asset:AVURLAsset(url:source),presetName:AVAssetExportPresetAppleM4A) else { throw failure("This recording has no audio to enhance.") }
                    let audio = FileManager.default.temporaryDirectory.appendingPathComponent("Lumio-voice-source-\(UUID().uuidString).m4a")
                    try await exporter.export(to:audio,as:.m4a)
                    extracted = audio; input = audio
                }
                try Task.checkCancellation()
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                let partial = target.deletingPathExtension().appendingPathExtension("partial.m4a")
                try? FileManager.default.removeItem(at:partial)
                _ = try await Task.detached(priority:.userInitiated) { try enhanceVoice(input:input,output:partial,isolation:isolation,level:level) }.value
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at:target)
                try FileManager.default.moveItem(at:partial,to:target)
                voiceProcessing = false
                refreshComposition()
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { voiceProcessing = false; message = "Voice enhancement failed: \(error.localizedDescription)" }
            }
        }
    }
}
