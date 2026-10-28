import BubblesCore
import SwiftUI

/// The SwiftUI part of the float window: the toast above the mic. Bubbles, the "+N" bubble, the mic and
/// pops are Core Animation layers (`BubbleCanvas`), so this view is rebuilt only when the toast changes —
/// never per frame.
struct BubbleScene: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.clear
                if let toast = model.toast {
                    ToastView(toast: toast) { action in model.runToastAction(action) }
                        .fixedSize()
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { model.toastFrame = $0 }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, model.toastBottom)
                        .transition(.opacity.combined(with: .offset(y: 8)))
                        .id(toast.id)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.easeOut(duration: 0.3), value: model.toast?.id)
        }
        .ignoresSafeArea()
    }
}
