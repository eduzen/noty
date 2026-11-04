import SwiftUI

/// Scrolling bars driven by live input level while a recording is active.
struct RecordingWaveformView: View {
    var level: Double
    var isLive: Bool

    private static let barCount = 96
    private static let idleBar: CGFloat = 0.08

    @State private var bars = Array(repeating: idleBar, count: barCount)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !isLive)) { timeline in
            Canvas { context, size in
                let spacing: CGFloat = 2
                let barWidth = max(
                    1.5,
                    (size.width - spacing * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount)
                )
                let midY = size.height / 2
                for (index, value) in bars.enumerated() {
                    let height = max(2.5, value * size.height)
                    let rect = CGRect(
                        x: CGFloat(index) * (barWidth + spacing),
                        y: midY - height / 2,
                        width: barWidth,
                        height: height
                    )
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(Color.accentColor.opacity(0.9))
                    )
                }
            }
            .onChange(of: timeline.date) { _, date in
                guard isLive else { return }
                bars.removeFirst()
                bars.append(Self.barHeight(for: level, at: date))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityHidden(true)
        .onChange(of: isLive) { _, live in
            if !live {
                bars = Array(repeating: Self.idleBar, count: Self.barCount)
            }
        }
    }

    /// Softens linear peaks for display and keeps a faint shimmer when quiet.
    static func barHeight(for level: Double, at date: Date) -> CGFloat {
        let shimmer = 0.05 + 0.04 * (0.5 + 0.5 * sin(date.timeIntervalSinceReferenceDate * 9))
        let shaped = min(1, pow(max(0, level), 0.5) * 1.65)
        return CGFloat(max(shimmer, shaped))
    }
}
