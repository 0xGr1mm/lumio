import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct AudioTrackEdit: Codable, Equatable, Identifiable {
    var id=UUID();var name:String;var path:String;var kind:String
    var timelineStart:Double=0;var sourceStart:Double=0;var sourceEnd:Double
    var volume:Double=0.8;var muted=false;var loop=false
    /// How long the file itself is. A track can be pulled out past this only when it loops, because
    /// otherwise the extra length would simply play nothing.
    var sourceLength:Double? = nil
    var duration:Double {max(0,sourceEnd-sourceStart)}
    var material:Double { let value=sourceLength ?? sourceEnd;return value.isFinite && value>0 ? value:sourceEnd }
}
struct AudioMixSettings: Codable, Equatable {
    var systemVolume=1.0;var ducking=true;var duckLevel=0.25
    var microphoneVolume:Double?=nil
    var enhanceVoice:Bool?=nil
    var voiceIsolation:Double?=nil
    var levelVoice:Bool?=nil
    func normalized()->AudioMixSettings {
        var value=self;value.systemVolume=min(1,max(0,value.systemVolume.isFinite ? value.systemVolume:1));value.duckLevel=min(1,max(0,value.duckLevel.isFinite ? value.duckLevel:0.25))
        if let volume=value.microphoneVolume {value.microphoneVolume=min(1,max(0,volume.isFinite ? volume:1))}
        if let strength=value.voiceIsolation {value.voiceIsolation=min(1,max(0,strength.isFinite ? strength:1))}
        return value
    }
}
func normalizedAudioTracks(_ tracks:[AudioTrackEdit],limit:Int=64)->[AudioTrackEdit] {
    var result:[AudioTrackEdit]=[],ids=Set<UUID>()
    for original in tracks.prefix(limit) {
        guard original.timelineStart.isFinite,original.sourceStart.isFinite,original.sourceEnd.isFinite,original.volume.isFinite,FileManager.default.fileExists(atPath:original.path) else{continue}
        var value=original
        value.name=String(value.name.prefix(200));value.timelineStart=max(0,min(86_400,value.timelineStart))
        value.sourceStart=max(0,min(86_400,value.sourceStart));value.sourceEnd=max(0,min(86_400,value.sourceEnd))
        value.volume=max(0,min(1,value.volume));if !["Music","Voiceover","Imported"].contains(value.kind){value.kind="Imported"}
        guard value.sourceEnd-value.sourceStart>=0.04 else{continue}
        if ids.contains(value.id){value.id=UUID()};ids.insert(value.id);result.append(value)
    }
    return result
}
struct BundledMusic:Identifiable {
    var id:String {file};var name:String;var category:String;var file:String;var length:String
}
let bundledMusic=[
    BundledMusic(name:"Lo-Fi Drift",category:"Lo-Fi",file:"lofi-drift",length:"0:16"),
    BundledMusic(name:"Ambient Air",category:"Ambient",file:"ambient-air",length:"0:16"),
    BundledMusic(name:"Warm Keys",category:"Instrumental",file:"warm-keys",length:"0:16"),
    BundledMusic(name:"Neon Pulse",category:"Electronic",file:"neon-pulse",length:"0:16"),
    BundledMusic(name:"Cinematic Rise",category:"Cinematic",file:"cinematic-rise",length:"0:16")]

