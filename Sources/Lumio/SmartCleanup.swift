import SwiftUI
import AVFoundation

struct CleanupCandidate:Equatable,Identifiable {
    var id=UUID()
    var start:Double
    var end:Double
    var kind:String
    var label:String
    var selected=true
    var duration:Double {max(0,end-start)}
}

private func mergedCleanupCuts(_ cuts:[VideoCut],duration:Double)->[VideoCut] {
    var result:[VideoCut]=[]
    for original in cuts.sorted(by:{$0.start<$1.start}) {
        let cut=VideoCut(start:max(0,min(duration,original.start)),end:max(0,min(duration,original.end)))
        guard cut.end-cut.start>=0.04 else{continue}
        if let last=result.last,last.end>=cut.start-0.02 {result[result.count-1].end=max(last.end,cut.end)}
        else {result.append(cut)}
    }
    return result
}

func cleanupTimelineCandidates(sourceRanges:[VideoCut],clips:[VideoClip],minimumDuration:Double)->[CleanupCandidate] {
    let raw=clips.flatMap {clip in sourceRanges.compactMap {range -> VideoCut? in
        let start=max(clip.sourceStart,range.start),end=min(clip.sourceEnd,range.end)
        guard end-start>=minimumDuration else{return nil}
        return VideoCut(start:clip.timelineTime(forSource:start),end:clip.timelineTime(forSource:end))
    }}
    let duration=clips.map{$0.timelineStart+$0.duration}.max() ?? 0
    return mergedCleanupCuts(raw,duration:duration).map {CleanupCandidate(start:$0.start,end:$0.end,kind:"Silence",label:"Silent pause")}
}

func fillerCleanupCandidates(captions:[CaptionCue])->[CleanupCandidate] {
    let fillers:Set<String>=["um","uh","umm","uhh","erm","hmm","hmmm","eee","ee","ııı","ıı","şey"]
    return captions.flatMap(\.words).compactMap {word in
        let normalized=word.text.lowercased().trimmingCharacters(in:.punctuationCharacters.union(.whitespacesAndNewlines))
        guard fillers.contains(normalized),word.end-word.start>=0.03 else{return nil}
        return CleanupCandidate(start:max(0,word.start-0.025),end:word.end+0.025,kind:"Filler",label:word.text)
    }
}

func analyzeSourceSilence(url:URL,thresholdDB:Double,minimumDuration:Double,padding:Double) async throws->[VideoCut] {
    try await Task.detached(priority:.userInitiated) {
        let asset=AVURLAsset(url:url)
        guard let track=try await asset.loadTracks(withMediaType:.audio).first else {
            throw NSError(domain:"Lumio",code:20,userInfo:[NSLocalizedDescriptionKey:"This recording does not contain an audio track."])
        }
        let descriptions=try await track.load(.formatDescriptions)
        let sampleRate=descriptions.first.flatMap{CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee.mSampleRate} ?? 48_000
        let reader=try AVAssetReader(asset:asset)
        let settings:[String:Any]=[
            AVFormatIDKey:kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey:true,
            AVLinearPCMBitDepthKey:32,
            AVLinearPCMIsNonInterleaved:false,
            AVLinearPCMIsBigEndianKey:false
        ]
        let output=AVAssetReaderTrackOutput(track:track,outputSettings:settings)
        output.alwaysCopiesSampleData=false
        guard reader.canAdd(output) else {throw NSError(domain:"Lumio",code:21,userInfo:[NSLocalizedDescriptionKey:"The audio track could not be analyzed."])}
        reader.add(output)
        guard reader.startReading() else {throw reader.error ?? NSError(domain:"Lumio",code:22,userInfo:[NSLocalizedDescriptionKey:"Audio analysis could not start."])}
        let threshold=pow(10,thresholdDB/20)
        var openStart:Double?,latestEnd=0.0,ranges:[VideoCut]=[]
        while reader.status == .reading,let sample=output.copyNextSampleBuffer() {
            let timestamp=CMSampleBufferGetPresentationTimeStamp(sample).seconds
            guard timestamp.isFinite else{continue}
            var block:CMBlockBuffer?
            var list=AudioBufferList(mNumberBuffers:1,mBuffers:AudioBuffer(mNumberChannels:0,mDataByteSize:0,mData:nil))
            let status=CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample,bufferListSizeNeededOut:nil,bufferListOut:&list,bufferListSize:MemoryLayout<AudioBufferList>.size,blockBufferAllocator:kCFAllocatorDefault,blockBufferMemoryAllocator:kCFAllocatorDefault,flags:UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),blockBufferOut:&block)
            guard status==noErr,let data=list.mBuffers.mData else{continue}
            let count=Int(list.mBuffers.mDataByteSize)/MemoryLayout<Float>.size
            let values=data.bindMemory(to:Float.self,capacity:count)
            var squares=0.0
            for index in 0..<count {let value=Double(values[index]);squares+=value*value}
            let rms=count>0 ? sqrt(squares/Double(count)):0
            var sampleDuration=CMSampleBufferGetDuration(sample).seconds
            if !sampleDuration.isFinite || sampleDuration<=0 {
                sampleDuration=Double(CMSampleBufferGetNumSamples(sample))/sampleRate
            }
            latestEnd=max(latestEnd,timestamp+sampleDuration)
            if rms<=threshold {
                if openStart==nil {openStart=timestamp}
            } else if let start=openStart {
                if timestamp-start>=minimumDuration {
                    let a=start+padding,b=timestamp-padding
                    if b-a>=0.04 {ranges.append(VideoCut(start:a,end:b))}
                }
                openStart=nil
            }
        }
        if reader.status == .failed {throw reader.error ?? NSError(domain:"Lumio",code:23,userInfo:[NSLocalizedDescriptionKey:"Audio analysis failed."])}
        if let start=openStart,latestEnd-start>=minimumDuration {
            let a=start+padding,b=latestEnd-padding
            if b-a>=0.04 {ranges.append(VideoCut(start:a,end:b))}
        }
        return ranges
    }.value
}

