import SwiftUI

enum TimelineItemKind: String {
    case clip, zoom, caption, audio, annotation
}

/// A copied timeline item. It stays on the clipboard for the session, so it can also be pasted into another recording.
enum TimelineClipboardItem {
    case clip(VideoClip)
    case zoom(ZoomClip)
    case caption(CaptionCue)
    case audio(AudioTrackEdit)
    case annotation(Annotation)
    var name: String {
        switch self {
        case .annotation(let item): return item.kind
        case .clip: return "Clip"
        case .zoom: return "Zoom"
        case .caption: return "Caption"
        case .audio: return "Audio"
        }
    }
    /// Timeline time where the item ends; duplicates are placed here.
    var end: Double {
        switch self {
        case .clip(let clip): return clip.timelineStart+clip.duration
        case .zoom(let zoom): return zoom.end
        case .caption(let cue): return cue.end
        case .audio(let track): return track.timelineStart+track.duration
        case .annotation(let item): return item.end
        }
    }
}

@MainActor extension Studio {
    /// Selects an item and makes its track the target of Delete, Copy, Cut and Duplicate.
    func focusTimeline(_ kind:TimelineItemKind,id:UUID) {
        timelineFocus = kind
        switch kind {
        case .clip: selectedClip = id
        case .zoom: selectedZoom = id
        case .caption: selectedCaption = id
        case .audio: selectedAudioTrack = id
        case .annotation: selectedAnnotation = id
        }
    }
    private func selectedID(_ kind:TimelineItemKind)->UUID? {
        switch kind {
        case .clip: return selectedClip
        case .zoom: return selectedZoom
        case .caption: return selectedCaption
        case .audio: return selectedAudioTrack
        case .annotation: return selectedAnnotation
        }
    }
    private func timelineItem(_ kind:TimelineItemKind,id:UUID)->TimelineClipboardItem? {
        switch kind {
        case .clip: return videoClips.first { $0.id == id }.map { .clip($0) }
        case .zoom: return zooms.first { $0.id == id }.map { .zoom($0) }
        case .caption: return captions.first { $0.id == id }.map { .caption($0) }
        case .audio: return audioTracks.first { $0.id == id }.map { .audio($0) }
        case .annotation: return annotations.first { $0.id == id }.map { .annotation($0) }
        }
    }
    var focusedTimelineItem: TimelineClipboardItem? {
        selectedID(timelineFocus).flatMap { timelineItem(timelineFocus,id:$0) }
    }

    func copyTimelineItem(_ kind:TimelineItemKind,id:UUID) {
        guard let item = timelineItem(kind,id:id) else { return }
        focusTimeline(kind,id:id)
        timelineClipboard = item
    }
    func cutTimelineItem(_ kind:TimelineItemKind,id:UUID) {
        guard timelineItem(kind,id:id) != nil, !busy else { return }
        if kind == .clip && videoClips.count <= 1 { message = "At least one clip must remain in the timeline."; return }
        copyTimelineItem(kind,id:id)
        deleteTimelineItem(kind,id:id)
    }
    func deleteTimelineItem(_ kind:TimelineItemKind,id:UUID) {
        guard !busy, timelineItem(kind,id:id) != nil else { return }
        switch kind {
        case .clip:
            selectedClip = id; deleteSelectedClip()
        case .zoom:
            zooms.removeAll { $0.id == id }
            if selectedZoom == id { selectedZoom = nil }
        case .caption:
            selectedCaption = id; deleteSelectedCaption()
        case .audio:
            audioTracks.removeAll { $0.id == id }
            if selectedAudioTrack == id { selectedAudioTrack = audioTracks.first?.id }
        case .annotation:
            annotations.removeAll { $0.id == id }
            if selectedAnnotation == id { selectedAnnotation = nil }
        }
    }
    /// Places a copy right after the item without changing the clipboard.
    func duplicateTimelineItem(_ kind:TimelineItemKind,id:UUID) {
        guard let item = timelineItem(kind,id:id) else { return }
        if case .clip = item { focusTimeline(.clip,id:id); duplicateSelectedClip(); return }
        insertTimelineItem(item,at:item.end,movePlayhead:false)
    }
    /// Pastes the clipboard at the playhead and moves the playhead to the end of the pasted item, so repeated pastes line up.
    @discardableResult func pasteTimelineItem(at time:Double?=nil)->Bool {
        guard let item = timelineClipboard else { return false }
        return insertTimelineItem(item,at:time ?? position,movePlayhead:true)
    }
    func copyTimelineSelection() { if let id = selectedID(timelineFocus) { copyTimelineItem(timelineFocus,id:id) } }
    func cutTimelineSelection() { if let id = selectedID(timelineFocus) { cutTimelineItem(timelineFocus,id:id) } }
    func deleteTimelineSelection() { if let id = selectedID(timelineFocus) { deleteTimelineItem(timelineFocus,id:id) } }
    func duplicateTimelineSelection() { if let id = selectedID(timelineFocus) { duplicateTimelineItem(timelineFocus,id:id) } }

