import AppKit
import SwiftUI

struct MainWindowView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var transcriptions: TranscriptionController
    @Binding var showMenuBarIcon: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                recordingControls
                if let issue = controller.latestIssue {
                    issueView(issue)
                }
                RecoveredRecordingsView(controller: controller)
                settings
                lastRecording
                TranscriptionView(controller: transcriptions)
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Noty")
                    .font(.largeTitle.bold())
                Text("Record system audio and your microphone.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var recordingControls: some View {
        GroupBox {
            VStack(spacing: 18) {
                RecordingStatusView(state: controller.state, elapsedDuration: controller.elapsedDuration)
                Text(RecordingStatusView.formatDuration(controller.elapsedDuration))
                    .font(.system(size: 44, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                HStack(spacing: 12) {
                    Button("Start Recording", systemImage: "record.circle") {
                        Task { await controller.start() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.canStart)

                    Button("Stop", systemImage: "stop.fill") {
                        Task { await controller.stop() }
                    }
                    .disabled(!controller.canStop)
                }
                .controlSize(.large)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
        }
    }

    private var settings: some View {
        GroupBox("Settings") {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Recording folder", systemImage: "folder")
                        .font(.headline)
                    Text(controller.destinationDisplayPath)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Choose Folder…") { controller.chooseDestination() }
                        .disabled(!controller.canChooseDestination)
                }
                Divider()
                Toggle("Show Noty in the menu bar", isOn: $showMenuBarIcon)
                Text("You can always reopen this window from the Dock. Closing it keeps Noty running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var lastRecording: some View {
        if let artifact = controller.lastArtifact {
            GroupBox("Last recording") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(artifact.displayName)
                            .lineLimit(2)
                        Text("Show the saved file in Finder.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { controller.revealLastRecordingInFinder() }
                }
                .padding(12)
            }
        }
    }

    private func issueView(_ issue: RecordingIssue) -> some View {
        let isRecoveryNotice = issue.code == "recording.recovery-found"
        return GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                Label(
                    isRecoveryNotice ? "Partial recording available" : "Recording needs attention",
                    systemImage: isRecoveryNotice ? "info.circle" : "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(isRecoveryNotice ? Color.secondary : .orange)
                Text(issue.message)
                    .font(.callout)
                    .textSelection(.enabled)
                if let url = issue.recoveryURL {
                    Button(url.isFileURL ? "Show Recording in Finder" : "Open System Settings") {
                        controller.openIssueAction(issue)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
