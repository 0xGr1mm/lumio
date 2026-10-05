import AVFoundation
import AppKit
import CoreGraphics

/// Writes the three-second recording the verification suite runs against.
///
/// The suite needs one input it cannot make up as it goes: a short video with sound, a picture that
/// changes over time and an even, mid-bright frame, so that a test which dims, blurs or covers part of
/// it can tell the difference. Keeping a generator beside the tests means the fixture can always be
/// remade, which matters because the file itself is too big to keep in the repository.
func writeSampleClip(to url: URL, seconds: Double = 3, size: CGSize = CGSize(width: 1280, height: 720)) async throws {
    try? FileManager.default.removeItem(at: url)
    let fps = 30.0
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 8_000_000]
    ])
    video.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 128_000
    ])
    audio.expectsMediaDataInRealTime = false
    writer.add(video); writer.add(audio)
    writer.startWriting(); writer.startSession(atSourceTime: .zero)

    // The sound goes in first and is closed: a writer with two open inputs will not let either run ahead.
    let rate = 48_000.0, samples = Int(seconds * rate)
    var pcm = [Int16](repeating: 0, count: samples)
    for index in 0..<samples {
        let time = Double(index) / rate
        let note = 196.0 * pow(2, Double(Int(time * 2) % 4) / 12)
        let envelope = 0.35 * (0.6 + 0.4 * sin(time * 3.1))
        pcm[index] = Int16(max(-1, min(1, sin(2 * .pi * note * time) * envelope)) * 26_000)
    }
    var format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                                             mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
                                             mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2,
                                             mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
    var description: CMAudioFormatDescription?
    CMAudioFormatDescriptionCreate(allocator: nil, asbd: &format, layoutSize: 0, layout: nil,
                                   magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
    if let description {
        var block: CMBlockBuffer?
        let bytes = samples * 2
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                           customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                           flags: 0, blockBufferOut: &block)
        if let block {
            CMBlockBufferAssureBlockMemory(block)
            pcm.withUnsafeBytes { raw in
                if let base = raw.baseAddress { CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) }
            }
            var buffer: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)),
                                            presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            var sampleSize = 2
            CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: description,
                                      sampleCount: samples, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                      sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &buffer)
            if let buffer {
                while !audio.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                audio.append(buffer)
            }
        }
    }
    audio.markAsFinished()

    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &pixelBuffer)
    guard let pixelBuffer else { throw NSError(domain: "Lumio", code: 93, userInfo: [NSLocalizedDescriptionKey: "no pixel buffer for the sample clip"]) }
    let frames = Int(seconds * fps)
    for frame in 0..<frames {
        let time = Double(frame) / fps
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer),
           let c = CGContext(data: base, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                             bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            // The suite reads colour out of this clip to prove where the picture ended up: a crop of the
            // left edge has to come back red, and a vertical reframe that follows the pointer right has to
            // come back cyan. So the two halves are kept pure through the whole middle band, and the
            // movement that makes every frame different lives in the top and bottom thirds instead.
            let pulse = 0.82 + 0.18 * sin(2 * .pi * time / 1.5)
            c.setFillColor(CGColor(red: 0.95 * pulse, green: 0.21 * pulse, blue: 0.19 * pulse, alpha: 1))
            c.fill(CGRect(x: 0, y: 0, width: size.width / 2, height: size.height))
            let other = 0.86 + 0.14 * cos(2 * .pi * time / 1.5)
            c.setFillColor(CGColor(red: 0.21 * other, green: 0.82 * other, blue: 0.90 * other, alpha: 1))
            c.fill(CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height))
            // A bar sweeping along the top and a dot bouncing along the bottom: motion a cut can be seen in.
            let sweep = size.width * (0.5 + 0.5 * sin(time * 2.0)) - 110
            c.setFillColor(CGColor(red: 0.98, green: 0.97, blue: 0.9, alpha: 1))
            c.fill(CGRect(x: sweep, y: size.height * 0.82, width: 220, height: size.height * 0.1))
            let bounce = size.width * (0.5 + 0.42 * cos(time * 1.6))
            c.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
            c.fillEllipse(in: CGRect(x: bounce - 60, y: size.height * 0.06 + abs(sin(time * 3)) * size.height * 0.07,
                                     width: 120, height: 120))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        while !video.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
        adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
    }
    video.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? NSError(domain: "Lumio", code: 92, userInfo: [NSLocalizedDescriptionKey: "the sample clip was not written"]) }
}

/// Developer-only: writes the suite's input clip into a folder, so a lost fixture is one command away.
@MainActor func makeSampleClip(folder: URL) async {
    do {
        let url = folder.appendingPathComponent("sample.mp4")
        try await writeSampleClip(to: url)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        print("wrote \(url.path) · \((attributes?[.size] as? Int) ?? 0) bytes")
        exit(0)
    } catch {
        print("FAIL \(error.localizedDescription)"); exit(1)
    }
}