@MainActor extension Studio {
    func addBundledMusic(_ music:BundledMusic) {
        guard let url=Bundle.main.url(forResource:music.file,withExtension:"wav",subdirectory:"Audio") else {message="The bundled music file is missing.";return}
        audioTracks.append(AudioTrackEdit(name:music.name,path:url.path,kind:"Music",timelineStart:position,sourceEnd:16,loop:true,sourceLength:16));selectedAudioTrack=audioTracks.last?.id
        flash("\(music.name) added to the timeline")
    }
    func previewMusic(_ music:BundledMusic) {
        guard let url=Bundle.main.url(forResource:music.file,withExtension:"wav",subdirectory:"Audio") else{return}
        do {musicPreviewPlayer=try AVAudioPlayer(contentsOf:url);musicPreviewPlayer?.play()} catch {message=error.localizedDescription}
    }
    /// Drags on an audio block's edges. Pulling the head in keeps the sound where it already sat under the
    /// playhead — the material is trimmed rather than slid — and pulling the tail out only goes past the end
    /// of the file when the track loops, since otherwise there would be nothing there to play.
    func setAudioRange(_ id:UUID,to range:TimelineRange) {
        guard let index=audioTracks.firstIndex(where:{ $0.id == id }) else { return }
        let track=audioTracks[index]
        let start=max(0,range.start),end=max(start+0.1,range.end)
        if abs(start-track.timelineStart)>0.001 {
            let wanted=track.sourceStart+(start-track.timelineStart)
            let trimmed=max(0,min(track.sourceEnd-0.1,wanted))
            audioTracks[index].sourceStart=trimmed
            audioTracks[index].timelineStart=max(0,track.timelineStart+(trimmed-track.sourceStart))
        } else {
            let limit=track.loop ? 86_400:max(0.1,track.material-track.sourceStart)
            audioTracks[index].sourceEnd=track.sourceStart+max(0.1,min(end-start,limit))
        }
        refreshComposition()
    }
    /// Cuts an audio track in two at a moment, so a piece of it can be taken out or moved on its own.
    @discardableResult func splitAudioTrack(_ id:UUID,at requested:Double?=nil)->UUID? {
        guard let index=audioTracks.firstIndex(where:{ $0.id == id }) else { return nil }
        let track=audioTracks[index]
        let at=requested ?? position
        let offset=at-track.timelineStart
        guard offset>0.1,offset<track.duration-0.1 else { message="Put the playhead inside the audio before cutting it.";return nil }
        var left=track;left.sourceEnd=track.sourceStart+offset
        var right=track;right.id=UUID();right.sourceStart=track.sourceStart+offset;right.timelineStart=at
        // A looping track that is cut keeps playing from where the cut left off, not from the top again.
        if track.loop,right.sourceStart>track.material { right.sourceStart=track.sourceStart }
        audioTracks.replaceSubrange(index...index,with:[left,right])
        selectedAudioTrack=right.id;focusTimeline(.audio,id:right.id)
        refreshComposition()
        flash("Audio cut · delete either piece to remove it")
        return right.id
    }
    func chooseAudioTrack() {
        let picker=NSOpenPanel();picker.allowedContentTypes=[.audio];picker.allowsMultipleSelection=false
        guard picker.runModal() == .OK,let url=picker.url else{return}
        Task { do {let length=try await AVURLAsset(url:url).load(.duration).seconds;guard length.isFinite,length>0 else{throw failure("The audio file is empty.")};audioTracks.append(AudioTrackEdit(name:url.deletingPathExtension().lastPathComponent,path:url.path,kind:"Imported",timelineStart:position,sourceEnd:length,sourceLength:length));selectedAudioTrack=audioTracks.last?.id} catch {message=error.localizedDescription} }
    }
    func toggleVoiceover() async {
        if voiceoverRecording {stopVoiceover();return}
        guard await AVCaptureDevice.requestAccess(for:.audio) else{message="Microphone permission is required to record a voiceover.";return}
        do {
            guard selectDefaultInputDevice(uniqueID:microphoneID) else{throw failure("The selected microphone could not be activated.")}
            let folder=preferences.folder.appendingPathComponent("Voiceovers");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            let url=folder.appendingPathComponent("Voiceover-\(UUID().uuidString.prefix(8)).m4a")
            let settings:[String:Any]=[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:44_100,AVNumberOfChannelsKey:1,AVEncoderAudioQualityKey:AVAudioQuality.high.rawValue]
            voiceRecorder=try AVAudioRecorder(url:url,settings:settings);voiceRecorder?.prepareToRecord();voiceoverTimelineStart=position;voiceRecorder?.record();voiceoverRecording=true;player.play()
            voiceoverTimer=Timer.scheduledTimer(withTimeInterval:0.1,repeats:true){[weak self]_ in Task{@MainActor in self?.objectWillChange.send()}}
        } catch {message="Voiceover could not start: \(error.localizedDescription)"}
    }
    func stopVoiceover() {
        guard let recorder=voiceRecorder else{return};let length=recorder.currentTime;recorder.stop();voiceoverTimer?.invalidate();voiceoverTimer=nil;voiceoverRecording=false;player.pause();playing=false
        if length>0.05 {audioTracks.append(AudioTrackEdit(name:"Voiceover",path:recorder.url.path,kind:"Voiceover",timelineStart:voiceoverTimelineStart,sourceEnd:length,volume:1,sourceLength:length));selectedAudioTrack=audioTracks.last?.id}
        voiceRecorder=nil
    }
}

