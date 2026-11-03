import SwiftUI

@main
struct NotyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("Noty", id: "main") {
            MainWindowView(controller: appDelegate.controller, transcriptions: appDelegate.transcriptions,
                           showMenuBarIcon: $showMenuBarIcon)
                .frame(minWidth: 480, minHeight: 540)
        }
        .defaultSize(width: 560, height: 620)

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView(controller: appDelegate.controller, transcriptions: appDelegate.transcriptions)
        } label: {
            RecordingStatusLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
