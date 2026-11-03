import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: RecordingController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if showsWarning {
            Label(statusTitle, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(statusTitle)
        }

        Divider()

        Button("Open Noty…", systemImage: "macwindow") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }

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
            Label(
                issueSummary(issue),
                systemImage: issue.code == "recording.recovery-found" ? "info.circle" : "exclamationmark.triangle.fill"
            )
            .font(.caption)
            .help(issue.message)
            if let recoveryURL = issue.recoveryURL {
                Button {
                    controller.openIssueAction(issue)
                } label: {
                    Label(
                        recoveryURL.isFileURL ? "Show Recording in Finder" : "Open System Settings",
                        systemImage: recoveryURL.isFileURL ? "arrow.up.forward.app" : "gearshape"
                    )
                }
            }
            Button {
                showDetails(issue)
            } label: {
                Label("Details…", systemImage: "info.circle")
            }
        }

        if !controller.recoveredRecordings.isEmpty {
            Divider()
            Menu("Recovered Recordings") {
                ForEach(controller.recoveredRecordings, id: \.recoveryIdentifier) { artifact in
                    Menu(artifact.displayName) {
                        Text(
                            "\(artifact.fileCountDescription) · "
                                + "\(RecordingStatusView.formatDuration(artifact.duration))"
                        )
                        Button("Show Audio in Finder") { controller.revealRecordingInFinder(artifact) }
                        Button("Dismiss Notice") { controller.dismissRecovery(artifact) }
                    }
                }
            }
        }

        Divider()
        Button("Quit Noty") { NSApp.terminate(nil) }
    }

    private var showsWarning: Bool {
        controller.state == .interrupted || controller.state == .failed
    }

    private var statusTitle: String {
        switch controller.state {
        case .idle: "Ready to record"
        case .starting: "Starting recording…"
        case .recording: "Recording · \(RecordingStatusView.formatDuration(controller.elapsedDuration))"
        case .stopping: "Finishing recording…"
        case .interrupted: "Recording interrupted"
        case .failed: "Recording failed"
        }
    }

    private func issueSummary(_ issue: RecordingIssue) -> String {
        switch issue.code {
        case "recording.recovery-found": "Partial recording available"
        case "capture.system-audio-silent": "No system audio detected"
        default: "Recording needs attention"
        }
    }

    private func showDetails(_ issue: RecordingIssue) {
        let alert = NSAlert()
        alert.alertStyle = issue.code == "recording.recovery-found" ? .informational : .warning
        alert.messageText = issueSummary(issue)
        alert.informativeText = issue.message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
