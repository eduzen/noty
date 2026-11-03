import Foundation
@testable import Noty
import Security
import XCTest

@MainActor
final class TranscriptionWorkerProcessTests: XCTestCase {
    func testBundledSignedWorkerReportsMissingModelsThroughProtocol() async throws {
        try skipWhenXcodeChangesInheritedWorkerEntitlements()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let worker = TranscriptionWorkerProcess()
        let request = TranscriptionWorkerRequest(jobID: UUID(), attemptID: UUID(), phase: .validate,
                                                 modelsURL: folder,
                                                 resultURL: folder.appendingPathComponent("result.json"),
                                                 parentPID: getpid())
        do {
            _ = try await worker.run(request) { _ in }
            XCTFail("Missing model assets must require repair")
        } catch let TranscriptionError.workerFailed(_, needsRepair) {
            XCTAssertTrue(needsRepair)
        }
        let result = try JSONDecoder().decode(TranscriptionWorkerResult.self,
                                              from: Data(contentsOf: request.resultURL))
        XCTAssertEqual(result.jobID, request.jobID)
        XCTAssertEqual(result.attemptID, request.attemptID)
        try await worker.stop()
    }

    private func skipWhenXcodeChangesInheritedWorkerEntitlements() throws {
        let url = try XCTUnwrap(Bundle.main.url(forAuxiliaryExecutable: "NotyTranscriptionWorker"))
        var code: SecStaticCode?
        XCTAssertEqual(SecStaticCodeCreateWithPath(url as CFURL, [], &code), errSecSuccess)
        let signedCode = try XCTUnwrap(code)
        var information: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(
            signedCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information
        ), errSecSuccess)
        let signature = try XCTUnwrap(information as? [String: Any])
        let entitlements = try XCTUnwrap(signature[kSecCodeInfoEntitlementsDict as String] as? [String: Any])
        let testServices = Set([
            "com.apple.testmanagerd", "com.apple.dt.testmanagerd.runner", "com.apple.coresymbolicationd"
        ])
        let injectedServices = Set(entitlements[
            "com.apple.security.temporary-exception.mach-lookup.global-name"
        ] as? [String] ?? [])
        let injectedPaths = entitlements[
            "com.apple.security.temporary-exception.files.absolute-path.read-only"
        ] as? [String]
        if entitlements["com.apple.security.inherit"] as? Bool == true,
           injectedPaths == ["/"], injectedServices == testServices {
            throw XCTSkip("Xcode injects test sandbox exceptions into the inherited helper, which macOS rejects. " +
                "Run docs/verification/WorkerSandboxProbe/check.sh against a normal build for this integration check.")
        }
    }
}
