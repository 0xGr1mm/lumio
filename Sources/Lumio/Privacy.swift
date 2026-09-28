import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// Something on screen that should not be published: a wallet address, a seed phrase, a balance, an e-mail.
/// Only the kind, the place and the moments it was seen are kept. The text itself is never stored in the project,
/// because a recovery phrase written into a project file would be exactly the leak this is meant to prevent.
struct SensitiveFind: Identifiable, Equatable {
    var id = UUID()
    var kind: String
    /// A masked hint so the list can be read without showing the secret, e.g. "0x4f2…9ab".
    var hint: String
    /// Top-left unit rectangle in the visible (cropped) video.
    var rect: CGRect
    var start: Double
    var end: Double
    /// True when the find is unmistakable — a private key, or a long run of phrase words. Only these are
    /// covered without asking, because covering an address the video is about would be the wrong call.
    var strong = false
    var hidden = false
}

/// What the scan looks for. Hex and base58 cover Ethereum-style and Solana-style addresses;
/// a 64-character hex run is a private key, which is the one thing that must never reach a video.
struct SensitivePattern { var kind:String; var expression:NSRegularExpression }

func sensitivePatterns(addresses:Bool,emails:Bool,balances:Bool)->[SensitivePattern] {
    var patterns:[(String,String)] = []
    if addresses {
        patterns.append(("Private Key","\\b[0-9a-fA-F]{64}\\b"))
        // An address is often shown shortened, with dots or an ellipsis in the middle; both halves are covered.
        patterns.append(("Wallet Address","0x[0-9a-fA-F]{3,}(?:\\s?[.…]{1,3}\\s?[0-9a-fA-F]{2,})?"))
        patterns.append(("Wallet Address","\\b[1-9A-HJ-NP-Za-km-z]{32,44}\\b"))
        patterns.append(("Wallet Name","\\b[a-z0-9][a-z0-9-]{2,}\\.(?:eth|sol|lens|base)\\b"))
    }
    if emails { patterns.append(("E-mail","\\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}\\b")) }
    if balances {
        patterns.append(("Balance","[$€£₺]\\s?\\d[\\d.,]*"))
        patterns.append(("Balance","\\b\\d[\\d.,]*\\s?(?:ETH|BTC|SOL|USDC|USDT|BNB|MATIC|AVAX|ARB|OP)\\b"))
    }
    return patterns.compactMap { kind,source in
        (try? NSRegularExpression(pattern:source)).map { SensitivePattern(kind:kind,expression:$0) }
    }
}

/// Words that could belong to a recovery phrase: three to eight lowercase letters, no numbers, no punctuation.
/// A line holding an everyday English function word is not a phrase, which is what keeps ordinary prose on screen
/// from being mistaken for one: none of those words are in the phrase vocabulary.
let everydayWords:Set<String> = ["the","and","for","are","but","not","you","all","can","her","was","one","our","out","has","had","his","how","its","who","did","yes","with","this","that","from","they","what","when","your","have","been","will","would","there","their","which","about","into","than","then","them","some","only","also","just","like","more","most","over","such","very","were","after","before","other","because","while","where","these","those","should","could","still","using","used","make","made","need","want","sure","here","even","much","many","each","both","same","between"]

func recoveryPhraseWordCount(_ line:String)->Int {
    let tokens = line.split(whereSeparator:{ $0 == " " || $0 == "\t" }).map { token in
        String(token).trimmingCharacters(in:CharacterSet(charactersIn:",.;:()[]|-·•"))
    }.filter { !$0.isEmpty }
    for token in tokens where everydayWords.contains(token.lowercased()) { return 0 }
    // Wallets number the words, so the numbers beside them are not held against the line.
    let words = tokens.filter { !$0.allSatisfy(\.isNumber) }
    guard !words.isEmpty else { return 0 }
    let counted = words.filter { $0.count >= 3 && $0.count <= 8 && $0.allSatisfy { $0.isLetter && $0.isLowercase } }.count
    // A line that is mostly something else — a label beside an address, a sentence with figures — is not a phrase row.
    return Double(counted) >= Double(words.count)*0.7 ? counted : 0
}

