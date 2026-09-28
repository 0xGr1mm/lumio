import SwiftUI

struct TranscriptToken: Identifiable, Equatable {
    var id: String
    var text: String
    var start: Double
    var end: Double
}

func transcriptTokens(_ cues:[CaptionCue])->[TranscriptToken] {
    cues.sorted { $0.start < $1.start }.flatMap { cue -> [TranscriptToken] in
        if cue.words.isEmpty { return [TranscriptToken(id:cue.id.uuidString,text:cue.text,start:cue.start,end:cue.end)] }
        return cue.words.map { TranscriptToken(id:$0.id.uuidString,text:$0.text,start:$0.start,end:$0.end) }
    }
}

struct FlowLayout: Layout {
    var spacing: CGFloat = 4
    func sizeThatFits(proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) -> CGSize {
        let width = proposal.width ?? 280
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row,size.height)
        }
        return CGSize(width:width,height:y + row)
    }
    func placeSubviews(in bounds:CGRect,proposal:ProposedViewSize,subviews:Subviews,cache:inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at:CGPoint(x:x,y:y),proposal:ProposedViewSize(size))
            x += size.width + spacing; row = max(row,size.height)
        }
    }
}

/// Word list that only re-renders when the transcript or selection changes, not on every playhead tick.
struct TranscriptWords: View, Equatable {
    var tokens: [TranscriptToken]
    var selected: Set<String>
    var tap: (Int) -> Void
    static func == (a:TranscriptWords,b:TranscriptWords) -> Bool { a.tokens == b.tokens && a.selected == b.selected }
    var body: some View {
        FlowLayout(spacing:3) {
            ForEach(Array(tokens.enumerated()),id:\.element.id) { index, token in
                Text(token.text).font(.system(size:12))
                    .padding(.horizontal,4).padding(.vertical,2)
                    .background(selected.contains(token.id) ? Color.red.opacity(0.45) : Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:4))
                    .contentShape(Rectangle())
                    .onTapGesture { tap(index) }
            }
        }
    }
}

struct TranscriptPanel: View {
    @ObservedObject var studio: Studio
    @State private var selected: Set<String> = []
    @State private var anchor: Int?
    var body: some View {
        let tokens = transcriptTokens(studio.captions)
        VStack(alignment:.leading,spacing:14) {
            Text("Cut the video by editing its words. Click a word to jump there; Shift-click selects a range and ⌘-click adds words.").font(.caption).foregroundStyle(.secondary)
            if tokens.isEmpty {
                Text("Generate captions in the Captions panel first. The transcript appears here.").font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    Button { remove(tokens) } label: { Label("Remove \(selected.count) Words",systemImage:"scissors") }.disabled(selected.isEmpty)
                    Button("Clear") { selected = []; anchor = nil }.disabled(selected.isEmpty)
                }
                TranscriptWords(tokens:tokens,selected:selected) { index in select(index,tokens:tokens) }.equatable()
                Text("Removing words closes the gap across video, zooms, captions and added audio. Undo restores it.").font(.caption2).foregroundStyle(.secondary)
            }
        }.font(.system(size:12))
        .onChange(of:studio.captions) { selected = selected.intersection(Set(transcriptTokens(studio.captions).map(\.id))) }
    }
    private func select(_ index:Int,tokens:[TranscriptToken]) {
        guard tokens.indices.contains(index) else { return }
        let token = tokens[index], flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor, tokens.indices.contains(anchor) {
            selected = Set(tokens[min(anchor,index)...max(anchor,index)].map(\.id))
        } else if flags.contains(.command) {
            if selected.contains(token.id) { selected.remove(token.id) } else { selected.insert(token.id) }
            anchor = index
        } else {
            selected = [token.id]; anchor = index
            studio.player.pause(); studio.playing = false; studio.position = token.start; studio.seek(token.start)
        }
    }
    private func remove(_ tokens:[TranscriptToken]) {
        let cuts = tokens.filter { selected.contains($0.id) }.map { VideoCut(start:max(0,$0.start-0.02),end:$0.end+0.02) }
        if studio.rippleDelete(cuts) { selected = []; anchor = nil }
    }
}