    @discardableResult func insertTimelineItem(_ item:TimelineClipboardItem,at requested:Double,movePlayhead:Bool)->Bool {
        guard !busy, source != nil, stillImage == nil, duration > 0 else { return false }
        let start = max(0,requested.isFinite ? requested : 0)
        switch item {
        case .clip(let original):
            guard let clip = normalizedVideoClips([VideoClip(sourceStart:original.sourceStart,sourceEnd:original.sourceEnd,timelineStart:start,speed:original.speed,source:original.source)],sourceDuration:sourceDuration,added:addedSources).first else {
                message = "This clip is outside the recording it plays."; return false
            }
            player.pause(); playing = false
            videoClips.append(clip); focusTimeline(.clip,id:clip.id)
            synchronizeVideoSequence()
            if movePlayhead { position = min(duration,clip.timelineStart+clip.duration); seek(position) }
        case .zoom(let original):
            guard start <= duration-0.1 else { message = "Move the playhead before the end of the timeline to paste."; return false }
            var zoom = original
            zoom.id = UUID(); zoom.start = start; zoom.end = min(duration,start+(original.end-original.start))
            zoom.transition = min(zoom.transition,(zoom.end-zoom.start)/2)
            zooms.append(zoom); focusTimeline(.zoom,id:zoom.id)
            if movePlayhead { position = zoom.end; seek(position) }
        case .caption(let original):
            guard start <= duration-0.04 else { message = "Move the playhead before the end of the timeline to paste."; return false }
            let shift = start-original.start
            var cue = original
            cue.id = UUID(); cue.start = start; cue.end = min(duration,original.end+shift)
            cue.words = original.words.compactMap { word in
                var copy = word; copy.id = UUID(); copy.start = word.start+shift; copy.end = min(cue.end,word.end+shift)
                return copy.start < cue.end && copy.end > copy.start ? copy : nil
            }
            if !original.words.isEmpty && cue.words.count < original.words.count {
                guard !cue.words.isEmpty else { message = "There is not enough room at the playhead for this caption."; return false }
                cue.text = cue.words.map(\.text).joined(separator:" ")
            }
            captions.append(cue); captions.sort { $0.start < $1.start }; focusTimeline(.caption,id:cue.id)
            if movePlayhead { position = cue.end; seek(position) }
        case .audio(let original):
            guard FileManager.default.fileExists(atPath:original.path) else { message = "The copied audio file is no longer available."; return false }
            guard start < duration-0.04 else { message = "Move the playhead before the end of the timeline to paste."; return false }
            var track = original
            track.id = UUID(); track.timelineStart = start
            audioTracks.append(track); focusTimeline(.audio,id:track.id)
            if movePlayhead { position = min(duration,start+track.duration); seek(position) }
        case .annotation(let original):
            guard start <= duration-0.1 else { message = "Move the playhead before the end of the timeline to paste."; return false }
            var item = original
            item.id = UUID(); item.start = start; item.end = min(duration,start+(original.end-original.start))
            annotations.append(item); focusTimeline(.annotation,id:item.id)
            if movePlayhead { position = item.end; seek(position) }
        }
        return true
    }
}

/// Copy, cut, paste, duplicate and delete for one timeline item, shared by every track's context menu.
struct TimelineItemMenu: View {
    @ObservedObject var studio: Studio
    let kind: TimelineItemKind
    let id: UUID
    var body: some View {
        Button("Copy") { studio.copyTimelineItem(kind,id:id) }
        Button("Cut") { studio.cutTimelineItem(kind,id:id) }
        Button(studio.timelineClipboard.map { "Paste \($0.name) at Playhead" } ?? "Paste at Playhead") { studio.pasteTimelineItem() }
            .disabled(studio.timelineClipboard == nil)
        Button("Duplicate") { studio.duplicateTimelineItem(kind,id:id) }
        Divider()
        Button("Delete",role:.destructive) { studio.deleteTimelineItem(kind,id:id) }
    }
}
