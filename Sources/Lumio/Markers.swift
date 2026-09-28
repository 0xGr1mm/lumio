import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A point on the timeline with a name: a place to come back to, and a chapter in the finished video.
struct TimelineMarker: Codable, Equatable, Identifiable {
    static let colors: [UInt32] = [0xFF3B30,0xFFD60A,0x34C759,0x0A84FF,0xBF5AF2,0xFFFFFF]
    var id = UUID()
    var time: Double
    var name: String = "Marker"
    var color = RGB(0xFFD60A)
}

func normalizedMarkers(_ markers:[TimelineMarker],duration:Double,limit:Int=500)->[TimelineMarker] {
    guard duration.isFinite, duration > 0 else { return [] }
    var ids = Set<UUID>()
    return markers.prefix(limit).compactMap { original in
        var marker = original
        guard marker.time.isFinite else { return nil }
        marker.time = max(0,min(duration,marker.time))
        marker.name = String(marker.name.trimmingCharacters(in:.whitespacesAndNewlines).prefix(80))
        if marker.name.isEmpty { marker.name = "Marker" }
        marker.color = marker.color.normalized()
        if !ids.insert(marker.id).inserted { marker.id = UUID() }
        return marker
    }.sorted { $0.time < $1.time }
}

/// Chapters in the format YouTube, Spotify and podcast players read: one `0:00 Name` line each.
/// The first chapter always starts at zero, because a list that starts later is rejected.
func chapterList(_ markers:[TimelineMarker],duration:Double)->String {
    let sorted = normalizedMarkers(markers,duration:duration)
    guard !sorted.isEmpty else { return "" }
    var lines: [String] = []
    if sorted.first!.time > 0.5 { lines.append("0:00 Start") }
    for marker in sorted {
        let total = Int(marker.time.rounded(.down))
        let stamp = total >= 3600 ? String(format:"%d:%02d:%02d",total/3600,(total/60)%60,total%60) : String(format:"%d:%02d",total/60,total%60)
        lines.append("\(stamp) \(marker.name)")
    }
    return lines.joined(separator:"\n")+"\n"
}

/// Keeps markers on the right moment when ranges are removed or a clip's speed changes.
/// A marker inside a removed range lands on the cut, so it never points past the end.
func remappedMarkers(_ markers:[TimelineMarker],_ remap:(Double)->Double)->[TimelineMarker] {
    var seen=Set<String>()
    return markers.compactMap { marker in
        var copy=marker;copy.time=remap(marker.time)
        // Two markers that collapse onto the same moment would be one chapter twice.
        let key=String(format:"%.3f",copy.time)
        return seen.insert(key).inserted ? copy:nil
    }.sorted { $0.time<$1.time }
}

@MainActor extension Studio {
    /// Adds a marker at the playhead, or selects the one already there.
    @discardableResult func addMarker(at time:Double?=nil,name:String?=nil)->UUID? {
        guard duration > 0 else { return nil }
        let spot = max(0,min(duration,time ?? position))
        if let existing = markers.first(where:{ abs($0.time-spot) < 0.001 }) { selectedMarker = existing.id; return existing.id }
        let marker = TimelineMarker(time:spot,name:name ?? "Marker \(markers.count+1)")
        markers.append(marker); markers.sort { $0.time < $1.time }
        selectedMarker = marker.id
        return marker.id
    }
    func moveMarker(_ id:UUID,to time:Double) {
        update(\.markers,id:id) { $0.time = max(0,min(duration,time)) }
        markers.sort { $0.time < $1.time }
    }
    func deleteMarker(_ id:UUID) {
        markers.removeAll { $0.id == id }
        if selectedMarker == id { selectedMarker = nil }
    }
    /// Jumps to the marker before or after the playhead.
    func goToMarker(forward:Bool) {
        let target = forward ? markers.first(where:{ $0.time > position+0.01 }) : markers.last(where:{ $0.time < position-0.01 })
        guard let target else { return }
        selectedMarker = target.id
        position = target.time; seek(position)
    }
    func exportChapters() {
        let text = chapterList(markers,duration:duration)
        guard !text.isEmpty else { message = "Add a marker first; markers become the chapters."; return }
        let picker = NSSavePanel(); picker.allowedContentTypes = [.plainText]
        picker.nameFieldStringValue = (source?.deletingPathExtension().lastPathComponent ?? "Lumio")+"-chapters.txt"
        guard picker.runModal() == .OK, let url = picker.url else { return }
        do { try text.write(to:url,atomically:true,encoding:.utf8) } catch { message = error.localizedDescription }
    }
}

struct MarkerInspector: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            HStack {
                Button("Add at Playhead") { studio.addMarker() }.disabled(studio.duration <= 0)
                Button("Previous") { studio.goToMarker(forward:false) }.disabled(studio.markers.isEmpty)
                Button("Next") { studio.goToMarker(forward:true) }.disabled(studio.markers.isEmpty)
            }
            Text("Markers are places to come back to. They also become the chapter list for YouTube and podcast players.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if studio.markers.isEmpty {
                Text("No markers yet. M adds one at the playhead.").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(studio.markers) { marker in
                    let id = marker.id
                    VStack(alignment:.leading,spacing:6) {
                        HStack(spacing:8) {
                            Circle().fill(marker.color.color).frame(width:10,height:10)
                            TextField("Name",text:studio.binding(\.markers,id:id,\.name,fallback:marker.name)).textFieldStyle(.roundedBorder)
                            Button { studio.position=marker.time;studio.seek(marker.time);studio.selectedMarker=id } label:{Image(systemName:"play.fill")}.help("Go to this marker")
                            Button(role:.destructive) { studio.deleteMarker(id) } label:{Image(systemName:"trash")}.help("Delete this marker")
                        }
                        HStack(spacing:6) {
                            Text(stamp(marker.time)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            ForEach(TimelineMarker.colors,id:\.self) { hex in
                                Button { studio.update(\.markers,id:id) { $0.color = RGB(hex) } } label: {
                                    Circle().fill(RGB(hex).color).frame(width:13,height:13).padding(2).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Use this color")
                            }
                        }
                    }.padding(9).background(studio.selectedMarker == id ? accent.opacity(0.12):Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                }
                Button("Export Chapters…") { studio.exportChapters() }
            }
        }
    }
    func stamp(_ seconds:Double)->String {
        let total=Int(max(0,seconds))
        return total>=3600 ? String(format:"%d:%02d:%02d",total/3600,(total/60)%60,total%60):String(format:"%d:%02d",total/60,total%60)
    }
}
