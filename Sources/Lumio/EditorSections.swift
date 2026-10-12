import SwiftUI

extension Editor {
    var designLayoutControls:some View {
        VStack(alignment:.leading,spacing:12) {
            MotionSlider(title:"Padding",value:$studio.look.padding,range:0...35,suffix:"%")
            MotionSlider(title:"Corners",value:$studio.look.radius,range:0...80)
            MotionSlider(title:"Shadow",value:$studio.look.shadow,range:0...100,suffix:"%")
            DisclosureGroup("Frame, crop & more") {videoControls.padding(.top,14)}
        }
    }
    var designControls:some View {
        VStack(alignment:.leading,spacing:16) {
            designLayoutControls
            Toggle("Glow",isOn:Binding(get:{studio.look.glow>0},set:{studio.look.glow=$0 ? 35:0}))
            if studio.look.glow>0 {glowControls}
            Button {tab="Background"} label:{Label("Choose background",systemImage:"photo.on.rectangle.angled")}
            Divider()
            Button("Reset design") {studio.look=Look()}.controlSize(.small)
        }.font(.system(size:12))
    }
}
