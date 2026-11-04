import SwiftUI

struct RecoveredRecordingsView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        if !controller.recoveredRecordings.isEmpty {
            GroupBox("Recovered recordings") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("These recordings may be incomplete. Dismissing a notice keeps the files.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(controller.recoveredRecordings, id: \.recoveryIdentifier) { artifact in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artifact.displayName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("\(artifact.fileCountDescription) · "
                                    + "\(RecordingStatusView.formatDuration(artifact.duration)) available")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Button {
                                controller.revealRecordingInFinder(artifact)
                            } label: {
                                Image(systemName: "folder")
                            }
                            .help("Show Audio in Finder")
                            .accessibilityLabel("Show audio in Finder")
                            Button {
                                controller.dismissRecovery(artifact)
                            } label: {
                                Image(systemName: "xmark.circle")
                            }
                            .help("Dismiss Notice")
                            .accessibilityLabel("Dismiss notice")
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
        }
    }
}
