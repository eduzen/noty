import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        Text(RecordingStatusView.accessibleLabel(for: controller.state, elapsedDuration: controller.elapsedDuration))
        Text("Recording folder")
            .font(.caption)
            .foregroundStyle(.secondary)
        Text(controller.destinationDisplayPath)
            .font(.caption2)
            .lineLimit(2)

        Divider()

        Button {
            Task { await controller.start() }
        } label: {
            Label("Start Recording", systemImage: "record.circle")
        }
        .disabled(!controller.canStart)

        Button {
            Task { await controller.stop() }
        } label: {
            Label("Stop Recording", systemImage: "stop.circle")
        }
        .disabled(!controller.canStop)

        Button {
            controller.chooseDestination()
        } label: {
            Label("Choose Recording Folder…", systemImage: "folder")
        }
        .disabled(!controller.canChooseDestination)

        Button {
            controller.revealLastRecordingInFinder()
        } label: {
            Label("Show Last Recording in Finder", systemImage: "arrow.up.forward.app")
        }
        .disabled(controller.lastArtifact == nil)

        if let issue = controller.latestIssue {
            Divider()
            Text(issue.message)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let recoveryURL = issue.recoveryURL {
                Button(recoveryURL.isFileURL ? "Show Recovery in Finder" : "Open System Settings") {
                    if recoveryURL.isFileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                    } else {
                        NSWorkspace.shared.open(recoveryURL)
                    }
                }
            }
        }

        Divider()
        Button("Quit Noty") { NSApp.terminate(nil) }
    }
}
