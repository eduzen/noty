import SwiftUI

struct RecordingStatusView: View {
    let state: RecordingState
    let elapsedDuration: TimeInterval
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbolName)
                .foregroundStyle(tint)
            if compact {
                Text(state == .recording ? "Noty \(Self.formatDuration(elapsedDuration))" : "Noty")
            } else {
                Text(Self.accessibleLabel(for: state, elapsedDuration: elapsedDuration))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibleLabel(for: state, elapsedDuration: elapsedDuration))
    }

    static func accessibleLabel(for state: RecordingState, elapsedDuration: TimeInterval) -> String {
        switch state {
        case .idle: "Noty is idle"
        case .starting: "Noty is starting a recording"
        case .recording: "Noty is recording, elapsed time \(formatDuration(elapsedDuration))"
        case .stopping: "Noty is finalizing the recording"
        case .interrupted: "Noty recording was interrupted"
        case .failed: "Noty recording failed"
        }
    }

    static func formatDuration(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainder = seconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
            : String(format: "%02d:%02d", minutes, remainder)
    }

    private var symbolName: String {
        switch state {
        case .idle: "waveform"
        case .starting: "hourglass"
        case .recording: "record.circle.fill"
        case .stopping: "stop.circle"
        case .interrupted: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .recording: .red
        case .interrupted, .failed: .orange
        default: .primary
        }
    }
}
