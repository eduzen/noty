import AppKit
import SwiftUI

/// Attaches to the native row so the underline spans every column and follows sorting and scrolling.
struct PlaybackRowProgress: NSViewRepresentable {
    let progress: Double?

    func makeNSView(context _: Context) -> PlaybackProgressAttachment {
        PlaybackProgressAttachment(frame: .zero)
    }

    func updateNSView(_ view: PlaybackProgressAttachment, context _: Context) {
        view.progress = progress
    }

    static func dismantleNSView(_ view: PlaybackProgressAttachment, coordinator _: ()) {
        view.detachUnderline()
    }
}

final class PlaybackProgressAttachment: NSView {
    var progress: Double? {
        didSet { updateUnderline() }
    }

    private let underline = PlaybackProgressUnderline(frame: .zero)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        updateUnderline()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateUnderline()
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    func detachUnderline() {
        underline.removeFromSuperview()
    }

    private func updateUnderline() {
        guard let progress, progress.isFinite,
              let row = sequence(first: self as NSView, next: { $0.superview })
                  .compactMap({ $0 as? NSTableRowView }).first else {
            detachUnderline()
            return
        }

        underline.progress = min(max(progress, 0), 1)
        underline.frame = row.bounds
        underline.autoresizingMask = [.width, .height]
        if underline.superview !== row {
            underline.removeFromSuperview()
            row.addSubview(underline, positioned: .above, relativeTo: nil)
        }
        underline.needsDisplay = true
    }
}

final class PlaybackProgressUnderline: NSView {
    var progress: Double = 0

    override var isFlipped: Bool {
        true
    }

    var fillRect: NSRect {
        NSRect(x: 0, y: bounds.height - 2, width: bounds.width * progress, height: 2)
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func draw(_: NSRect) {
        NSColor.controlAccentColor.setFill()
        NSBezierPath(rect: fillRect).fill()
    }
}
