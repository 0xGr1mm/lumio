import AppKit
import AVFoundation
import Speech
import SwiftUI

struct CaptionWord: Codable, Equatable, Identifiable {
    var id = UUID()
    var text: String
    var start: Double
    var end: Double
}

struct CaptionCue: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double
    var end: Double
    var text: String
    var words: [CaptionWord] = []
}

struct CaptionStyle: Codable, Equatable {
    var enabled = true
    var preset = "Bold"
    var fontName = "Avenir Next Condensed"
    var fontSize = 64.0
    var textColor = RGB(0xFFFFFF)
    var highlightColor = RGB(0xD4FF63)
    var backgroundColor = RGB(0x111111)
    var backgroundOpacity = 0.0
    var strokeColor = RGB(0x000000)
    var strokeWidth = 7.0
    var position = "Bottom"
    var verticalOffset = 0.0
    var uppercase = false
    var maxWords = 5
    var animation = "Pop"
    func normalized()->CaptionStyle {
        var value=self
        if !["Bold","Karaoke","Bubble","Neon","Minimal"].contains(value.preset){value.preset="Bold"}
        if !["Top","Center","Bottom"].contains(value.position){value.position="Bottom"}
        if !["None","Pop","Bounce","Fade","Slide"].contains(value.animation){value.animation="Pop"}
        value.fontName=String(value.fontName.prefix(100));if value.fontName.isEmpty{value.fontName="Avenir Next Condensed"}
        value.textColor=value.textColor.normalized();value.highlightColor=value.highlightColor.normalized();value.backgroundColor=value.backgroundColor.normalized();value.strokeColor=value.strokeColor.normalized()
        value.fontSize=max(28,min(120,value.fontSize.isFinite ? value.fontSize:64))
        value.backgroundOpacity=max(0,min(1,value.backgroundOpacity.isFinite ? value.backgroundOpacity:0))
        value.strokeWidth=max(0,min(16,value.strokeWidth.isFinite ? value.strokeWidth:7))
        value.verticalOffset=max(-300,min(300,value.verticalOffset.isFinite ? value.verticalOffset:0))
        value.maxWords=max(1,min(10,value.maxWords))
        return value
    }
}

func normalizedCaptionCues(_ cues:[CaptionCue],duration:Double,limit:Int=10_000)->[CaptionCue] {
    guard duration.isFinite,duration>0 else{return []}
    var result:[CaptionCue]=[],ids=Set<UUID>()
    for original in cues.prefix(limit) {
        guard original.start.isFinite,original.end.isFinite else{continue}
        var value=original
        value.start=max(0,min(duration,value.start));value.end=max(0,min(duration,value.end))
        value.text=String(value.text.prefix(2_000)).trimmingCharacters(in:.whitespacesAndNewlines)
        guard value.end-value.start>=0.04,!value.text.isEmpty else{continue}
        if ids.contains(value.id){value.id=UUID()};ids.insert(value.id)
        value.words=value.words.prefix(250).compactMap { word in
            guard word.start.isFinite,word.end.isFinite else{return nil}
            var copy=word;copy.text=String(copy.text.prefix(200)).trimmingCharacters(in:.whitespacesAndNewlines)
            copy.start=max(value.start,min(value.end,copy.start));copy.end=max(value.start,min(value.end,copy.end))
            return copy.end>copy.start && !copy.text.isEmpty ? copy:nil
        }
        result.append(value)
    }
    return result.sorted{$0.start<$1.start}
}

struct CaptionToken: Equatable {
    var text: String
    var start: Double
    var duration: Double
}

func makeCaptionCues(tokens: [CaptionToken], maxWords: Int) -> [CaptionCue] {
    guard !tokens.isEmpty else { return [] }
    var cues: [CaptionCue] = []
    var words: [CaptionWord] = []
    func flush() {
        guard let first = words.first, let last = words.last else { return }
        let text = words.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: " ,", with: ",")
            .replacingOccurrences(of: " .", with: ".")
            .replacingOccurrences(of: " !", with: "!")
            .replacingOccurrences(of: " ?", with: "?")
        cues.append(CaptionCue(start: first.start, end: max(last.end, first.start + 0.25), text: text, words: words))
        words = []
    }
    for token in tokens where !token.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let clean = token.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let gap = token.start - (words.last?.end ?? token.start)
        if !words.isEmpty && (words.count >= max(1, maxWords) || gap > 0.65 || words.last?.text.last.map(".!?".contains) == true) { flush() }
        words.append(CaptionWord(text: clean, start: token.start, end: token.start + max(0.08, token.duration)))
    }
    flush()
    return cues
}

