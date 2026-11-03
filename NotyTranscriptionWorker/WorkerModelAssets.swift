import Foundation

struct WorkerAssetManifest: Codable {
    var schemaVersion = 1
    var model = "openai_whisper-large-v3-v20240930_626MB"
    var sdk = "1.1.1"
    var setID: UUID
}

struct WorkerAssetLocations {
    let root: URL
    var whisper: URL {
        root.appendingPathComponent("whisper")
    }

    var tokenizer: URL {
        root.appendingPathComponent("tokenizer")
    }

    var speakers: URL {
        root.appendingPathComponent("speakers")
    }

    static func current(at modelsURL: URL) throws -> WorkerAssetLocations {
        do {
            let manifest = try JSONDecoder().decode(
                WorkerAssetManifest.self,
                from: Data(contentsOf: modelsURL.appendingPathComponent("current.json"))
            )
            guard manifest.schemaVersion == 1,
                  manifest.sdk == "1.1.1",
                  manifest.model == "openai_whisper-large-v3-v20240930_626MB"
            else { throw WorkerFailure.modelNeedsRepair }
            let locations = WorkerAssetLocations(
                root: modelsURL.appendingPathComponent("sets").appendingPathComponent(manifest.setID.uuidString)
            )
            for folder in [locations.whisper, locations.tokenizer, locations.speakers] {
                let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw WorkerFailure.modelNeedsRepair
                }
            }
            return locations
        } catch { throw WorkerFailure.modelNeedsRepair }
    }

    static func beginPreparation(at modelsURL: URL, setID: UUID) throws -> WorkerAssetLocations {
        let setsURL = modelsURL.appendingPathComponent("sets")
        try FileManager.default.createDirectory(at: setsURL, withIntermediateDirectories: true)
        for url in try FileManager.default.contentsOfDirectory(at: setsURL, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix(".preparing-") {
            try FileManager.default.removeItem(at: url)
        }
        let root = setsURL.appendingPathComponent(".preparing-" + setID.uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return WorkerAssetLocations(root: root)
    }

    func publish(at modelsURL: URL, setID: UUID) throws {
        let target = modelsURL.appendingPathComponent("sets").appendingPathComponent(setID.uuidString)
        try FileManager.default.moveItem(at: root, to: target)
        try JSONEncoder().encode(WorkerAssetManifest(setID: setID))
            .write(to: modelsURL.appendingPathComponent("current.json"), options: .atomic)
        // Keep the selected set only; these folders contain exclusively app-owned downloaded assets.
        for url in try FileManager.default.contentsOfDirectory(
            at: target.deletingLastPathComponent(), includingPropertiesForKeys: nil
        ) where url.lastPathComponent != target.lastPathComponent && UUID(uuidString: url.lastPathComponent) != nil {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
