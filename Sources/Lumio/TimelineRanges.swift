import AppKit
import SwiftUI

enum TimelineEdge { case start, end, move }
struct TimelineRange: Equatable {
    var start: Double
    var end: Double
    var length: Double { end-start }
}

/// Applies a drag to a timeline item: resizes one edge or moves the whole item, keeps it within
/// [lower, upper] and at least minLength long, and snaps the dragged edge to the nearest target within threshold.
/// Returns the snap target that was used so the caller can give feedback when it changes.
func draggedTimelineRange(_ base:TimelineRange,edge:TimelineEdge,delta:Double,lower:Double,upper:Double,minLength:Double,snapTargets:[Double],threshold:Double)->(range:TimelineRange,snapped:Double?) {
    // An item that already overlaps a neighbour may still be dragged back instead of jumping.
    let lower=min(lower,base.start),upper=max(upper,base.end)
    func snap(_ time:Double)->Double? { snapTargets.filter { abs($0-time)<=threshold }.min { abs($0-time)<abs($1-time) } }
    func kept(_ hit:Double?,_ value:Double)->Double? { hit.flatMap { abs($0-value)<1e-9 ? $0:nil } }
    switch edge {
    case .start:
        let hit=snap(base.start+delta)
        let start=max(lower,min(base.end-minLength,hit ?? base.start+delta))
        return (TimelineRange(start:start,end:base.end),kept(hit,start))
    case .end:
        let hit=snap(base.end+delta)
        let end=min(upper,max(base.start+minLength,hit ?? base.end+delta))
        return (TimelineRange(start:base.start,end:end),kept(hit,end))
    case .move:
        let length=base.length
        var start=base.start+delta,hit:Double?
        let headHit=snap(start),tailHit=snap(start+length)
        if let headHit,tailHit.map({ abs(headHit-start)<=abs($0-start-length) }) ?? true { start=headHit;hit=headHit }
        else if let tailHit { start=tailHit-length;hit=tailHit }
        start=max(lower,min(upper-length,start))
        return (TimelineRange(start:start,end:start+length),kept(hit,start) ?? kept(hit,start+length))
    }
}

/// Snaps both ends of a drawn range to nearby targets, keeping it at least minLength long.
func snappedTimelineEdges(_ range:TimelineRange,snapTargets:[Double],threshold:Double,minLength:Double)->TimelineRange {
    func snap(_ time:Double)->Double { snapTargets.filter { abs($0-time)<=threshold }.min { abs($0-time)<abs($1-time) } ?? time }
    let start=snap(range.start),end=snap(range.end)
    return end-start>=minLength ? TimelineRange(start:start,end:end):range
}

/// The free space around an item on its track: the end of the closest item before it and the start of the closest one after it.
func timelineNeighbourBounds(_ others:[TimelineRange],around base:TimelineRange,duration:Double)->(lower:Double,upper:Double) {
    let lower=others.filter { $0.end<=base.start+1e-6 }.map(\.end).max() ?? 0
    let upper=others.filter { $0.start>=base.end-1e-6 }.map(\.start).min() ?? duration
    return (lower,max(lower,upper))
}

@MainActor extension Studio {
    /// Changes one item of a list by id. Inspectors never hold an index, which a deletion would invalidate.
    func update<Item:Identifiable>(_ list:ReferenceWritableKeyPath<Studio,[Item]>,id:Item.ID,_ change:(inout Item)->Void) {
        guard let index=self[keyPath:list].firstIndex(where:{ $0.id == id }) else { return }
        change(&self[keyPath:list][index])
    }
    /// A binding to one field of an item held by id, with an optional rule that keeps the written value valid.
    func binding<Item:Identifiable,Value>(_ list:ReferenceWritableKeyPath<Studio,[Item]>,id:Item.ID,_ field:WritableKeyPath<Item,Value>,fallback:Value,clamp:((Value)->Value)?=nil)->Binding<Value> {
        Binding(get:{ [weak self] in self?[keyPath:list].first { $0.id == id }?[keyPath:field] ?? fallback },
                set:{ [weak self] value in self?.update(list,id:id) { $0[keyPath:field]=clamp?(value) ?? value } })
    }
    /// Edges a dragged item clicks onto: timeline ends, playhead, clip boundaries and other zooms and captions.
    func timelineSnapTargets(excluding id:UUID?)->[Double] {
        var targets=[0,duration,position]
        for clip in videoClips { targets+=[clip.timelineStart,clip.timelineStart+clip.duration] }
        for zoom in zooms where zoom.id != id { targets+=[zoom.start,zoom.end] }
        for cue in captions where cue.id != id { targets+=[cue.start,cue.end] }
        return targets
    }
    func setZoomRange(_ id:UUID,to range:TimelineRange) {
        guard let i=zooms.firstIndex(where:{ $0.id == id }) else { return }
        zooms[i].start=max(0,range.start);zooms[i].end=min(duration,max(zooms[i].start+0.1,range.end))
        zooms[i].transition=min(zooms[i].transition,(zooms[i].end-zooms[i].start)/2)
    }
    /// Moves or resizes a caption; its word timings stretch with it so highlighting stays on the spoken word.
    func setCaptionRange(_ id:UUID,to range:TimelineRange) {
        guard let i=captions.firstIndex(where:{ $0.id == id }) else { return }
        let old=captions[i],start=max(0,range.start),end=min(duration,max(start+0.04,range.end))
        let factor=old.end-old.start>0 ? (end-start)/(old.end-old.start):1
        func map(_ time:Double)->Double { min(end,max(start,start+(time-old.start)*factor)) }
        captions[i].start=start;captions[i].end=end
        captions[i].words=old.words.map { var word=$0;word.start=map($0.start);word.end=map($0.end);return word }
        captions.sort { $0.start<$1.start }
    }
    func moveAudioTrack(_ id:UUID,toTimelineStart start:Double) {
        guard let i=audioTracks.firstIndex(where:{ $0.id == id }) else { return }
        audioTracks[i].timelineStart=max(0,min(max(0,duration-0.04),start))
    }
}