/// Splits a recognized phrase into words and spreads its time range across them by character length.
func splitCaptionToken(_ text:String,start:Double,duration:Double)->[CaptionToken] {
    let words=text.split(whereSeparator:{$0.isWhitespace}).map(String.init)
    guard words.count>1 else { return words.map { CaptionToken(text:$0,start:start,duration:duration) } }
    let total=Double(max(1,words.reduce(0){$0+$1.count}))
    var cursor=start
    return words.map { word in
        let length=duration*Double(word.count)/total
        defer { cursor+=length }
        return CaptionToken(text:word,start:cursor,duration:length)
    }
}

private final class SpeechRecognitionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    var task: SFSpeechRecognitionTask?
    func claimCompletion() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !completed else { return false }
        completed = true
        return true
    }
}

/// On-device, long-form transcription (macOS 26). Returns nil when the language is not supported so the caller can fall back.
@available(macOS 26.0, *)
func transcribeWithSpeechAnalyzer(url:URL,locale requested:Locale?) async throws -> [CaptionToken]? {
    guard SpeechTranscriber.isAvailable, let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested ?? Locale.current) else { return nil }
    let transcriber = SpeechTranscriber(locale:locale,transcriptionOptions:[],reportingOptions:[],attributeOptions:[.audioTimeRange])
    if let request = try await AssetInventory.assetInstallationRequest(supporting:[transcriber]) { try await request.downloadAndInstall() }
    let collector = Task { () throws -> [CaptionToken] in
        var tokens:[CaptionToken] = []
        for try await result in transcriber.results {
            for run in result.text.runs {
                guard let range = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self], range.start.seconds.isFinite, range.duration.seconds.isFinite else { continue }
                let text = String(result.text[run.range].characters)
                tokens.append(contentsOf:splitCaptionToken(text,start:range.start.seconds,duration:range.duration.seconds))
            }
        }
        return tokens
    }
    do {
        let file = try AVAudioFile(forReading:url)
        let analyzer = try await SpeechAnalyzer(inputAudioFile:file,modules:[transcriber],finishAfterFile:true)
        let tokens = try await collector.value
        withExtendedLifetime(analyzer) {}
        return tokens.sorted { $0.start < $1.start }
    } catch {
        collector.cancel()
        throw error
    }
}

private func recognizeSpeech(_ recognizer:SFSpeechRecognizer,url:URL,onDevice:Bool) async throws -> SFSpeechRecognitionResult {
    let request = SFSpeechURLRecognitionRequest(url:url)
    request.shouldReportPartialResults = false
    request.addsPunctuation = true
    if onDevice { request.requiresOnDeviceRecognition = true }
    return try await withCheckedThrowingContinuation { continuation in
        let box = SpeechRecognitionBox()
        box.task = recognizer.recognitionTask(with:request) { result, error in
            if let error, box.claimCompletion() { continuation.resume(throwing:error); return }
            if let result, result.isFinal, box.claimCompletion() { continuation.resume(returning:result) }
        }
    }
}

private func exportAudioSlice(_ url:URL,start:Double,length:Double) async throws -> URL {
    guard let exporter = AVAssetExportSession(asset:AVURLAsset(url:url),presetName:AVAssetExportPresetAppleM4A) else {
        throw NSError(domain:"Lumio",code:30,userInfo:[NSLocalizedDescriptionKey:"The audio could not be split for transcription."])
    }
    exporter.timeRange = CMTimeRange(start:CMTime(seconds:start,preferredTimescale:600),duration:CMTime(seconds:length,preferredTimescale:600))
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("Lumio-slice-\(UUID().uuidString).m4a")
    try await exporter.export(to:output,as:.m4a)
    return output
}

