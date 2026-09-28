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
            if studio.selectedZoom != nil { ZoomInspector(studio:studio);Divider() }
            Text("Auto Zoom Settings").font(.headline)
            Toggle("Enable",isOn:$studio.motion.autoZoom)
            if studio.pointerSamples.isEmpty { Text("Auto Zoom requires a new Lumio recording with pointer data. You can still add manual zooms to this video.").font(.caption).foregroundStyle(.secondary) }
            Divider()
            MotionSlider(title:"Zoom",value:$studio.motion.zoom,range:1...6,suffix:"×")
            MotionSlider(title:"Camera Zoom",value:$studio.motion.cameraZoom,range:1...3,suffix:"×")
            HStack { Button("Add Camera Video…") { studio.chooseCameraVideo() };if studio.cameraPath != nil { Button { studio.cameraPath=nil;studio.refreshComposition() } label:{Image(systemName:"xmark")} } }.font(.caption)
            Toggle("Keep Zoomed In",isOn:$studio.motion.keepZoomed)
            Picker("Motion",selection:$studio.motion.motion) {
                Image(systemName:"scope").tag("focused")
                Image(systemName:"water.waves").tag("fluid")
                Image(systemName:"bolt.fill").tag("spring")
            }.pickerStyle(.segmented)
            Text(studio.motion.motion == "focused" ? "Settles quickly and keeps text easy to follow." : studio.motion.motion == "fluid" ? "Uses smooth, fluid camera movement." : "Adds a quick spring overshoot and return.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Motion Blur").font(.subheadline).foregroundStyle(.secondary)
            Toggle("Enable",isOn:$studio.motion.blurEnabled)
            MotionSlider(title:"Amount",value:$studio.motion.blurAmount,range:0...1)
            Picker("Quality",selection:$studio.motion.blurQuality) {
                Image(systemName:"hare.fill").tag(0)
                Image(systemName:"gauge.with.dots.needle.50percent").tag(1)
                Image(systemName:"tortoise.fill").tag(2)
            }.pickerStyle(.segmented)
            DisclosureGroup("Advanced") {
                VStack(spacing:14) {
                    MotionSlider(title:"Cursor",value:$studio.motion.blurCursor,range:0...1)
                    MotionSlider(title:"Screen",value:$studio.motion.blurScreen,range:0...1)
                    MotionSlider(title:"Zoom",value:$studio.motion.blurZoom,range:0...1)
                    MotionSlider(title:"Snap to Edge",value:$studio.motion.snap,range:0...1)
                }.padding(.top,12)
            }
            Divider()
            if studio.selectedZoom == nil { ZoomInspector(studio:studio) }
        }.font(.system(size:12))
    }
}
struct CursorPanel:View {
    @ObservedObject var studio:Studio
    let styles=["Classic Outline","Solid Arrow","Lavender","Neon","Pixel","3D","Color Pop","Cartoon","Minecraft Enchanted","Pop Cat","Rose Diamond","Among Us Batman","Among Us Joker","Harley Quinn"]
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Toggle("Show Cursor",isOn:$studio.motion.showCursor)
            if studio.cursorEmbedded { Text("The cursor is embedded in this video. Cursor styling applies to new Lumio recordings that contain separate pointer data.").font(.caption).foregroundStyle(.secondary) }
            Text("Style").font(.caption)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:8) {
                ForEach(styles,id:\.self) { name in
                    Button { studio.motion.style=name } label: {
                        Image(decorative:cursorArtwork(style:name,color:studio.motion.color.ns),scale:1).resizable().scaledToFit().padding(12).frame(maxWidth:.infinity).frame(height:60).background(studio.motion.style == name ? Color.white.opacity(0.18):Color.white.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius:8)).overlay(RoundedRectangle(cornerRadius:8).stroke(.white.opacity(0.15)))
                    }.buttonStyle(.plain).help(name).accessibilityLabel(name)
                }
            }
            Picker("Type",selection:$studio.motion.type) { Text("Auto").tag("Auto");Text("Fixed").tag("Fixed") }.pickerStyle(.segmented)
            Text("Auto preserves the pointer shape detected during recording.").font(.caption).foregroundStyle(.secondary)
            MotionSlider(title:"Size",value:$studio.motion.size,range:25...400,suffix:"%")
            HStack(spacing:9) {
                ForEach([UInt32(0),0xFFFFFF,0xFFBE00,0xF655AA,0x34C759,0x00C8EC,0xBFC8FF],id:\.self) { hex in
                    Button { studio.motion.color=RGB(hex) } label: { Circle().fill(RGB(hex).color).frame(width:21,height:21).overlay(Circle().stroke(.white.opacity(0.6))) }.buttonStyle(.plain)
                }
                ColorPicker("",selection:Binding(get:{studio.motion.color.color},set:{studio.motion.color=RGB($0)}),supportsOpacity:false).labelsHidden()
            }
            Divider()
            Text("Motion").foregroundStyle(.secondary)
            Toggle("Smoothing",isOn:$studio.motion.smoothing)
            MotionSlider(title:"Stiffness",value:$studio.motion.stiffness,range:20...1000)
            MotionSlider(title:"Damping",value:$studio.motion.damping,range:1...150)
            MotionSlider(title:"Mass",value:$studio.motion.mass,range:0.2...10)
            Toggle("Tilt",isOn:$studio.motion.tilt)
            Divider()
            Text("Timeline").foregroundStyle(.secondary)
            Picker("End Motion",selection:$studio.motion.endMotion) {
                Image(systemName:"nosign").tag("hide")
                Image(systemName:"arrow.trianglehead.2.clockwise").tag("loop")
                Image(systemName:"snowflake").tag("stop")
            }.pickerStyle(.segmented)
            Toggle("Shake Filter",isOn:$studio.motion.shakeFilter)
            MotionSlider(title:"Threshold",value:$studio.motion.threshold,range:0...1000)
            DisclosureGroup("Click Effect") {
                VStack(spacing:14) {
                    MotionSlider(title:"Zoom",value:$studio.motion.clickZoom,range:0...0.8)
                    MotionSlider(title:"Duration",value:$studio.motion.clickDuration,range:0.05...1,suffix:" s")
                    Toggle("Click Highlight",isOn:$studio.motion.clickHighlight)
                    Text("Shows a ring that expands from every click.").font(.caption).foregroundStyle(.secondary)
                }.padding(.top,12)
            }
            DisclosureGroup("Click Sound") { Toggle("Click Sounds",isOn:$studio.motion.clickSound).padding(.top,12) }
            DisclosureGroup("Spotlight") {
                VStack(alignment:.leading,spacing:14) {
                    Text("Dims the screen except for a circle around the pointer, so an eye goes where the hand is.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                    MotionSlider(title:"Dim",value:Binding(get:{studio.motion.resolvedSpotlight},set:{studio.motion.spotlight=$0}),range:0...100,suffix:"%")
                    MotionSlider(title:"Size",value:Binding(get:{studio.motion.resolvedSpotlightSize},set:{studio.motion.spotlightSize=$0}),range:8...70,suffix:"%")
                    HStack(spacing:8) {
                        Button("Off") { studio.motion.spotlight=0 }
                        Button("Subtle") { studio.motion.spotlight=45;studio.motion.spotlightSize=34 }
                        Button("Strong") { studio.motion.spotlight=85;studio.motion.spotlightSize=22 }
                    }.controlSize(.small)
                }.padding(.top,12)
            }
            Divider();Text("Visibility").foregroundStyle(.secondary)
            Toggle("Hide Idle",isOn:$studio.motion.hideIdle)
            if studio.motion.hideIdle { MotionSlider(title:"Idle Delay",value:$studio.motion.idleDelay,range:0.3...5,suffix:" s") }
            Toggle("Hide Typing",isOn:$studio.motion.hideTyping)
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