/// Text recognition sometimes answers with a Cyrillic or Greek look-alike for a Latin letter, so "12.48 ETH" comes
/// back as "12.48 ЕTH" and an honest pattern misses it. Each stands in for exactly one character, so the places of
/// the matches still line up with the text they were found in.
let latinLookAlikes:[Character:Character] = ["А":"A","В":"B","Е":"E","К":"K","М":"M","Н":"H","О":"O","Р":"P","С":"C","Т":"T","Х":"X","У":"Y","Ѕ":"S","Ј":"J","а":"a","е":"e","о":"o","р":"p","с":"c","х":"x","у":"y","і":"i","ѕ":"s","ј":"j","Α":"A","Β":"B","Ε":"E","Η":"H","Ι":"I","Κ":"K","Μ":"M","Ν":"N","Ο":"O","Ρ":"P","Τ":"T","Υ":"Y","Χ":"X","Ζ":"Z","α":"a","ο":"o","ι":"i","ν":"v"]

func latinized(_ text:String)->String {
    let mapped = String(text.map { latinLookAlikes[$0] ?? $0 })
    // If a substitution changed the length the places would shift, so the original is used instead.
    return mapped.utf16.count == text.utf16.count ? mapped : text
}

/// Shows enough of a find to recognise it without printing the secret.
func maskedHint(_ text:String)->String {
    let trimmed = text.trimmingCharacters(in:.whitespaces)
    guard trimmed.count > 10 else { return String(repeating:"•",count:max(3,trimmed.count)) }
    return trimmed.prefix(5)+"…"+trimmed.suffix(3)
}

/// Converts a Vision box (bottom-left, whole frame) into an annotation rectangle (top-left, visible video),
/// with a little room around it so a blur covers the whole glyph rather than its measured box.
func sensitiveRect(_ box:CGRect,crop:CGRect)->CGRect? {
    guard crop.width > 0.001, crop.height > 0.001 else { return nil }
    let padX = max(0.004,box.width*0.03), padY = max(0.008,box.height*0.28)
    let frame = CGRect(x:box.minX-padX,y:1-box.maxY-padY,width:box.width+padX*2,height:box.height+padY*2)
    let visible = CGRect(x:(frame.minX-crop.minX)/crop.width,y:(frame.minY-crop.minY)/crop.height,
                         width:frame.width/crop.width,height:frame.height/crop.height)
    // A find that the crop already removed does not need hiding.
    guard visible.maxX > 0.01, visible.minX < 0.99, visible.maxY > 0.01, visible.minY < 0.99 else { return nil }
    return CGRect(x:max(0,visible.minX),y:max(0,visible.minY),
                  width:min(1,visible.maxX)-max(0,visible.minX),height:min(1,visible.maxY)-max(0,visible.minY))
}

/// Reads one frame and reports what should be hidden on it.
func sensitiveFinds(in image:CGImage,at time:Double,crop:CGRect,patterns:[SensitivePattern])->[SensitiveFind] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    // Language correction rewrites addresses into words, which is the opposite of what this needs.
    request.usesLanguageCorrection = false
    guard (try? VNImageRequestHandler(cgImage:image,options:[:]).perform([request])) != nil,
          let observations = request.results else { return [] }
    var finds:[SensitiveFind] = []
    var phraseRows:[(words:Int,box:CGRect)] = []
    for observation in observations {
        guard let candidate = observation.topCandidates(1).first else { continue }
        let line = candidate.string
        let searchable = latinized(line)
        let words = recoveryPhraseWordCount(searchable)
        if words > 0 { phraseRows.append((words,observation.boundingBox)) }
        let text = searchable as NSString
        for pattern in patterns {
            for match in pattern.expression.matches(in:searchable,range:NSRange(location:0,length:text.length)) {
                guard let range = Range(match.range,in:line),
                      let box = try? candidate.boundingBox(for:range),
                      let rect = sensitiveRect(box.boundingBox,crop:crop) else { continue }
                finds.append(SensitiveFind(kind:pattern.kind,hint:maskedHint(String(line[range])),rect:rect,
                                           start:time,end:time,strong:pattern.kind == "Private Key"))
            }
        }
    }
    // Twelve of those words on one screen is a recovery phrase however it is laid out: one line, or a grid of boxes.
    let phraseWords = phraseRows.reduce(0) { $0+$1.words }
    if phraseWords >= 12 {
        for row in phraseRows {
            guard let rect = sensitiveRect(row.box,crop:crop) else { continue }
            finds.append(SensitiveFind(kind:"Recovery Phrase",hint:"\(row.words) words",rect:rect,start:time,end:time,strong:row.words >= 8))
        }
    }
    return finds
}

