import Foundation

/// Turns a meeting title into a file-name stem that is safe on macOS, or nil if nothing usable remains.
enum MeetingFileName {
    static let maximumLength = 80
    private static let reservedCharacters: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]

    static func stem(from title: String?) -> String? {
        guard let title else { return nil }
        var cleaned = ""
        for character in title {
            let isControl = character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            cleaned.append(isControl || reservedCharacters.contains(character) ? " " : character)
        }
        let words = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let limited = String(words.prefix(maximumLength))
        let stem = limited.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return stem.isEmpty ? nil : stem
    }
}
