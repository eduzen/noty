import SwiftUI

@main
struct NotyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(controller: appDelegate.controller)
        } label: {
            RecordingStatusLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
