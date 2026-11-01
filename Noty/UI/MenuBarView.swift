import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        if showsWarning {
            Label(statusTitle, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(statusTitle)
        }
        Text("Recording folder: \(destinationName)")
            .font(.caption)
            .foregroundStyle(.secondary)
            .help(controller.destinationDisplayPath)

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
            Label(issueSummary(issue), systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .help(issue.message)
            if let recoveryURL = issue.recoveryURL {
                Button(recoveryURL.isFileURL ? "Show Recovery in Finder" : "Open System Settings") {
                    if recoveryURL.isFileURL {
                        NSWorkspace.shared.activateFileViewerSelecting([recoveryURL])
                    } else {
                        NSWorkspace.shared.open(recoveryURL)
                    }
                }
            }
            Button("Details…") {
                showDetails(issue)
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

    private var destinationName: String {
        guard let url = controller.currentDestinationURL else { return "Noty" }
        let components = url.standardizedFileURL.pathComponents
        let name = url.lastPathComponent
        let label: String
        if components.count > 3, components[1] == "Volumes" {
            label = "\(components[2]) › \(name)"
        } else {
            label = name
        }
        // Native menus size themselves to their text, so bound unusually long folder names too.
        guard label.count > 40 else { return label }
        return "\(label.prefix(19))…\(label.suffix(20))"
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
        alert.alertStyle = .warning
        alert.messageText = issueSummary(issue)
        var details = issue.message
        if let url = issue.recoveryURL, url.isFileURL, !details.contains(url.path) {
            details += "\n\nRecovery file: \(url.path)"
        }
        alert.informativeText = details
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
