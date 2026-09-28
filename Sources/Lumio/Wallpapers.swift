import SwiftUI

struct Wallpaper:Codable,Identifiable {
    let id:String;let name:String;let width:Int;let height:Int;let category:String
}
@MainActor final class WallpaperLibrary:ObservableObject {
    static let shared=WallpaperLibrary()
    @Published var items:[Wallpaper]=[]
    let folder:URL
    init() {
        folder=Bundle.main.resourceURL!.appendingPathComponent("Wallpapers")
        if let data=try? Data(contentsOf:folder.appendingPathComponent("catalog.json")),let decoded=try? JSONDecoder().decode([Wallpaper].self,from:data) { items=decoded }
    }
    func url(_ item:Wallpaper)->URL { folder.appendingPathComponent(item.id+".jpg") }
    func thumb(_ item:Wallpaper)->NSImage? { NSImage(contentsOf:folder.appendingPathComponent("thumbs/"+item.id+".jpg")) }
}
struct WallpaperPanel:View {
    @ObservedObject var studio:Studio
    @ObservedObject var library=WallpaperLibrary.shared
    @State var query=""
    @State var category="All"
    var filtered:[Wallpaper] { library.items.filter { (category == "All" || $0.category == category || (category == "Classic" && $0.category == "klasik")) && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)) } }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Picker("Collection",selection:$category) { Text("All").tag("All");Text("Apple").tag("Apple");Text("Classic").tag("Classic") }.pickerStyle(.segmented)
            TextField("Search wallpapers",text:$query).textFieldStyle(.roundedBorder)
            HStack {
                Button { if let item=filtered.randomElement(){apply(item)} } label:{Label("Random",systemImage:"shuffle")}
                Button { studio.chooseBackground() } label:{Image(systemName:"plus")}.help("Add your own wallpaper")
                Button { studio.useDesktopBackground() } label:{Image(systemName:"desktopcomputer")}.help("Use desktop wallpaper")
            }.buttonStyle(.bordered).controlSize(.small)
            Text("\(filtered.count) wallpapers · Offline").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(filtered) { item in
                    Button { apply(item) } label: {
                        VStack(alignment:.leading,spacing:3) {
                            if let image=library.thumb(item) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fill).frame(height:62).clipped().clipShape(RoundedRectangle(cornerRadius:7)) }
                            Text(item.name).font(.system(size:9)).lineLimit(1).foregroundStyle(.secondary)
                        }.contentShape(Rectangle()).overlay(RoundedRectangle(cornerRadius:7).stroke(studio.look.imagePath == library.url(item).path ? accent:.clear,lineWidth:2))
                    }.buttonStyle(.plain).help("\(item.name) · \(item.width) × \(item.height)")
                }
            }
        }
    }
    func apply(_ item:Wallpaper) { studio.look.imagePath=library.url(item).path;studio.look.mode="Image" }
}