/// A timeline item that can be moved by its body and resized by its edges.
/// The drag is measured in window coordinates so the moving block never feeds back into its own gesture,
/// and it is shown from local state until the mouse is released, so only this block redraws while dragging.
struct TimelineRangeBlock<Label:View>:View {
    let range:TimelineRange
    let width:Double
    let duration:Double
    var height:Double=30
    var resizable=true
    var minLength=0.1
    var cornerRadius:Double=7
    var fill:Color
    var selected=false
    /// Automatic zooms become editable only when a drag is committed, so they are not selected when it begins.
    var selectOnDrag=true
    /// Free space for the item, read once when a drag begins.
    var bounds:()->(lower:Double,upper:Double)
    var snapTargets:()->[Double]
    var onSelect:()->Void
    var onCommit:(TimelineRange)->Void
    @ViewBuilder var label:(TimelineRange,Bool)->Label

    private struct Session { var edge:TimelineEdge;var base:TimelineRange;var lower:Double;var upper:Double;var targets:[Double];var snapped:Double? }
    @State private var session:Session?
    @State private var live:TimelineRange?

    var pointsPerSecond:Double { width/max(0.1,duration) }
    var body:some View {
        let shown=live ?? range
        let blockWidth=max(28,pointsPerSecond*shown.length)
        RoundedRectangle(cornerRadius:cornerRadius).fill(fill)
            .overlay(RoundedRectangle(cornerRadius:cornerRadius).stroke(selected || live != nil ? Color.white.opacity(0.85):.clear,lineWidth:1))
            .overlay(label(shown,live != nil).padding(.horizontal,resizable ? 9:4))
            .overlay(alignment:.leading) { if resizable { edgeHandle(.start,blockWidth:blockWidth) } }
            .overlay(alignment:.trailing) { if resizable { edgeHandle(.end,blockWidth:blockWidth) } }
            .frame(width:blockWidth,height:height)
            .contentShape(Rectangle())
            .pointerStyle(session?.edge == .move ? .grabActive:.grabIdle)
            .gesture(drag(.move))
            .onTapGesture(perform:onSelect)
            .offset(x:pointsPerSecond*shown.start)
            .zIndex(live != nil ? 20:selected ? 10:0)
    }
    func edgeHandle(_ edge:TimelineEdge,blockWidth:Double)->some View {
        Color.clear.frame(width:min(10,blockWidth/3)).contentShape(Rectangle())
            .overlay(Capsule().fill(.white.opacity(session?.edge == edge ? 1:0.7)).frame(width:3,height:height*0.55))
            .pointerStyle(.frameResize(position:edge == .start ? .leading:.trailing,directions:[.inward,.outward]))
            .highPriorityGesture(drag(edge))
            .help(edge == .start ? "Drag to change where it starts · hold ⌘ to turn off snapping":"Drag to change where it ends · hold ⌘ to turn off snapping")
    }
    func drag(_ edge:TimelineEdge)->some Gesture {
        DragGesture(minimumDistance:1,coordinateSpace:.global).onChanged { value in
            if session == nil {
                let free=bounds()
                session=Session(edge:edge,base:range,lower:free.lower,upper:free.upper,targets:snapTargets())
                if selectOnDrag { onSelect() }
            }
            guard var current=session else { return }
            let snapping = !NSEvent.modifierFlags.contains(.command)
            let result=draggedTimelineRange(current.base,edge:edge,delta:value.translation.width/pointsPerSecond,lower:current.lower,upper:current.upper,minLength:minLength,
                                            snapTargets:snapping ? current.targets:[],threshold:8/pointsPerSecond)
            if let hit=result.snapped,hit != current.snapped { NSHapticFeedbackManager.defaultPerformer.perform(.alignment,performanceTime:.now) }
            current.snapped=result.snapped;session=current;live=result.range
        }.onEnded { _ in
            if let live,live != session?.base { onCommit(live) }
            live=nil;session=nil
        }
    }
}
