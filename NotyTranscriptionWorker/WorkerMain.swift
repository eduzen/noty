import Darwin
import Foundation

@main
struct NotyTranscriptionWorker {
    static func main() async {
        guard CommandLine.arguments.count == 2 else {
            WorkerRuntime.diagnostic("Usage: NotyTranscriptionWorker /path/to/request.json")
            Darwin.exit(EX_USAGE)
        }
        // Preserve the protocol stream, then redirect any third-party print() to diagnostics.
        let protocolDescriptor = dup(STDOUT_FILENO)
        guard protocolDescriptor >= 0, dup2(STDERR_FILENO, STDOUT_FILENO) >= 0 else {
            Darwin.exit(EX_OSERR)
        }
        let output = FileHandle(fileDescriptor: protocolDescriptor, closeOnDealloc: true)
        let emitter = WorkerProgressEmitter(output: output)
        let backend = WorkerBackend(progress: emitter)
        let requestURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let status = await WorkerRuntime.execute(requestAt: requestURL) { request in
            try await backend.perform(request)
        }
        Darwin.exit(status)
    }
}
