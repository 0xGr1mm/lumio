import SwiftUI

struct SavedEditVersion: Codable, Equatable, Identifiable {
    var id=UUID()
    var name:String
    var createdAt=Date()
    var edit:EditSnapshot
    var length:Double {edit.clips.map{$0.timelineStart+$0.duration}.max() ?? 0}
    func normalized(sourceDuration:Double,added:[String:Double]=[:])->SavedEditVersion {
        var copy=self
        copy.name=String(name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        if copy.name.isEmpty {copy.name="Untitled version"}
        if let markers=edit.retakes {copy.edit.retakes=normalizedRetakes(markers,duration:sourceDuration)}
        copy.edit.look=edit.look.normalized();copy.edit.motion=edit.motion.normalized()
        copy.edit.clips=normalizedVideoClips(edit.clips,sourceDuration:sourceDuration,added:added)
        let length=copy.length
        copy.edit.zooms=normalizedZoomClips(edit.zooms,duration:length)
        copy.edit.captions=normalizedCaptionCues(edit.captions,duration:length)
        copy.edit.captionStyle=edit.captionStyle.normalized()
        copy.edit.audioTracks=normalizedAudioTracks(edit.audioTracks)
        copy.edit.audioSettings=edit.audioSettings.normalized();copy.edit.keyboardStyle=edit.keyboardStyle.normalized()
        if let path=copy.edit.camera,!FileManager.default.fileExists(atPath:path){copy.edit.camera=nil}
        return copy
    }
}

@MainActor extension Studio {
    @discardableResult func saveVersion(named requested:String)->Bool {
        guard source != nil,!busy,!voiceoverRecording,!captionGenerating else{return false}
        guard savedVersions.count<24 else{message="The shelf holds 24 versions. Remove a version before saving another.";return false}
        let name=String(requested.trimmingCharacters(in:.whitespacesAndNewlines).prefix(60))
        savedVersions.insert(SavedEditVersion(name:name.isEmpty ? "Version \(savedVersions.count+1)":name,edit:snapshot),at:0)
        return true
    }
    func useVersion(_ id:UUID) {
        guard let version=savedVersions.first(where:{$0.id==id}),!busy,!voiceoverRecording,!captionGenerating else{return}
        guard version.edit != snapshot else{return}
        // Keep an unsaved experiment before switching; never evict a user's version.
        if !savedVersions.contains(where:{$0.edit==snapshot}) {
            guard saveVersion(named:"Before switching · \(Date().formatted(date:.omitted,time:.shortened))") else{return}
        }
        player.pause();playing=false
        undoStack.append(snapshot);if undoStack.count>80{undoStack.removeFirst()};redoStack=[]
        restore(version.normalized(sourceDuration:sourceDuration,added:addedSources).edit)
        seek(position)
    }
}

struct VersionShelfPanel:View {
    @ObservedObject var studio:Studio
    @State private var name=""
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Try another direction. Keep the one you love.").font(.headline)
            Text("Save complete edits, switch between them, and keep experimenting. Your current changes are kept before every switch.").font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Name this version",text:$name).textFieldStyle(.roundedBorder).onSubmit{save()}
                Button(action:save){Image(systemName:"plus")}.help("Save Current Version").accessibilityLabel("Save Current Version")
                    .disabled(studio.savedVersions.count>=24)
            }
            HStack {
                Text("\(studio.savedVersions.count) / 24 versions").foregroundStyle(.secondary)
                Spacer()
                Button{studio.saveProject()}label:{Image(systemName:"square.and.arrow.down")}.help("Save Project with Versions").accessibilityLabel("Save Project with Versions")
            }.font(.caption)
            Text("Versions stay in this .lumio project when you save it. Original media files are shared, not copied.").font(.caption).foregroundStyle(.secondary)
            if studio.savedVersions.isEmpty {
                VStack(spacing:10){Image(systemName:"square.stack.3d.up").font(.largeTitle);Text("Your first experiment starts here");Text("Save your current edit above.").font(.caption)}
                    .foregroundStyle(.secondary).frame(maxWidth:.infinity).padding(.vertical,24)
            }
            ForEach(studio.savedVersions) { version in
                versionCard(version)
            }
        }.disabled(studio.busy || studio.voiceoverRecording || studio.captionGenerating)
    }
    private func save(){if studio.saveVersion(named:name){name=""}}
    private func versionCard(_ version:SavedEditVersion)->some View {
        let current=version.edit==studio.snapshot
        return VStack(alignment:.leading,spacing:10) {
            HStack {
                RoundedRectangle(cornerRadius:5).fill(LinearGradient(colors:[version.edit.look.first.color,version.edit.look.second.color],startPoint:.topLeading,endPoint:.bottomTrailing)).frame(width:30,height:30)
                TextField("Version name",text:Binding(get:{studio.savedVersions.first(where:{$0.id==version.id})?.name ?? version.name},set:{newName in
                    if let index=studio.savedVersions.firstIndex(where:{$0.id==version.id}){studio.savedVersions[index].name=String(newName.prefix(60))}
                })).textFieldStyle(.plain).fontWeight(.semibold)
                if current {Image(systemName:"checkmark.circle.fill").foregroundStyle(accent).help("Matches Current Edit")}
            }
            Text("\(version.edit.look.aspect) · \(stamp(version.length)) · \(version.edit.clips.count) clips").font(.caption).foregroundStyle(.secondary)
            Text("\(version.edit.zooms.count) zooms · \(version.edit.captions.count) captions · \(version.edit.audioTracks.count) audio tracks").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Text(version.createdAt,style:.date).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button{studio.useVersion(version.id)}label:{Image(systemName:"arrow.uturn.backward.circle")}.help("Use This Version").accessibilityLabel("Use \(version.name)").disabled(current)
                Button{studio.savedVersions.removeAll{$0.id==version.id}}label:{Image(systemName:"trash")}.help("Remove Saved Version").accessibilityLabel("Remove \(version.name)")
            }.buttonStyle(.borderless)
        }.padding(12).background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(current ? accent.opacity(0.6):Color.white.opacity(0.08)))
    }
}
