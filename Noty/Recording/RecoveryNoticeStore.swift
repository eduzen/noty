import Foundation

protocol RecoveryNoticeStoring {
    func isAcknowledged(_ identifier: String) -> Bool
    func acknowledge(_ identifier: String)
}

/// Remembers handled sessions without removing any recovered audio.
struct RecoveryNoticeStore: RecoveryNoticeStoring {
    private static let lock = NSLock()
    private let defaults: UserDefaults
    private let key = "acknowledgedRecoverySessions"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isAcknowledged(_ identifier: String) -> Bool {
        (defaults.stringArray(forKey: key) ?? []).contains(identifier)
    }

    func acknowledge(_ identifier: String) {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        var identifiers = defaults.stringArray(forKey: key) ?? []
        guard !identifiers.contains(identifier) else { return }
        identifiers.append(identifier)
        defaults.set(identifiers, forKey: key)
    }
}
