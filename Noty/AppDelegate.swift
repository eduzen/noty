import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: RecordingController
    private var terminationReplyPending = false

    override init() {
        controller = RecordingController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor [weak self] in await self?.controller.bootstrap() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.hasActiveRecording else { return .terminateNow }
        guard !terminationReplyPending else { return .terminateCancel }

        terminationReplyPending = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let shouldTerminate = await controller.finishForTermination()
            terminationReplyPending = false
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
