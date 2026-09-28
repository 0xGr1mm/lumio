import SwiftUI

@MainActor extension Studio {
    /// Says what just happened, without getting in the way. Errors still open an alert, because they need
    /// an answer; everything the user did on purpose only needs to be confirmed and then forgotten.
    func flash(_ text:String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for:.seconds(2.2))
            guard !Task.isCancelled else { return }
            await MainActor.run { if self?.toast == text { self?.toast = nil } }
        }
    }
}

/// The confirmation itself: a small pill over the bottom of the picture.
struct ToastView: View {
    var text: String
    var body: some View {
        HStack(spacing:8) {
            Image(systemName:"checkmark.circle.fill").foregroundStyle(accent)
            Text(text).font(.system(size:12,weight:.medium)).foregroundStyle(.white)
        }
        .padding(.horizontal,14).padding(.vertical,9)
        .background(.black.opacity(0.78),in:Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.13)))
        .shadow(color:.black.opacity(0.4),radius:12,y:4)
        .padding(.bottom,18)
        .transition(.move(edge:.bottom).combined(with:.opacity))
    }
}
