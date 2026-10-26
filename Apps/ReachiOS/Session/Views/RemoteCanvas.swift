import SwiftUI

/// SwiftUI bridge for the UIKit/Metal canvas. Settings and session phase flow in through
/// `updateUIView`; everything latency-sensitive stays inside UIKit.
struct RemoteCanvas: UIViewRepresentable {
    let controller: SessionController
    var config: GestureEngine.Config
    var dimmed: Bool
    var accessoryHeight: CGFloat

    func makeUIView(context: Context) -> RemoteScreenView {
        RemoteScreenView(controller: controller)
    }

    func updateUIView(_ view: RemoteScreenView, context: Context) {
        view.apply(config: config, dimmed: dimmed, accessoryHeight: accessoryHeight)
    }
}
