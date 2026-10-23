import SwiftUI

@main
struct NotyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: appDelegate.controller)
        } label: {
            RecordingStatusView(
                state: appDelegate.controller.state,
                elapsedDuration: appDelegate.controller.elapsedDuration,
                compact: true
            )
        }
        .menuBarExtraStyle(.menu)
    }
}
