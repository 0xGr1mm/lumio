import AVFoundation
import SwiftUI

/// One step of the quick edit. The panel shows these as they finish, so a long pass tells the user
/// what it actually did instead of only spinning.
struct QuickEditStep: Identifiable, Equatable {
    var id = UUID()
    var label: String
    var detail = ""
    var state = "waiting"   // waiting · running · done · skipped
    var symbol: String
}

@MainActor extension Studio {
    /// The whole first pass over a fresh recording: dead air out, captions in, zooms on the clicks,
    /// a look at what should not be published, and a gentle fade at both ends. Every part of it is undoable.
    func quickEdit() async {
        guard source != nil, stillImage == nil, duration > 0, !quickRunning, !busy else { return }
        quickRunning = true
        quickSteps = [
            QuickEditStep(label:"Cutting dead air",symbol:"scissors"),
            QuickEditStep(label:"Writing captions",symbol:"captions.bubble"),
            QuickEditStep(label:"Zooming where you clicked",symbol:"viewfinder"),
            QuickEditStep(label:"Checking for private details",symbol:"lock.shield"),
            QuickEditStep(label:"Fading in and out",symbol:"circle.lefthalf.filled")
        ]
        defer { quickRunning = false }

        func run(_ index:Int,_ work:() async->String) async {
            guard quickSteps.indices.contains(index) else { return }
            quickSteps[index].state = "running"
            let detail = await work()
            quickSteps[index].detail = detail
            quickSteps[index].state = detail.isEmpty ? "skipped" : "done"
        }

        await run(0) { [self] in
            let before = duration
            await scanSilence()
            let silence = cleanupCandidates.filter { $0.kind == "Silence" }
            guard !silence.isEmpty else { return "" }
            guard rippleDelete(silence.map { VideoCut(start:$0.start,end:$0.end) }) else { return "" }
            cleanupCandidates = []
            let saved = max(0,before-duration)
            return "\(silence.count) gaps out · \(String(format:"%.1f",saved)) s shorter"
        }
        await run(1) { [self] in
            guard captions.isEmpty else { return "\(captions.count) already there" }
            await generateCaptions(localeIdentifier:"Auto")
            captionStyle.enabled = !captions.isEmpty
            return captions.isEmpty ? "" : "\(captions.count) lines"
        }
        await run(2) { [self] in
            motion.autoZoom = true
            motion.clickHighlight = true
            let zooms = autoZoomClips(samples:timelinePointerSamples,settings:motion,duration:duration,typing:keyboardSamples.filter { $0.typing ?? false }.map(\.time))
            refreshComposition()
            return zooms.isEmpty ? "no clicks found · click highlight on" : "\(zooms.count) zooms · click highlight on"
        }
        await run(3) { [self] in
            await scanForSensitiveText()
            guard !privacyFinds.isEmpty else { return "" }
            // A recovery phrase or a private key is never meant to be in a video, so those are covered right away.
            // An address or a balance might be the point of the video, so those are only reported.
            let critical = privacyFinds.filter(\.strong)
            for find in critical { hideFind(find.id) }
            let rest = privacyFinds.count-critical.count
            if !critical.isEmpty && rest > 0 { return "\(critical.count) covered · \(rest) to review in Privacy" }
            if !critical.isEmpty { return "\(critical.count) covered" }
            return "\(rest) to review in Privacy"
        }
        await run(4) { [self] in
            guard look.resolvedFadeIn <= 0, look.resolvedFadeOut <= 0, duration > 1.5 else { return "" }
            look.fadeIn = 0.4; look.fadeOut = 0.5
            refreshComposition()
            return "0.4 s in · 0.5 s out"
        }
        quickEditFinished = Date()
    }
}

struct QuickPanel: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("One pass over the recording: dead air out, captions in, zooms on your clicks, a check for anything private. Undo takes any of it back.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button { Task { await studio.quickEdit() } } label: {
                HStack(spacing:9) {
                    Image(systemName:studio.quickRunning ? "hourglass":"wand.and.rays").font(.system(size:15))
                    Text(studio.quickRunning ? "Working…":"Clean This Up").font(.system(size:13,weight:.semibold))
                    Spacer(minLength:0)
                }.frame(maxWidth:.infinity).padding(.vertical,4).contentShape(Rectangle())
            }.buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(studio.source == nil || studio.stillImage != nil || studio.duration <= 0 || studio.quickRunning || studio.busy)
            if !studio.quickSteps.isEmpty {
                VStack(alignment:.leading,spacing:8) {
                    ForEach(studio.quickSteps) { step in
                        HStack(alignment:.top,spacing:9) {
                            Group {
                                switch step.state {
                                case "done": Image(systemName:"checkmark.circle.fill").foregroundStyle(accent)
                                case "running": ProgressView().controlSize(.small).scaleEffect(0.7).frame(width:15,height:15)
                                case "skipped": Image(systemName:"minus.circle").foregroundStyle(.secondary.opacity(0.5))
                                default: Image(systemName:step.symbol).foregroundStyle(.secondary.opacity(0.45))
                                }
                            }.frame(width:16)
                            VStack(alignment:.leading,spacing:1) {
                                Text(step.label).font(.system(size:12,weight:step.state == "running" ? .semibold: .regular))
                                    .foregroundStyle(step.state == "waiting" ? .secondary: .primary)
                                if !step.detail.isEmpty { Text(step.detail).font(.system(size:10)).foregroundStyle(.secondary) }
                                else if step.state == "skipped" { Text("nothing to do").font(.system(size:10)).foregroundStyle(.secondary) }
                            }
                            Spacer(minLength:0)
                        }
                    }
                }.padding(11).frame(maxWidth:.infinity,alignment:.leading)
                    .background(Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:9))
                if studio.quickEditFinished != nil && !studio.quickRunning {
                    HStack(spacing:8) {
                        Button { studio.undoEdit() } label: { Label("Undo Last Step",systemImage:"arrow.uturn.backward") }.controlSize(.small)
                        Spacer()
                    }
                }
            }
            Divider()
            Text("Made for").font(.system(size:12,weight:.semibold))
            VStack(spacing:6) {
                ForEach(exportPresets) { preset in
                    Button { studio.applyExportPreset(preset) } label: {
                        HStack(spacing:8) {
                            Image(systemName:presetSymbol(preset.id)).frame(width:16)
                            VStack(alignment:.leading,spacing:1) {
                                Text(preset.id).font(.system(size:11,weight:.medium))
                                Text(preset.detail).font(.system(size:9)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength:0)
                        }.padding(.vertical,6).padding(.horizontal,8).frame(maxWidth:.infinity).contentShape(Rectangle())
                            .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).help("Canvas, file and frame rate for \(preset.id)")
                }
            }.disabled(studio.source == nil)
            Button { studio.startExport() } label: { Label("Export \(studio.stillImage == nil ? studio.exportSettings.resolvedFormat:"PNG")…",systemImage:"square.and.arrow.up") }
                .disabled(studio.source == nil || studio.busy)
        }
    }
    func presetSymbol(_ name:String)->String {
        if name.hasPrefix("YouTube") { return "play.rectangle.fill" }
        if name.hasPrefix("TikTok") { return "iphone" }
        if name.hasPrefix("Instagram") { return "square.fill" }
        if name.hasPrefix("Looping") { return "arrow.triangle.2.circlepath" }
        return "rectangle.on.rectangle"
    }
}
