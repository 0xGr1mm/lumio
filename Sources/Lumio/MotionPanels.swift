import SwiftUI

struct MotionSlider:View {
    var title:String
    @Binding var value:Double
    var range:ClosedRange<Double>
    var suffix:String = ""
    var body:some View {
        HStack(spacing:10) {
            Text(title).font(.system(size:12)).frame(width:83,alignment:.leading)
            Slider(value:$value,in:range).controlSize(.small)
            TextField("",value:$value,format:.number.precision(.fractionLength(suffix == "×" || suffix == " s" || range.upperBound <= 10 ? 2:0)))
                .textFieldStyle(.roundedBorder).frame(width:54).font(.system(size:11)).onSubmit { value=min(range.upperBound,max(range.lowerBound,value)) }
            if !suffix.isEmpty { Text(suffix).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
struct AutoZoomPanel:View {
    @ObservedObject var studio:Studio
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            if studio.selectedZoom != nil {ZoomInspector(studio:studio);Divider()}
            Toggle("Automatic zoom",isOn:Binding(get:{!studio.pointerSamples.isEmpty && studio.motion.autoZoom},set:{studio.motion.autoZoom=$0})).disabled(studio.pointerSamples.isEmpty)
            if studio.pointerSamples.isEmpty {
                Text("Record with Lumio to zoom automatically on clicks. You can add a zoom to any video.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Frames your clicks and holds steady around nearby activity.").font(.caption).foregroundStyle(.secondary)
            }
            MotionSlider(title:"Zoom",value:$studio.motion.zoom,range:1...3,suffix:"×")
            Picker("Movement",selection:$studio.motion.motion) {
                Text("Focused").tag("focused");Text("Fluid").tag("fluid")
            }.pickerStyle(.segmented)
            Toggle("Zoom on typing",isOn:Binding(get:{studio.motion.zoomOnTyping ?? true},set:{studio.motion.zoomOnTyping=$0}))
            HStack {
                Button {studio.addZoom()} label:{Label("Add zoom",systemImage:"plus.magnifyingglass")}
                    .disabled(studio.stillImage != nil || studio.duration<=0)
                if studio.selectedZoom != nil {Button("Done") {studio.selectedZoom=nil}}
            }.controlSize(.small)
            DisclosureGroup("More motion options") {
                VStack(alignment:.leading,spacing:14) {
                    Toggle("Keep zoomed in",isOn:$studio.motion.keepZoomed)
                    MotionSlider(title:"Max zoom",value:$studio.motion.zoom,range:1...6,suffix:"×")
                    Toggle("Motion blur",isOn:$studio.motion.blurEnabled)
                    if studio.motion.blurEnabled {MotionSlider(title:"Blur amount",value:$studio.motion.blurAmount,range:0...1)}
                    Picker("Blur quality",selection:$studio.motion.blurQuality) {Text("Fast").tag(0);Text("Balanced").tag(1);Text("High").tag(2)}
                    MotionSlider(title:"Cut punch",value:Binding(get:{studio.motion.resolvedPunch},set:{studio.motion.punchOnCut=$0}),range:0...100,suffix:"%")
                }.padding(.top,12)
            }
        }.font(.system(size:12))
    }
}
struct CursorPanel:View {
    @ObservedObject var studio:Studio
    let styles=["Classic Outline","Solid Arrow","Lavender"]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Toggle("Show cursor",isOn:$studio.motion.showCursor)
            if studio.cursorEmbedded {Text("This video's cursor is embedded. Record with Lumio to change its look and movement.").font(.caption).foregroundStyle(.secondary)}
            LazyVGrid(columns:Array(repeating:GridItem(.flexible()),count:3),spacing:8) {
                ForEach(styles,id:\.self) {name in
                    Button {studio.motion.style=name} label: {
                        Image(decorative:cursorArtwork(style:name,color:studio.motion.color.ns),scale:1).resizable().scaledToFit().padding(12).frame(maxWidth:.infinity).frame(height:58)
                            .background(studio.motion.style==name ? accent.opacity(0.15):Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8))
                    }.buttonStyle(.plain).help(name).accessibilityLabel(name)
                }
            }
            MotionSlider(title:"Size",value:$studio.motion.size,range:50...200,suffix:"%")
            Toggle("Smooth movement",isOn:$studio.motion.smoothing)
            Toggle("Highlight clicks",isOn:$studio.motion.clickHighlight)
            Toggle("Hide when idle",isOn:$studio.motion.hideIdle)
            if studio.motion.hideIdle {MotionSlider(title:"Idle delay",value:$studio.motion.idleDelay,range:0.3...5,suffix:" s")}
            DisclosureGroup("More cursor options") {
                VStack(alignment:.leading,spacing:14) {
                    Picker("Style",selection:$studio.motion.style) {
                        ForEach(["Classic Outline","Solid Arrow","Lavender","Neon","Pixel","3D","Color Pop","Cartoon","Minecraft Enchanted","Pop Cat","Rose Diamond","Among Us Batman","Among Us Joker","Harley Quinn"],id:\.self) {Text($0).tag($0)}
                    }
                    Picker("Pointer shape",selection:$studio.motion.type) {Text("Recorded").tag("Auto");Text("Arrow").tag("Fixed")}
                    ColorPicker("Color",selection:Binding(get:{studio.motion.color.color},set:{studio.motion.color=RGB($0)}),supportsOpacity:false)
                    MotionSlider(title:"Max size",value:$studio.motion.size,range:25...400,suffix:"%")
                    MotionSlider(title:"Stiffness",value:$studio.motion.stiffness,range:20...1000)
                    MotionSlider(title:"Damping",value:$studio.motion.damping,range:1...150)
                    MotionSlider(title:"Mass",value:$studio.motion.mass,range:0.2...10)
                    Toggle("Tilt",isOn:$studio.motion.tilt)
                    Toggle("Hide while typing",isOn:$studio.motion.hideTyping)
                    Toggle("Click sounds",isOn:$studio.motion.clickSound)
                    Toggle("Cut sounds",isOn:Binding(get:{studio.motion.resolvedCutSound},set:{studio.motion.cutSound=$0}))
                    MotionSlider(title:"Spotlight",value:Binding(get:{studio.motion.resolvedSpotlight},set:{studio.motion.spotlight=$0}),range:0...100,suffix:"%")
                }.padding(.top,12)
            }
        }.font(.system(size:12))
    }
}