/// The same address found on frame after frame is one thing to hide, for as long as it was on screen.
func mergedFinds(_ finds:[SensitiveFind],duration:Double,padding:Double=0.45)->[SensitiveFind] {
    var groups:[SensitiveFind] = []
    for find in finds {
        if let index = groups.firstIndex(where:{ $0.kind == find.kind && overlapFraction($0.rect,find.rect) > 0.35 }) {
            groups[index].rect = groups[index].rect.union(find.rect)
            groups[index].start = min(groups[index].start,find.start)
            groups[index].end = max(groups[index].end,find.end)
            groups[index].strong = groups[index].strong || find.strong
        } else {
            groups.append(find)
        }
    }
    return groups.map { group in
        var copy = group
        copy.start = max(0,group.start-padding)
        copy.end = min(duration,max(copy.start+0.3,group.end+padding))
        return copy
    }.sorted { $0.start < $1.start }
}

func overlapFraction(_ a:CGRect,_ b:CGRect)->Double {
    let shared = a.intersection(b)
    guard !shared.isNull, shared.width > 0, shared.height > 0 else { return 0 }
    let smaller = min(a.width*a.height,b.width*b.height)
    return smaller > 0 ? shared.width*shared.height/smaller : 0
}

@MainActor extension Studio {
    /// Looks through the recording for wallet addresses and other private details, on this machine only.
    func scanForSensitiveText() async {
        guard duration > 0, stillImage == nil, !privacyScanning else { return }
        // With every switch off the scan still finds a recovery phrase, which is never worth leaving on screen.
        let patterns = sensitivePatterns(addresses:privacyAddresses,emails:privacyEmails,balances:privacyBalances)
        privacyScanning = true; privacyProgress = 0; privacyFinds = []
        defer { privacyScanning = false; privacyProgress = nil }
        let crop = (look.videoStyle ?? VideoStyle()).cropRect
        // Sixty frames is enough to catch a detail that stays on screen for a second, and keeps a long
        // recording from taking minutes: text recognition is the slow part, not reading the frames.
        let steps = max(4,min(60,Int(duration)))
        var generators:[String:AVAssetImageGenerator] = [:]
        var found:[SensitiveFind] = []
        for step in 0..<steps {
            if Task.isCancelled { break }
            let time = duration*Double(step)/Double(max(1,steps-1))
            guard let placement = placement(containing:min(time,max(0,duration-0.01))) ?? clipPlacements.first else { continue }
            let path = placement.clip.source ?? source?.path ?? ""
            guard !path.isEmpty else { continue }
            if generators[path] == nil {
                let generator = AVAssetImageGenerator(asset:AVURLAsset(url:URL(fileURLWithPath:path)))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
                // Text this small needs the pixels: a downscaled frame turns an address into a grey smear.
                generator.maximumSize = CGSize(width:2560,height:2560)
                generators[path] = generator
            }
            guard let generator = generators[path] else { continue }
            let sourceTime = placement.clip.sourceTime(forTimeline:time)
            guard let frame = try? await generator.image(at:CMTime(seconds:max(0,sourceTime),preferredTimescale:600)).image else { continue }
            let onFrame = await Task.detached(priority:.userInitiated) { sensitiveFinds(in:frame,at:time,crop:crop,patterns:patterns) }.value
            found.append(contentsOf:onFrame)
            privacyProgress = Double(step+1)/Double(steps)
            privacyFinds = mergedFinds(found,duration:duration)
        }
        privacyFinds = mergedFinds(found,duration:duration)
        privacyScanned = true
        flash(privacyFinds.isEmpty ? "Nothing private found in \(steps) frames":"\(privacyFinds.count) to look at")
    }
    /// Covers one find with a solid block for as long as it is on screen.
    @discardableResult func hideFind(_ id:UUID)->UUID? {
        guard let index = privacyFinds.firstIndex(where:{ $0.id == id }) else { return nil }
        let find = privacyFinds[index]
        var item = Annotation(kind:"Hide",start:find.start,end:find.end)
        item.x = find.rect.minX; item.y = find.rect.minY; item.width = find.rect.width; item.height = find.rect.height
        item.color = RGB(0x101216)
        annotations.append(item)
        privacyFinds[index].hidden = true
        refreshComposition()
        flash("\(find.kind) covered")
        return item.id
    }
    func hideEveryFind() {
        for find in privacyFinds where !find.hidden { hideFind(find.id) }
    }
    /// A block the user places themselves, for anything the scan cannot read.
    func hideRegionAtPlayhead() { addAnnotation("Hide") }
}

