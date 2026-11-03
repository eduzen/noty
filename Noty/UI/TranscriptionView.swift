import SwiftUI

struct TranscriptionView: View {
    @ObservedObject var controller: TranscriptionController
    @State private var isImporting = false

    var body: some View {
        GroupBox("Transcription") {
            VStack(alignment: .leading, spacing: 16) {
                Text("English transcripts with Speaker 1, Speaker 2 labels, processed on this Mac.")
                    .font(.callout)
                Text("Speaker labels support recordings up to two hours. Longer audio receives text only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                modelSetup

                Toggle("Automatically transcribe new recordings", isOn: Binding(
                    get: { controller.automaticEnabled },
                    set: { controller.setAutomaticEnabled($0) }
                ))
                .disabled(controller.modelState != .ready)

                Button("Import Audio…", systemImage: "waveform.badge.plus") {
                    isImporting = true
                    Task { @MainActor in
                        defer { isImporting = false }
                        await controller.importAudio()
                    }
                }
                .disabled(!controller.canImport || isImporting)

                if let issue = controller.issue {
                    Label(issue, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if controller.isRecording, controller.jobs.contains(where: \.canCancel) {
                    Text("Transcription will resume after recording stops.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ForEach(controller.jobs.reversed()) { job in
                    Divider()
                    TranscriptionJobView(controller: controller, job: job)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var modelSetup: some View {
        switch controller.modelState {
        case .notInstalled:
            Text("Download the speech models once to get started. Your audio stays on this Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Download and Enable", systemImage: "arrow.down.circle") { controller.prepareModels() }
                .disabled(!controller.canPrepareModels)
        case .preparing:
            ProgressView(value: controller.progress) {
                Text(controller.progressMessage ?? "Preparing speech models…")
            }
            Button("Cancel Download") { Task { await controller.cancelModelPreparation() } }
        case .ready:
            Label("Speech models ready", systemImage: "checkmark.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .needsRepair:
            Text("The speech models need repair before transcription can continue.")
                .font(.callout)
            Button("Repair Models", systemImage: "arrow.clockwise") { controller.prepareModels() }
                .disabled(!controller.canPrepareModels)
        }
    }
}

private struct TranscriptionJobView: View {
    @ObservedObject var controller: TranscriptionController
    let job: TranscriptionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.displayName)
                .font(.headline)
                .textSelection(.enabled)
                .lineLimit(2)
            Text("\(statusTitle) · \(RecordingStatusView.formatDuration(job.duration))")
                .font(.caption)
                .foregroundStyle(.secondary)

            if job.status.isRunning {
                ProgressView(value: controller.progress)
                    .accessibilityLabel(statusTitle)
                if let message = controller.progressMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let message = job.message {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(job.status == .needsAttention ? Color.orange : Color.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
                if job.lastExport != nil {
                    Button("Open Transcript") { controller.openTranscript(job) }
                    Button("Show in Finder") { controller.revealTranscript(job) }
                }
                if job.canRetry {
                    Button(job.lastExport == nil ? "Retry" : "Retry Speaker Labels") { controller.retry(job.id) }
                        .disabled(!controller.canImport)
                }
                if job.canCancel {
                    Button("Cancel") { Task { await controller.cancel(job.id) } }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusTitle: String {
        guard job.status == .waiting else { return job.status.title }
        if controller.modelState != .ready {
            return "Waiting for speech models"
        }
        return controller.isRecording ? "Waiting for recording to finish" : job.status.title
    }
}
