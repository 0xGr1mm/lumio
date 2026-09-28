import AVFoundation
import Foundation

/// Loudness envelope of a recording's audio, one peak per bucket across the whole file.
/// The timeline draws it so cuts can be placed on what is actually heard.
func audioPeaks(url:URL,buckets:Int=1_600) async throws->[Float] {
    try await Task.detached(priority:.utility) {
        let asset=AVURLAsset(url:url)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else { return [] }
        let duration=try await asset.load(.duration).seconds
        guard duration.isFinite,duration>0,buckets>0 else { return [] }
        let reader=try AVAssetReader(asset:asset)
        let settings:[String:Any]=[
            AVFormatIDKey:kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:true,
            AVLinearPCMBitDepthKey:32,
            AVLinearPCMIsNonInterleaved:false,
            AVLinearPCMIsBigEndianKey:false
        ]
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:settings)
        guard reader.canAdd(output) else { return [] }
        reader.add(output);reader.startReading()
        let descriptions=try await track.load(.formatDescriptions)
        let format=descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let channels=Int(format?.mChannelsPerFrame ?? 1),sampleRate=format?.mSampleRate ?? 48_000
        let total=max(1,Int(duration*sampleRate))
        let perBucket=max(1,total/buckets)
        var peaks=[Float](repeating:0,count:buckets)
        var index=0
        while let buffer=output.copyNextSampleBuffer() {
            guard let block=CMSampleBufferGetDataBuffer(buffer) else { continue }
            var length=0
            var pointer:UnsafeMutablePointer<Int8>?
            guard CMBlockBufferGetDataPointer(block,atOffset:0,lengthAtOffsetOut:nil,totalLengthOut:&length,dataPointerOut:&pointer) == noErr,let pointer else { continue }
            pointer.withMemoryRebound(to:Float.self,capacity:length/4) { samples in
                for position in stride(from:0,to:length/4,by:max(1,channels)) {
                    let bucket=min(buckets-1,index/perBucket)
                    peaks[bucket]=max(peaks[bucket],abs(samples[position]))
                    index+=1
                }
            }
            CMSampleBufferInvalidate(buffer)
            if Task.isCancelled { return [] }
        }
        guard reader.status != .failed else { return [] }
        // Quiet recordings would draw as a flat line, so the envelope is lifted to its own loudest point.
        let loudest=peaks.max() ?? 0
        guard loudest>0.0001 else { return peaks }
        return peaks.map { min(1,$0/loudest) }
    }.value
}

/// Peak at a source time, for an envelope covering a file of the given length.
func peak(_ peaks:[Float],at sourceTime:Double,length:Double)->Float {
    guard !peaks.isEmpty,length>0,sourceTime.isFinite else { return 0 }
    let index=Int(max(0,min(1,sourceTime/length))*Double(peaks.count-1))
    return peaks[max(0,min(peaks.count-1,index))]
}

@MainActor extension Studio {
    /// Reads the envelope of the opened recording and of every added one, in the background.
    func loadWaveforms() {
        waveformTask?.cancel()
        let opened=source
        let extra=addedSources.map(\.key)
        waveformTask=Task { [weak self] in
            if let opened,await self?.waveforms[""] == nil {
                let peaks=(try? await audioPeaks(url:opened)) ?? []
                if Task.isCancelled { return }
                await MainActor.run { self?.waveforms[""]=peaks }
            }
            for path in extra {
                if Task.isCancelled { return }
                if await self?.waveforms[path] != nil { continue }
                let peaks=(try? await audioPeaks(url:URL(fileURLWithPath:path))) ?? []
                if Task.isCancelled { return }
                await MainActor.run { self?.waveforms[path]=peaks }
            }
        }
    }
    /// Envelope value for a clip at a timeline time, 0…1.
    func waveformLevel(at time:Double,clip:VideoClip)->Float {
        let key=clip.source ?? ""
        guard let peaks=waveforms[key],!peaks.isEmpty else { return 0 }
        let length=clip.source.flatMap { addedSources[$0] } ?? sourceDuration
        return peak(peaks,at:clip.sourceTime(forTimeline:time),length:length)
    }
}