struct PrivacyPanel: View {
    @ObservedObject var studio: Studio
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Before you post it, take your wallet off the screen. Lumio reads the recording on this Mac — nothing is uploaded.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            VStack(alignment:.leading,spacing:7) {
                Toggle("Wallet addresses, keys and .eth names",isOn:$studio.privacyAddresses)
                Toggle("E-mail addresses",isOn:$studio.privacyEmails)
                Toggle("Balances and amounts",isOn:$studio.privacyBalances)
            }.font(.system(size:12)).toggleStyle(.switch)
            if let progress = studio.privacyProgress {
                HStack(spacing:8) { ProgressView(value:progress).frame(width:120); Text("\(Int(progress*100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            HStack(spacing:8) {
                Button { Task { await studio.scanForSensitiveText() } } label: { Label("Scan Recording",systemImage:"sparkle.magnifyingglass") }
                    .buttonStyle(.borderedProminent).disabled(studio.duration <= 0 || studio.stillImage != nil || studio.privacyScanning)
                Button { studio.hideRegionAtPlayhead() } label: { Label("Hide Region",systemImage:"square.slash") }
                    .help("Put a block on the picture yourself and drag it over anything private").disabled(studio.duration <= 0 || studio.stillImage != nil)
            }
            if studio.privacyScanned,studio.privacyFinds.isEmpty,!studio.privacyScanning {
                Text("Nothing private was found. If something only flashes by, put a block on it yourself with Hide Region.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
            if !studio.privacyFinds.isEmpty {
                Divider()
                HStack {
                    Text("\(studio.privacyFinds.count) found").font(.system(size:12,weight:.semibold))
                    Spacer()
                    Button("Hide All") { studio.hideEveryFind() }.disabled(studio.privacyFinds.allSatisfy(\.hidden))
                }
                ForEach(studio.privacyFinds) { find in
                    HStack(spacing:9) {
                        Image(systemName:find.kind == "Recovery Phrase" || find.kind == "Private Key" ? "exclamationmark.shield.fill":"eye.slash")
                            .foregroundStyle(find.kind == "Recovery Phrase" || find.kind == "Private Key" ? .red:.secondary)
                        VStack(alignment:.leading,spacing:1) {
                            Text(find.kind).font(.system(size:11,weight:.medium))
                            Text("\(find.hint) · \(stampedRange(find))").font(.system(size:10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Spacer(minLength:0)
                        if find.hidden {
                            Image(systemName:"checkmark.circle.fill").foregroundStyle(accent)
                        } else {
                            Button("Hide") { studio.hideFind(find.id) }.controlSize(.small)
                        }
                    }
                    .padding(.vertical,6).padding(.horizontal,8)
                    .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius:8))
                    .onTapGesture { studio.position = find.start; studio.seek(find.start) }
                }
                Text("A block is placed for as long as the detail is on screen. Drag its ends in the timeline, or drag the block on the picture, to adjust it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            }
        }
        .onAppear { studio.annotationEditing = true }
        .onDisappear { studio.annotationEditing = false }
    }
    func stampedRange(_ find:SensitiveFind)->String { String(format:"%.1f – %.1f s",find.start,find.end) }
}