/// Server recognition stops after about a minute of audio, so long recordings are transcribed in chunks with their offsets restored.
func transcribeWithSpeechRecognizer(url:URL,duration:Double,locale:Locale?) async throws -> [CaptionToken] {
    let authorization = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) } }
    guard authorization == .authorized else { throw NSError(domain:"Lumio",code:31,userInfo:[NSLocalizedDescriptionKey:"Speech Recognition permission is required to generate captions."]) }
    guard let recognizer = locale.map(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer(), recognizer.isAvailable else {
        throw NSError(domain:"Lumio",code:32,userInfo:[NSLocalizedDescriptionKey:"Speech Recognition is not available for the selected language."])
    }
    let onDevice = recognizer.supportsOnDeviceRecognition
    let chunk = onDevice ? max(duration,1) : 50
    var tokens:[CaptionToken] = []
    var start = 0.0
    while start < duration-0.05 {
        let length = min(chunk,duration-start)
        let whole = start == 0 && length >= duration-0.05
        let piece = whole ? url : try await exportAudioSlice(url,start:start,length:length)
        do {
            let result = try await recognizeSpeech(recognizer,url:piece,onDevice:onDevice)
            tokens += result.bestTranscription.segments.map { CaptionToken(text:$0.substring,start:start+$0.timestamp,duration:$0.duration) }
        } catch {
            let code = (error as NSError).code
            // "No speech detected" in one chunk should not discard the others.
            if !((error as NSError).domain == "kAFAssistantErrorDomain" && [203,1110].contains(code)) || whole {
                if !whole { try? FileManager.default.removeItem(at:piece) }
                throw error
            }
        }
        if !whole { try? FileManager.default.removeItem(at:piece) }
        start += length
    }
    return tokens
}

@MainActor extension Studio {
    func addCaption() {
        let start = min(max(0, position), max(0, duration - 0.25))
        let cue = CaptionCue(start: start, end: min(duration, start + 2.0), text: "New caption")
        captions.append(cue); selectedCaption = cue.id; timelineFocus = .caption
    }

    func deleteSelectedCaption() {
        guard let selectedCaption else { return }
        captions.removeAll { $0.id == selectedCaption }
        self.selectedCaption = captions.first?.id
    }

    func updateCaption(_ cue: CaptionCue) {
        guard let index = captions.firstIndex(where: { $0.id == cue.id }) else { return }
        captions[index] = cue
    }

    func generateCaptions(localeIdentifier: String) async {
        guard let source, stillImage == nil, !captionGenerating else { return }
        captionGenerating = true
        defer { captionGenerating = false }
        do {
            let sourceAsset = AVURLAsset(url: source)
            guard !(try await sourceAsset.loadTracks(withMediaType: .audio)).isEmpty else { throw failure("This video does not contain an audio track.") }
            let (editedAsset, _, audioMix) = try await makeEditingComposition(asset: sourceAsset, size: CGSize(width: 320, height: 180), fps: 30)
            let audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("Lumio-captions-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            guard let exporter = AVAssetExportSession(asset: editedAsset, presetName: AVAssetExportPresetAppleM4A) else { throw failure("The audio track could not be prepared for transcription.") }
            exporter.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
            exporter.audioMix = audioMix
            try await exporter.export(to: audioURL, as: .m4a)
            let locale = localeIdentifier == "Auto" ? nil : Locale(identifier: localeIdentifier)
            var tokens: [CaptionToken]?
            if #available(macOS 26.0, *) { tokens = try? await transcribeWithSpeechAnalyzer(url: audioURL, locale: locale) }
            if tokens == nil { tokens = try await transcribeWithSpeechRecognizer(url: audioURL, duration: duration, locale: locale) }
            let generated = makeCaptionCues(tokens: tokens ?? [], maxWords: captionStyle.maxWords)
            guard !generated.isEmpty else { throw failure("No spoken words were detected in this video.") }
            captions = generated; selectedCaption = generated.first?.id
        } catch { message = "Captions could not be generated: \(error.localizedDescription)" }
    }
}

func captionArtwork(cue: CaptionCue, activeWord: Int?, style: CaptionStyle) -> CGImage {
    let width = 1200, height = 260
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
    let graphics = NSGraphicsContext(cgContext: context, flipped: true)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = graphics
    let displayed = style.uppercase ? cue.text.uppercased() : cue.text
    let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.lineBreakMode = .byWordWrapping
    let font = NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize, weight: .heavy)
    let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: style.textColor.ns, .paragraphStyle: paragraph]
    let text = NSMutableAttributedString(string: displayed, attributes: attributes)
    if let activeWord, activeWord < cue.words.count {
        var location = 0
        for index in 0...activeWord {
            let word = style.uppercase ? cue.words[index].text.uppercased() : cue.words[index].text
            let range = (displayed as NSString).range(of: word, options: [], range: NSRange(location: location, length: max(0, displayed.utf16.count - location)))
            if range.location != NSNotFound {
                if index == activeWord { text.addAttribute(.foregroundColor, value: style.highlightColor.ns, range: range) }
                location = range.location + range.length
            }
        }
    }
    let limit = CGSize(width: CGFloat(width - 100), height: CGFloat(height - 50))
    let measured = text.boundingRect(with: limit, options: [.usesLineFragmentOrigin, .usesFontLeading])
    let rect = CGRect(x: 50, y: (CGFloat(height) - min(limit.height, measured.height)) / 2, width: CGFloat(width - 100), height: min(limit.height, measured.height) + 8)
    if style.backgroundOpacity > 0.001 {
        let pill = NSBezierPath(roundedRect: rect.insetBy(dx: -25, dy: -15), xRadius: 24, yRadius: 24)
        style.backgroundColor.ns.withAlphaComponent(style.backgroundOpacity).setFill(); pill.fill()
    }
    if style.strokeWidth > 0 {
        let outline=NSMutableAttributedString(attributedString:text)
        outline.addAttributes([.strokeColor:style.strokeColor.ns,.strokeWidth:style.strokeWidth],range:NSRange(location:0,length:outline.length))
        context.setShadow(offset: CGSize(width: 0, height: 7), blur: 16, color: NSColor.black.withAlphaComponent(0.7).cgColor)
        outline.draw(with:rect,options:[.usesLineFragmentOrigin,.usesFontLeading])
        context.setShadow(offset:.zero,blur:0,color:nil)
    }
    text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    return context.makeImage()!
}

