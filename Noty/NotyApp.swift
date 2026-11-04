import SwiftUI

@main
struct NotyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        Window("Noty", id: "main") {
            MainWindowView(controller: appDelegate.controller, transcriptions: appDelegate.transcriptions)
                .frame(minWidth: 620, minHeight: 540)
        }
        .defaultSize(width: 700, height: 620)

        Settings {
            SettingsView(
                controller: appDelegate.controller,
                transcriptions: appDelegate.transcriptions,
                showMenuBarIcon: $showMenuBarIcon
            )
        }

        MenuBarExtra(isInserted: $showMenuBarIcon) {
            MenuBarView(controller: appDelegate.controller, transcriptions: appDelegate.transcriptions)
        } label: {
            RecordingStatusLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}