struct AnimationPanel:View {
    @ObservedObject var studio:Studio
    @State private var section = "Motion Blur"
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Picker("Animation Section",selection:$section) {
                Text("Motion Blur").tag("Motion Blur")
                Text("Cursor").tag("Cursor")
                Text("Screen").tag("Screen")
                Text("Ends").tag("Ends")
            }.pickerStyle(.segmented).labelsHidden()
            Divider()
            if section == "Motion Blur" {
                Text("Motion Blur").font(.headline)
                Text("Adds cinematic blur to cursor movement, screen movement and zoom transitions.").font(.caption).foregroundStyle(.secondary)
                Toggle("Enable",isOn:$studio.motion.blurEnabled)
                MotionSlider(title:"Strength",value:$studio.motion.blurAmount,range:0...1)
                Picker("Quality",selection:$studio.motion.blurQuality) {
                    Label("Fast",systemImage:"hare.fill").tag(0)
                    Label("Balanced",systemImage:"gauge.with.dots.needle.50percent").tag(1)
                    Label("High",systemImage:"tortoise.fill").tag(2)
                }.pickerStyle(.segmented)
                DisclosureGroup("Advanced") {
                    VStack(spacing:14) {
                        MotionSlider(title:"Cursor",value:$studio.motion.blurCursor,range:0...1)
                        MotionSlider(title:"Screen Zoom",value:$studio.motion.blurZoom,range:0...1)
                        MotionSlider(title:"Screen Move",value:$studio.motion.blurScreen,range:0...1)
                    }.padding(.top,12)
                }
            } else if section == "Cursor" {
                Text("Cursor Animations").font(.headline)
                Text("Choose how quickly the recorded pointer settles into each movement.").font(.caption).foregroundStyle(.secondary)
                Picker("Cursor Animation Style",selection:cursorAnimation) {
                    ForEach(["Smooth","Medium","Rapid","None"],id:\.self) {Text($0).tag($0)}
                }
                if studio.motion.cursorAnimation != "None" {
                    DisclosureGroup("Advanced") {
                        VStack(spacing:14) {
                            MotionSlider(title:"Stiffness",value:$studio.motion.stiffness,range:20...1000)
                            MotionSlider(title:"Damping",value:$studio.motion.damping,range:1...150)
                            MotionSlider(title:"Mass",value:$studio.motion.mass,range:0.2...10)
                            Toggle("Tilt",isOn:$studio.motion.tilt)
                        }.padding(.top,12)
                    }
                }
            } else if section == "Ends" {
                Text("Fade In and Out").font(.headline)
                Text("The finished video starts from black and returns to it, picture and sound together.").font(.caption).foregroundStyle(.secondary)
                MotionSlider(title:"Fade In (s)",value:Binding(get:{studio.look.resolvedFadeIn},set:{studio.look.fadeIn=$0<=0.01 ? nil:$0}),range:0...5)
                MotionSlider(title:"Fade Out (s)",value:Binding(get:{studio.look.resolvedFadeOut},set:{studio.look.fadeOut=$0<=0.01 ? nil:$0}),range:0...5)
                Button("No Fade") { studio.look.fadeIn=nil;studio.look.fadeOut=nil }
                    .disabled(studio.look.resolvedFadeIn==0 && studio.look.resolvedFadeOut==0)
            } else {
                Text("Screen Animation").font(.headline)
                Text(studio.motion.motion == "focused" ? "Animation stabilizes quickly, making text easier to follow and read." : "Animation moves fluidly for creative content and softer camera travel.").font(.caption).foregroundStyle(.secondary)
                Picker("Style",selection:$studio.motion.motion) {
                    Label("Focused",systemImage:"scope").tag("focused")
                    Label("Smooth",systemImage:"water.waves").tag("fluid")
                }.pickerStyle(.segmented)
                MotionSlider(title:"Snap to Edge",value:$studio.motion.snap,range:0...1)
            }
        }.font(.system(size:12))
    }
    var cursorAnimation:Binding<String> {
        Binding(get:{studio.motion.cursorAnimation},set:{ value in
            studio.motion.cursorAnimation=value
            switch value {
            case "Smooth":studio.motion.smoothing=true;studio.motion.stiffness=260;studio.motion.damping=42;studio.motion.mass=4
            case "Rapid":studio.motion.smoothing=true;studio.motion.stiffness=820;studio.motion.damping=92;studio.motion.mass=1.6
            case "None":studio.motion.smoothing=false
            default:studio.motion.smoothing=true;studio.motion.stiffness=470;studio.motion.damping=70;studio.motion.mass=3
            }
        })
    }
}
