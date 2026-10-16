import SwiftUI

struct ApplicationRootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var startup: StartupCoordinator

    var body: some View {
        Group {
            if startup.isReady {
                ListenerView(model: model)
            } else {
                StartupView(model: model, startup: startup)
            }
        }
        .frame(
            minWidth: startup.isReady ? ApplicationWindows.libraryMinimum.width : ApplicationWindows.startupSize.width,
            minHeight: startup.isReady
                ? ApplicationWindows.libraryMinimum.height : ApplicationWindows.startupSize.height
        )
        .weijiAccent()
    }
}