struct CaptionPanel: View {
    @ObservedObject var studio: Studio
    @State private var language = "Auto"
    private let presets = ["Bold", "Karaoke", "Bubble", "Neon", "Minimal"]
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Toggle("Show Captions", isOn: $studio.captionStyle.enabled)
            Picker("Language", selection: $language) {
                Text("Auto Detect").tag("Auto")
                Text("English").tag("en-US")
                Text("Turkish").tag("tr-TR")
                Text("Spanish").tag("es-ES")
                Text("French").tag("fr-FR")
                Text("German").tag("de-DE")
            }
            Button { Task { await studio.generateCaptions(localeIdentifier: language) } } label: {
                Label(studio.captionGenerating ? "Generating Transcript…" : "Generate Captions", systemImage: "waveform.badge.mic")
            }.disabled(studio.captionGenerating || studio.source == nil || studio.stillImage != nil)
            HStack {
                Button("Add Caption") { studio.addCaption() }
                Button("Delete", role: .destructive) { studio.deleteSelectedCaption() }.disabled(studio.selectedCaption == nil)
                Button { studio.exportCaptions() } label: { Label("SRT", systemImage: "square.and.arrow.up") }.disabled(studio.captions.isEmpty).help("Export captions as an SRT subtitle file")
            }
            if !studio.captions.isEmpty { Text("Open the Transcript panel to cut the video by deleting words.").font(.caption).foregroundStyle(.secondary) }
            if let cue = studio.captions.first(where: { $0.id == studio.selectedCaption }) {
                Divider(); Text("Selected Caption").fontWeight(.medium)
                TextField("Caption text", text: Binding(get: { cue.text }, set: { var copy = cue; copy.text = $0; studio.updateCaption(copy) }), axis: .vertical).lineLimit(2...5)
                MotionSlider(title: "Start", value: cueValue(cue, \.start), range: 0...max(0.01, studio.duration), suffix: " s")
                MotionSlider(title: "End", value: cueValue(cue, \.end), range: 0...max(0.01, studio.duration), suffix: " s")
            }
            Divider(); Text("Caption Style").fontWeight(.medium)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(presets, id: \.self) { preset in
                    Button { applyPreset(preset) } label: {
                        Text(previewText(preset)).font(previewFont(preset)).foregroundStyle(previewColor(preset)).frame(maxWidth: .infinity).frame(height: 46)
                            .background(preset == "Bubble" ? Color.black.opacity(0.7) : Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(studio.captionStyle.preset == preset ? accent : .white.opacity(0.1), lineWidth: 1.5))
                    }.buttonStyle(.plain).accessibilityLabel(preset)
                }
            }
            Picker("Position", selection: $studio.captionStyle.position) { ForEach(["Top", "Center", "Bottom"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented)
            MotionSlider(title: "Vertical", value: $studio.captionStyle.verticalOffset, range: -300...300)
            MotionSlider(title: "Font Size", value: $studio.captionStyle.fontSize, range: 28...120)
            Stepper("Words per caption: \(studio.captionStyle.maxWords)", value: $studio.captionStyle.maxWords, in: 1...10)
            Toggle("Uppercase", isOn: $studio.captionStyle.uppercase)
            Picker("Animation", selection: Binding(get:{studio.captionStyle.animation},set:{studio.captionStyle.animation=$0})) { ForEach(["None", "Pop", "Bounce", "Fade", "Slide"], id: \.self) { Text($0).tag($0) } }
            ColorPicker("Text Color", selection: styleColor(\.textColor), supportsOpacity: false)
            ColorPicker("Active Word", selection: styleColor(\.highlightColor), supportsOpacity: false)
            ColorPicker("Outline", selection: styleColor(\.strokeColor), supportsOpacity: false)
            MotionSlider(title: "Outline", value: $studio.captionStyle.strokeWidth, range: 0...16)
            MotionSlider(title: "Background", value: $studio.captionStyle.backgroundOpacity, range: 0...1)
        }.font(.system(size: 12))
    }
    func cueValue(_ cue: CaptionCue, _ keyPath: WritableKeyPath<CaptionCue, Double>) -> Binding<Double> {
        Binding(get: { studio.captions.first(where: { $0.id == cue.id })?[keyPath: keyPath] ?? cue[keyPath: keyPath] }, set: { value in
            var copy = studio.captions.first(where: { $0.id == cue.id }) ?? cue
            copy[keyPath: keyPath] = value
            if copy.end < copy.start + 0.05 { if keyPath == \.start { copy.end = copy.start + 0.05 } else { copy.start = max(0, copy.end - 0.05) } }
            studio.updateCaption(copy)
        })
    }
    func styleColor(_ keyPath: WritableKeyPath<CaptionStyle, RGB>) -> Binding<Color> {
        Binding(get: { studio.captionStyle[keyPath: keyPath].color }, set: { studio.captionStyle[keyPath: keyPath] = RGB($0) })
    }
    func previewText(_ preset: String) -> String { preset == "Karaoke" ? "WORD by WORD" : preset.uppercased() }
    func previewFont(_ preset: String) -> Font { .system(size: preset == "Minimal" ? 12 : 14, weight: preset == "Minimal" ? .medium : .heavy, design: preset == "Neon" ? .rounded : .default) }
    func previewColor(_ preset: String) -> Color { preset == "Neon" ? .cyan : preset == "Karaoke" ? accent : .white }
    func applyPreset(_ preset: String) {
        studio.captionStyle.preset = preset
        switch preset {
        case "Karaoke": studio.captionStyle.fontName = "Avenir Next Condensed"; studio.captionStyle.textColor = RGB(0xFFFFFF); studio.captionStyle.highlightColor = RGB(0xD4FF63); studio.captionStyle.backgroundOpacity = 0; studio.captionStyle.strokeWidth = 7; studio.captionStyle.animation = "Pop"
        case "Bubble": studio.captionStyle.fontName = "Avenir Next"; studio.captionStyle.textColor = RGB(0xFFFFFF); studio.captionStyle.highlightColor = RGB(0xFFFFFF); studio.captionStyle.backgroundColor = RGB(0x111111); studio.captionStyle.backgroundOpacity = 0.82; studio.captionStyle.strokeWidth = 0; studio.captionStyle.animation = "Bounce"
        case "Neon": studio.captionStyle.fontName = "Avenir Next"; studio.captionStyle.textColor = RGB(0x58E8FF); studio.captionStyle.highlightColor = RGB(0xFF58C7); studio.captionStyle.backgroundOpacity = 0; studio.captionStyle.strokeColor = RGB(0x26113D); studio.captionStyle.strokeWidth = 5; studio.captionStyle.animation = "Fade"
        case "Minimal": studio.captionStyle.fontName = "Helvetica Neue"; studio.captionStyle.fontSize = 48; studio.captionStyle.textColor = RGB(0xFFFFFF); studio.captionStyle.highlightColor = RGB(0xFFFFFF); studio.captionStyle.backgroundColor = RGB(0x000000); studio.captionStyle.backgroundOpacity = 0.45; studio.captionStyle.strokeWidth = 0; studio.captionStyle.animation = "Fade"
        default: studio.captionStyle.fontName = "Avenir Next Condensed"; studio.captionStyle.fontSize = 64; studio.captionStyle.textColor = RGB(0xFFFFFF); studio.captionStyle.highlightColor = RGB(0xFFD84D); studio.captionStyle.backgroundOpacity = 0; studio.captionStyle.strokeColor = RGB(0x000000); studio.captionStyle.strokeWidth = 8; studio.captionStyle.animation = "Pop"
        }
    }
}
