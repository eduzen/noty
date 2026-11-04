import SwiftUI

struct MainWindowView: View {
    @ObservedObject var controller: RecordingController
    @ObservedObject var transcriptions: TranscriptionController
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            recordingControls
            if let issue = controller.latestIssue {
                issueView(issue)
            }
            RecoveredRecordingsView(controller: controller)
            TranscriptionView(controller: transcriptions)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Settings", systemImage: "gearshape") { openSettings() }
                    .help("Settings (⌘,)")
            }
        }
    }

    private var recordingControls: some View {
        GroupBox {
            HStack(spacing: 14) {
                RecordingStatusView(state: controller.state, elapsedDuration: controller.elapsedDuration)
                Text(RecordingStatusView.formatDuration(controller.elapsedDuration))
                    .font(.title2.monospacedDigit())
                    .contentTransition(.numericText())
                Spacer(minLength: 12)
                controlButtons
            }
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
            .padding(12)
            .background {
                // Size the waveform from the full padded box, independently of the controls.
                if controller.hasActiveRecording {
                    RecordingWaveformView(
                        level: controller.audioLevel,
                        isLive: controller.state == .recording
                    )
                    .padding(6)
                    .opacity(0.35)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private var controlButtons: some View {
        HStack(spacing: 8) {
            if controller.hasActiveRecording {
                if controller.state == .paused {
                    Button("Resume", systemImage: "play.fill") { controller.resume() }
                        .disabled(!controller.canResume)
                } else {
                    Button("Pause", systemImage: "pause.fill") { controller.pause() }
                        .disabled(!controller.canPause)
                }
                Button("Stop", systemImage: "stop.fill") {
                    Task { await controller.stop() }
                }
                .disabled(!controller.canStop)
            } else {
                Button("Record", systemImage: "record.circle.fill") {
                    Task { await controller.start() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(!controller.canStart)
            }
        }
        .controlSize(.large)
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
