import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: RecordingController
    let transcriptions: TranscriptionController
    private var terminationReplyPending = false

    override init() {
        let transcriptions = TranscriptionController()
        self.transcriptions = transcriptions
        controller = RecordingController(transcriptions: transcriptions)
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        Task { @MainActor [weak self] in
            await self?.transcriptions.bootstrap()
            await self?.controller.bootstrap()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationReplyPending else { return .terminateCancel }

        terminationReplyPending = true
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            await transcriptions.prepareForTermination()
            let shouldTerminate = await controller.finishForTermination()
            await transcriptions.prepareForTermination()
            if !shouldTerminate {
                transcriptions.cancelTermination()
            }
            terminationReplyPending = false
            sender?.reply(toApplicationShouldTerminate: shouldTerminate)
        }
        return .terminateLater
    }
}
