import SwiftUI
import AVFoundation
import CoreAudio

struct SoundDevice: Identifiable { let id: UInt32; let name: String }
func selectDefaultInputDevice(uniqueID:String)->Bool {
    guard !uniqueID.isEmpty else{return true}
    var address=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    var size:UInt32=0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size)==noErr,size>=MemoryLayout<AudioObjectID>.size else{return false}
    var ids=[AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
    let status:OSStatus=ids.withUnsafeMutableBytes{buffer in guard let base=buffer.baseAddress else{return OSStatus(-1)};return AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,base)}
    guard status==noErr else{return false}
    let match=ids.first{id in
        var uid:Unmanaged<CFString>?;var bytes=UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var property=AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyDeviceUID,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(id,&property,0,nil,&bytes,&uid)==noErr,let value=uid?.takeUnretainedValue() else{return false}
        return value as String == uniqueID
    }
    guard var selected=match else{return false}
    var property=AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultInputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
    return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&property,0,nil,UInt32(MemoryLayout<AudioObjectID>.size),&selected)==noErr
}
@MainActor final class AudioDevices: ObservableObject {
    @Published var microphones: [AVCaptureDevice] = []
    @Published var outputs: [SoundDevice] = []
    @Published var outputID: UInt32 = 0
    func refresh() {
        microphones = AVCaptureDevice.DiscoverySession(deviceTypes:[.microphone,.external],mediaType:.audio,position:.unspecified).devices
        var address = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDevices,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr else { return }
        var ids = [AudioObjectID](repeating:0,count:Int(size)/MemoryLayout<AudioObjectID>.size)
        let status = ids.withUnsafeMutableBytes { AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,$0.baseAddress!) }
        guard status == noErr else { return }
        outputs = ids.compactMap { id in
            var streams = AudioObjectPropertyAddress(mSelector:kAudioDevicePropertyStreams,mScope:kAudioDevicePropertyScopeOutput,mElement:kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id,&streams,0,nil,&bytes) == noErr, bytes > 0 else { return nil }
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var prop = AudioObjectPropertyAddress(mSelector:kAudioObjectPropertyName,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(id,&prop,0,nil,&nameSize,&name) == noErr else { return nil }
            guard let value=name?.takeUnretainedValue() else{return nil}
            return SoundDevice(id:id,name:value as String)
        }
        var prop = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        var id: AudioObjectID = 0; var bytes = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&prop,0,nil,&bytes,&id) == noErr { outputID = id }
    }
    func selectOutput(_ id: UInt32) -> Bool {
        var id = id
        var prop = AudioObjectPropertyAddress(mSelector:kAudioHardwarePropertyDefaultOutputDevice,mScope:kAudioObjectPropertyScopeGlobal,mElement:kAudioObjectPropertyElementMain)
        let result = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),&prop,0,nil,UInt32(MemoryLayout<AudioObjectID>.size),&id)
        refresh(); return result == noErr
    }
}
struct AudioDevicePanel: View {
    @ObservedObject var studio: Studio
    @StateObject var devices = AudioDevices()
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Audio Devices").font(.headline)
            Toggle("Record System Audio",isOn:$studio.systemAudio)
            Toggle("Record Microphone",isOn:$studio.mic)
            Picker("Microphone",selection:$studio.microphoneID) {
                Text("System Default").tag("")
                ForEach(devices.microphones,id:\.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                if !studio.microphoneID.isEmpty && !devices.microphones.contains(where:{$0.uniqueID == studio.microphoneID}) {
                    Text("Selected microphone is unavailable").tag(studio.microphoneID)
                }
            }.disabled(!studio.mic)
            Divider()
            Toggle("Record Camera",isOn:Binding(get:{studio.camera},set:{studio.camera=$0;Task{await studio.prepareCameraPreview()}}))
            Picker("Camera",selection:Binding(get:{studio.cameraID},set:{studio.cameraID=$0;Task{await studio.prepareCameraPreview()}})) {
                Text("System Default").tag("")
                ForEach(studio.cameraRecorder.devices(),id:\.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
            }.disabled(!studio.camera)
            Divider()
            Picker("Audio Output",selection:Binding(get:{devices.outputID},set:{ id in
                if !devices.selectOutput(id) { studio.message = "The audio output could not be changed. Check the device connection." }
            })) {
                ForEach(devices.outputs) { Text($0.name).tag($0.id) }
            }
            Text("Output selection changes the Mac's default speaker or headphones. System audio capture follows the selected screen or window source.").font(.caption).foregroundStyle(.secondary)
            Button("Refresh Devices") { devices.refresh() }
        }.padding(20).frame(width:370).onAppear { devices.refresh() }
            .onReceive(NotificationCenter.default.publisher(for:AVCaptureDevice.wasConnectedNotification)) { _ in devices.refresh() }
            .onReceive(NotificationCenter.default.publisher(for:AVCaptureDevice.wasDisconnectedNotification)) { _ in devices.refresh() }
            .disabled(studio.busy || studio.recording)
    }
}