@MainActor extension Studio {
    func scanSilence() async {
        guard let source,stillImage==nil,!cleanupScanning,!busy else{return}
        cleanupScanning=true
        defer{cleanupScanning=false}
        do {
            let ranges=try await analyzeSourceSilence(url:source,thresholdDB:cleanupThreshold,minimumDuration:cleanupMinimumDuration,padding:cleanupPadding)
            let silence=cleanupTimelineCandidates(sourceRanges:ranges,clips:videoClips,minimumDuration:0.04)
            cleanupCandidates.removeAll{$0.kind=="Silence"}
            cleanupCandidates.append(contentsOf:silence)
            cleanupCandidates.sort{$0.start<$1.start}
        } catch {message="Silence analysis failed: \(error.localizedDescription)"}
    }
    func findFillerWords() {
        guard !captions.isEmpty else{message="Generate captions first so Lumio can use word timings to find filler words.";return}
        cleanupCandidates.removeAll{$0.kind=="Filler"}
        cleanupCandidates.append(contentsOf:fillerCleanupCandidates(captions:captions))
        cleanupCandidates.sort{$0.start<$1.start}
    }
    func applySelectedCleanup() {
        let chosen=cleanupCandidates.filter(\.selected).map{VideoCut(start:$0.start,end:$0.end)}
        guard !chosen.isEmpty else{message="Select at least one cleanup suggestion.";return}
        if rippleDelete(chosen) {cleanupCandidates=[];flash("\(chosen.count) range\(chosen.count==1 ? "":"s") removed")}
    }
    /// Removes timeline ranges and closes the gaps across clips, zooms, captions and added audio as one undoable edit.
    @discardableResult func rippleDelete(_ ranges:[VideoCut])->Bool {
        let cuts=mergedCleanupCuts(ranges,duration:duration)
        guard !cuts.isEmpty else{message="Select at least one range to remove.";return false}
        let clips=retakeRippleClips(videoClips,cuts:cuts)
        guard !clips.isEmpty else{message="This would remove the entire video. Keep at least part of it.";return false}
        var edit=snapshot
        edit.clips=clips
        edit.zooms=zooms.compactMap {zoom in
            var copy=zoom;copy.start=retakeRippleTime(zoom.start,cuts:cuts);copy.end=retakeRippleTime(zoom.end,cuts:cuts)
            guard copy.end-copy.start>=0.1 else{return nil};copy.transition=min(copy.transition,(copy.end-copy.start)/2);return copy
        }
        edit.captions=captions.compactMap {cue in
            var copy=cue;copy.start=retakeRippleTime(cue.start,cuts:cuts);copy.end=retakeRippleTime(cue.end,cuts:cuts)
            guard copy.end-copy.start>=0.04 else{return nil}
            copy.words=cue.words.compactMap {word in
                var value=word;value.start=retakeRippleTime(word.start,cuts:cuts);value.end=retakeRippleTime(word.end,cuts:cuts)
                return value.end-value.start>=0.01 ? value:nil
            }
            if !cue.words.isEmpty {copy.text=copy.words.map(\.text).joined(separator:" ");if copy.words.isEmpty{return nil}}
            return copy
        }
        edit.annotations=remappedAnnotations(annotations) { retakeRippleTime($0,cuts:cuts) }
        invalidateSensitiveScan()
        edit.markers=remappedMarkers(markers) { retakeRippleTime($0,cuts:cuts) }
        edit.audioTracks=audioTracks.flatMap {track in
            keptVideoRanges(start:track.timelineStart,end:track.timelineStart+track.duration,cuts:cuts).enumerated().compactMap {index,range in
                guard range.end-range.start>=0.04 else{return nil}
                var copy=track;copy.id=index==0 ? track.id:UUID();copy.timelineStart=retakeRippleTime(range.start,cuts:cuts)
                copy.sourceStart=track.sourceStart+range.start-track.timelineStart;copy.sourceEnd=copy.sourceStart+range.end-range.start
                return copy
            }
        }
        player.pause();playing=false
        let target=retakeRippleTime(position,cuts:cuts)
        undoStack.append(snapshot);if undoStack.count>80{undoStack.removeFirst()};redoStack=[]
        restore(edit);trimTimelineItemsToDuration();seek(target)
        return true
    }
}

