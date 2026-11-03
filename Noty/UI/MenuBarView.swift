import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var transcriptions: TranscriptionController
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

        if transcriptions.modelState != .notInstalled || !transcriptions.jobs.isEmpty || transcriptions.issue != nil {
            Divider()
            Label(transcriptionSummary, systemImage: "text.bubble")
                .font(.caption)
            Button("Transcription Details…") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        Divider()
        Button("Quit Noty") { NSApp.terminate(nil) }
    }

    private var showsWarning: Bool {
        controller.state == .interrupted || controller.state == .failed
    }

    private var transcriptionSummary: String {
        if transcriptions.modelState == .preparing {
            return "Preparing transcription models…"
        }
        if transcriptions.modelState == .needsRepair {
            return "Transcription models need repair"
        }
        let pending = transcriptions.jobs.filter(\.canCancel)
        if transcriptions.isRecording, !pending.isEmpty {
            return "Transcription paused while recording"
        }
        if let running = pending.first(where: { $0.status.isRunning }) {
            return "\(running.status.title)…"
        }
        if !pending.isEmpty {
            return pending.count == 1 ? "1 transcription waiting" : "\(pending.count) transcriptions waiting"
        }
        if transcriptions.issue != nil || transcriptions.jobs.contains(where: { $0.status == .needsAttention }) {
            return "Transcription needs attention"
        }
        return "Transcription ready"
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
