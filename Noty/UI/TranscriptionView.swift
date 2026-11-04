import SwiftUI

struct TranscriptionView: View {
    @ObservedObject var controller: TranscriptionController
    @State private var isImporting = false
    @State private var sortOrder = [KeyPathComparator(\TranscriptionJob.identity.modified, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recordings")
                    .font(.headline)
                Spacer()
                Button("Import Audio…", systemImage: "waveform.badge.plus") {
                    isImporting = true
                    Task { @MainActor in
                        defer { isImporting = false }
                        await controller.importAudio()
                    }
                }
                .disabled(!controller.canImport || isImporting)
            }

            if controller.modelState != .ready {
                Label("Download speech models in Settings to transcribe recordings.", systemImage: "arrow.down.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            table
        }
    }

    private var table: some View {
        Table(controller.jobs.sorted(using: sortOrder), sortOrder: $sortOrder) {
            TableColumn("Name", value: \.displayName) { job in
                Text(job.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(job.sourceURL.path)
            }
            .width(min: 160, ideal: 240)

            TableColumn("Date", value: \.identity.modified) { job in
                Text(job.identity.modified.formatted(date: .abbreviated, time: .shortened))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)

            TableColumn("Duration", value: \.duration) { job in
                Text(RecordingStatusView.formatDuration(job.duration))
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 80)

            TableColumn("Status") { job in
                TranscriptionStatusCell(controller: controller, job: job)
            }
            .width(min: 140, ideal: 170)

            TableColumn("Actions") { job in
                TranscriptionActionsCell(controller: controller, job: job)
            }
            .width(min: 110, ideal: 120)
        }
        .frame(minHeight: 200)
        .overlay {
            if controller.jobs.isEmpty {
                Text("Recordings and imported audio appear here.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct TranscriptionStatusCell: View {
    @ObservedObject var controller: TranscriptionController
    let job: TranscriptionJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if job.status.isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(statusTitle)
                    .foregroundStyle(job.status == .needsAttention ? Color.orange : Color.secondary)
            }
            if job.status.isRunning, let message = controller.progressMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if job.status == .needsAttention, let message = job.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .help(job.message ?? statusTitle)
    }

    private var statusTitle: String {
        guard job.status == .waiting else { return job.status.title }
        if controller.modelState != .ready {
            return "Waiting for speech models"
        }
        return controller.isRecording ? "Waiting for recording to finish" : job.status.title
    }
}

private struct TranscriptionActionsCell: View {
    @ObservedObject var controller: TranscriptionController
    let job: TranscriptionJob

    var body: some View {
        HStack(spacing: 12) {
            if job.lastExport != nil {
                Button {
                    controller.openTranscript(job)
                } label: {
                    Image(systemName: "doc.text")
                }
                .help("Open Transcript")
                .accessibilityLabel("Open transcript")

                Button {
                    controller.revealTranscript(job)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Show Transcript in Finder")
                .accessibilityLabel("Show transcript in Finder")
            }
            if job.canRetry {
                Button {
                    controller.retry(job.id)
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help(job.lastExport == nil ? "Retry" : "Retry Speaker Labels")
                .disabled(!controller.canImport)
                .accessibilityLabel(job.lastExport == nil ? "Retry" : "Retry speaker labels")
            }
            if job.canCancel {
                Button {
                    Task { await controller.cancel(job.id) }
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .help("Cancel")
                .accessibilityLabel("Cancel")
            }
        }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
    }
}
