import AppKit
@testable import Noty
import SwiftUI
import XCTest

@MainActor
final class PlaybackRowProgressTests: XCTestCase {
    func testRecordingsTableShowsUnderlineAcrossNativeRowWithoutExtraColumn() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = folder.appendingPathComponent("Meeting.m4a")
        try Data("fixture".utf8).write(to: audio)
        let playback = AudioPlaybackController(makePlayer: { _ in PlaybackTestPlayer() })
        let controller = TranscriptionController(store: TranscriptionFileStore(rootURL: folder), playback: playback)
        await controller.enqueue(sourceURL: audio, duration: 10, folderBookmark: nil)
        try controller.togglePlayback(XCTUnwrap(controller.jobs.first))
        playback.seek(to: 2.5)
        defer { playback.stop() }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: TranscriptionView(controller: controller))
        window.contentView = host

        var underline: PlaybackProgressUnderline?
        for _ in 0 ..< 50 {
            host.layoutSubtreeIfNeeded()
            underline = descendants(of: host).compactMap { $0 as? PlaybackProgressUnderline }.first
            if underline != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        let table = try XCTUnwrap(descendants(of: host).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.tableColumns.map(\.headerCell.stringValue),
                       ["Name", "Date", "Duration", "Status", "Actions"])
        let line = try XCTUnwrap(underline)
        let row = try XCTUnwrap(line.superview as? NSTableRowView)
        XCTAssertEqual(line.frame.width, row.bounds.width)
        XCTAssertEqual(line.fillRect.width, row.bounds.width * 0.25, accuracy: 0.01)
    }

    func testUnderlineSpansTheRowAndGrowsWithPlayback() throws {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        let cell = NSView(frame: NSRect(x: 10, y: 0, width: 160, height: 40))
        let attachment = PlaybackProgressAttachment(frame: cell.bounds)
        row.addSubview(cell)
        cell.addSubview(attachment)

        attachment.progress = 0.25
        let underline = try XCTUnwrap(row.subviews.compactMap { $0 as? PlaybackProgressUnderline }.first)
        XCTAssertEqual(underline.frame, row.bounds)
        XCTAssertEqual(underline.fillRect.width, 150)
        XCTAssertEqual(underline.fillRect.height, 2)
        XCTAssertEqual(underline.fillRect.maxY, row.bounds.maxY)

        attachment.progress = 0.75
        XCTAssertEqual(underline.fillRect.width, 450)
        XCTAssertNil(underline.hitTest(NSPoint(x: 30, y: 39)))

        attachment.progress = nil
        XCTAssertNil(underline.superview)
    }

    func testMovingToAnotherRowRemovesTheOldUnderline() throws {
        let firstRow = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 40))
        let secondRow = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 800, height: 40))
        let attachment = PlaybackProgressAttachment(frame: .zero)
        attachment.progress = 0.5
        firstRow.addSubview(attachment)
        let underline = try XCTUnwrap(firstRow.subviews.compactMap { $0 as? PlaybackProgressUnderline }.first)

        secondRow.addSubview(attachment)
        XCTAssertTrue(underline.superview === secondRow)
        XCTAssertEqual(underline.fillRect.width, 400)
        XCTAssertFalse(firstRow.subviews.contains(underline))

        attachment.detachUnderline()
        XCTAssertNil(underline.superview)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
