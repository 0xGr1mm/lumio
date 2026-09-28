import Foundation
struct EditSnapshot:Codable,Equatable {
    var retakes:[RetakeMarker]? = nil
    var look:Look;var motion:MotionSettings;var zooms:[ZoomClip];var camera:String?;var clips:[VideoClip];var captions:[CaptionCue];var captionStyle:CaptionStyle;var audioTracks:[AudioTrackEdit];var audioSettings:AudioMixSettings;var keyboardStyle:KeyboardOverlayStyle
    var cameraOffset:Double? = nil
    var annotations:[Annotation]? = nil
    var markers:[TimelineMarker]? = nil
}
@MainActor extension Studio {
    var snapshot:EditSnapshot { EditSnapshot(retakes:retakes,look:look,motion:motion,zooms:zooms,camera:cameraPath,clips:videoClips,captions:captions,captionStyle:captionStyle,audioTracks:audioTracks,audioSettings:audioSettings,keyboardStyle:keyboardStyle,cameraOffset:cameraOffset,annotations:annotations,markers:markers) }
    func recordEdit() {
        let now=Date()
        if now < restoringUntil { previousSnapshot=snapshot;refreshComposition();return }
        if let previous=previousSnapshot,previous != snapshot {
            if now.timeIntervalSince(lastEdit)>0.5 { undoStack.append(previous);if undoStack.count>80{undoStack.removeFirst()} }
            redoStack=[];lastEdit=now
        }
        previousSnapshot=snapshot;refreshComposition()
    }
    func restore(_ s:EditSnapshot) {
        restoringUntil=Date().addingTimeInterval(0.4)
        // Older snapshots have no camera offset; keep the current one when they point at the same camera file.
        let offset=s.camera == nil ? nil:(s.cameraOffset ?? (s.camera == cameraPath ? cameraOffset:nil))
        retakes=s.retakes ?? retakes.map { var copy=$0;copy.choice=nil;return copy };look=s.look;motion=s.motion;zooms=s.zooms;cameraPath=s.camera;cameraOffset=offset;videoClips=s.clips;captions=s.captions;captionStyle=s.captionStyle;audioTracks=s.audioTracks;audioSettings=s.audioSettings;keyboardStyle=s.keyboardStyle;annotations=s.annotations ?? [];markers=s.markers ?? []
        if !videoClips.contains(where:{$0.id==selectedClip}){selectedClip=videoClips.first?.id};if !zooms.contains(where:{$0.id==selectedZoom}){selectedZoom=zooms.first?.id};if !captions.contains(where:{$0.id==selectedCaption}){selectedCaption=captions.first?.id};if !audioTracks.contains(where:{$0.id==selectedAudioTrack}){selectedAudioTrack=audioTracks.first?.id};if !annotations.contains(where:{$0.id==selectedAnnotation}){selectedAnnotation=nil};if !markers.contains(where:{$0.id==selectedMarker}){selectedMarker=nil}
        synchronizeVideoSequence(refresh:false,trimItems:false)
        previousSnapshot=s;refreshComposition()
    }
    func undoEdit() { guard let last=undoStack.popLast() else{return};redoStack.append(snapshot);restore(last);flash("Undone") }
    func redoEdit() { guard let last=redoStack.popLast() else{return};undoStack.append(snapshot);restore(last);flash("Redone") }
}
