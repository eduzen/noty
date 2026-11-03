import SwiftUI

struct RecoveredRecordingsView: View {
    @ObservedObject var controller: RecordingController

    var body: some View {
        if !controller.recoveredRecordings.isEmpty {
            GroupBox("Recovered recordings") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("These recordings may be incomplete. All available audio files are kept together. "
                        + "Dismissing a notice keeps the files.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    ForEach(controller.recoveredRecordings, id: \.recoveryIdentifier) { artifact in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(artifact.displayName)
                                .font(.headline)
                            Text("\(artifact.fileCountDescription) · "
                                + "\(RecordingStatusView.formatDuration(artifact.duration)) available")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Show Audio in Finder") { controller.revealRecordingInFinder(artifact) }
                                Button("Dismiss Notice") { controller.dismissRecovery(artifact) }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
        }
    }
}