struct SmartCleanupPanel:View {
    @ObservedObject var studio:Studio
    var chosen:[CleanupCandidate] {studio.cleanupCandidates.filter(\.selected)}
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Find slow moments, review every suggestion, then remove only the ones you choose.").font(.caption).foregroundStyle(.secondary)
            Text("Silent Pauses").fontWeight(.medium)
            VStack(alignment:.leading,spacing:12) {
                valueSlider("Sensitivity",value:$studio.cleanupThreshold,range:-60 ... -25,format:{"\(Int($0)) dB"})
                valueSlider("Minimum Pause",value:$studio.cleanupMinimumDuration,range:0.3 ... 2,format:{String(format:"%.1f s",$0)})
                valueSlider("Keep Breathing Room",value:$studio.cleanupPadding,range:0 ... 0.4,format:{String(format:"%.2f s",$0)})
                Button {Task{await studio.scanSilence()}} label:{Label(studio.cleanupScanning ? "Analyzing…":"Find Silent Pauses",systemImage:"waveform.badge.magnifyingglass")}.disabled(studio.cleanupScanning)
            }
            Divider()
            Text("Filler Words").fontWeight(.medium)
            VStack(alignment:.leading,spacing:8) {
                Text("Uses caption word timing to find um, uh, erm, hmm and common Turkish fillers.").font(.caption).foregroundStyle(.secondary)
                Button {studio.findFillerWords()} label:{Label("Find Filler Words",systemImage:"captions.bubble")}
            }
            if !studio.cleanupCandidates.isEmpty {
                HStack {
                    Text("\(chosen.count) of \(studio.cleanupCandidates.count) selected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("All") {for index in studio.cleanupCandidates.indices {studio.cleanupCandidates[index].selected=true}}
                    Button("None") {for index in studio.cleanupCandidates.indices {studio.cleanupCandidates[index].selected=false}}
                }.buttonStyle(.plain)
                ForEach($studio.cleanupCandidates) {$candidate in
                    HStack(spacing:9) {
                        Toggle("",isOn:$candidate.selected).labelsHidden()
                        VStack(alignment:.leading,spacing:2) {
                            Text(candidate.label).lineLimit(1)
                            Text("\(candidate.kind) · \(stamp(candidate.start))–\(stamp(candidate.end)) · \(candidate.duration,format:.number.precision(.fractionLength(2))) s").font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {studio.position=candidate.start;studio.seek(candidate.start)} label:{Image(systemName:"play.fill")}.buttonStyle(.plain).help("Preview from Here")
                    }.padding(9).background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                }
                Button {studio.applySelectedCleanup()} label:{Label("Remove Selected · \(chosen.reduce(0){$0+$1.duration},format:.number.precision(.fractionLength(1))) s",systemImage:"scissors")}
                    .buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
                Text("Nothing is removed until you press the button. Undo restores the complete edit; the raw recording remains untouched.").font(.caption2).foregroundStyle(.secondary)
            }
        }.disabled(studio.busy || studio.recording || studio.voiceoverRecording || studio.captionGenerating)
    }
    private func valueSlider(_ title:String,value:Binding<Double>,range:ClosedRange<Double>,format:(Double)->String)->some View {
        VStack(spacing:5) {HStack {Text(title).font(.caption);Spacer();Text(format(value.wrappedValue)).font(.caption).foregroundStyle(.secondary).monospacedDigit()};Slider(value:value,in:range)}
    }
}
