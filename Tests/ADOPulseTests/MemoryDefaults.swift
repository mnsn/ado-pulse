import Foundation

/// Preferences kept in memory, for the tests: a UserDefaults suite leaves a file in ~/Library/Preferences, even once
/// its domain is removed. Every typed getter and setter goes through `object(forKey:)` and `set(_:forKey:)`.
final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    /// What a preferences file would hold: what any program running as you could read there.
    private(set) var stored: [String: Any]
    /// Stands for the launch arguments (`-key value`), which UserDefaults reads before the preferences, and which
    /// removing a key leaves alone.
    private let arguments: [String: Any]

    init(stored: [String: Any] = [:], arguments: [String: Any] = [:]) {
        self.stored = stored
        self.arguments = arguments
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        arguments[defaultName] ?? stored[defaultName]
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        stored[defaultName] = value
    }

    override func removeObject(forKey defaultName: String) {
        stored[defaultName] = nil
    }

    override func dictionaryRepresentation() -> [String: Any] {
        stored.merging(arguments) { _, argument in argument }
    }
}