struct AudioPanel:View {
    @ObservedObject var studio:Studio
    @StateObject private var devices=AudioDevices()
    @State private var category="Lo-Fi"
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if let clip=studio.selectedVideoClip {
                Text("Selected clip").font(.system(size:13,weight:.semibold))
                MotionSlider(title:"Volume",value:Binding(get:{studio.selectedVideoClip?.resolvedVolume ?? 1},set:{studio.setClipVolume(clip.id,to:$0)}),range:0...1)
                Toggle("Mute clip",isOn:Binding(get:{(studio.selectedVideoClip?.resolvedVolume ?? 1)<0.001},set:{studio.setClipVolume(clip.id,to:$0 ? 0:1)}))
                Divider()
            }
            Text("Recording audio").font(.system(size:13,weight:.semibold))
            MotionSlider(title:"System",value:$studio.audioSettings.systemVolume,range:0...1)
            if studio.microphonePath != nil {
                MotionSlider(title:"Microphone",value:Binding(get:{studio.audioSettings.microphoneVolume ?? 1},set:{studio.audioSettings.microphoneVolume=$0}),range:0...1)
            } else if studio.source != nil && studio.stillImage == nil {
                Text("This recording has no separate microphone track. New recordings keep the microphone on its own track.").font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Enhance Voice",isOn:Binding(get:{studio.audioSettings.enhanceVoice ?? false},set:{studio.audioSettings.enhanceVoice=$0})).disabled(studio.source == nil || studio.stillImage != nil)
            if studio.audioSettings.enhanceVoice ?? false {
                MotionSlider(title:"Noise Removal",value:Binding(get:{(studio.audioSettings.voiceIsolation ?? 1)*100},set:{studio.audioSettings.voiceIsolation=$0/100}),range:0...100,suffix:"%")
                Toggle("Level Voice Loudness",isOn:Binding(get:{studio.audioSettings.levelVoice ?? true},set:{studio.audioSettings.levelVoice=$0}))
                if studio.voiceProcessing { HStack(spacing:8) { ProgressView().controlSize(.small); Text("Processing the \(studio.voiceSourceDescription)…") }.font(.caption) }
                Text("Removes background noise with Apple's on-device voice isolation, evens out loudness and limits peaks. Applies to the \(studio.voiceSourceDescription).").font(.caption).foregroundStyle(.secondary)
            }
            Divider();HStack{Text("Mixer").font(.headline);Spacer();Button{studio.chooseAudioTrack()}label:{Image(systemName:"plus")}.help("Add Audio Track")}
            if studio.audioTracks.isEmpty {Text("No audio tracks").font(.caption).foregroundStyle(.secondary)}
            ForEach($studio.audioTracks){$track in HStack{Button{track.muted.toggle()}label:{Image(systemName:track.muted ? "speaker.slash.fill":"speaker.wave.2.fill")}.help(track.muted ? "Unmute":"Mute");VStack(alignment:.leading){Text(track.name).lineLimit(1);Slider(value:$track.volume,in:0...1)};Button{studio.audioTracks.removeAll{$0.id==track.id}}label:{Image(systemName:"trash")}.help("Delete Audio Track")}.font(.caption)}
            DisclosureGroup("Voiceover & music") {
                VStack(alignment:.leading,spacing:14) {
            Text("Voiceover").font(.headline)
            Picker("Input Microphone",selection:$studio.microphoneID) {Text("System Default").tag("");ForEach(devices.microphones,id:\.uniqueID){Text($0.localizedName).tag($0.uniqueID)}}
            Button {Task{await studio.toggleVoiceover()}} label:{Image(systemName:studio.voiceoverRecording ? "stop.fill":"mic.fill").frame(maxWidth:.infinity).padding(7)}.buttonStyle(.borderedProminent).tint(studio.voiceoverRecording ? .red:accent).foregroundStyle(.black).help(studio.voiceoverRecording ? "Stop Voiceover":"Record Voiceover at Playhead")
            Divider();Text("Background Music").font(.headline)
            ScrollView(.horizontal,showsIndicators:false){HStack{ForEach(["Lo-Fi","Ambient","Instrumental","Electronic","Cinematic"],id:\.self){name in Button{name == category ? ():(category=name)}label:{Text(name).font(.caption).padding(.horizontal,10).padding(.vertical,5).background(category == name ? .white.opacity(0.22):.white.opacity(0.07)).clipShape(Capsule())}.buttonStyle(.plain)}}}
            ForEach(bundledMusic.filter{$0.category==category}){music in HStack{Button{studio.addBundledMusic(music)}label:{Image(systemName:"plus.circle")}.help("Add \(music.name) to Timeline");Text(music.name);Spacer();Text(music.length).foregroundStyle(.secondary);Button{studio.previewMusic(music)}label:{Image(systemName:"play.circle")}.help("Preview \(music.name)")}}
                }.padding(.top,12)
            }
            DisclosureGroup("Mixing options") {
                VStack(alignment:.leading,spacing:14) {
            Divider();Toggle("Duck system audio under voice",isOn:$studio.audioSettings.ducking)
            if studio.audioSettings.ducking {MotionSlider(title:"Duck Level",value:$studio.audioSettings.duckLevel,range:0...1)}
                }.padding(.top,12)
            }
        }.font(.system(size:12)).onAppear{devices.refresh()}
    }
}
