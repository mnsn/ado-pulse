import Foundation
import Testing

/// The tests leave nothing behind: a UserDefaults suite leaves a file in ~/Library/Preferences, even once its domain is
/// removed, so they keep preferences in `MemoryDefaults`.
@Suite struct MemoryDefaultsTests {
    @Test func keepsEverythingInMemory() throws {
        let key = "ADOPulseTests-\(UUID().uuidString)"
        let defaults = MemoryDefaults()
        // The typed setters and getters that AppSettings uses go through it too.
        defaults.set(true, forKey: key + ".bool")
        defaults.set(7, forKey: key + ".int")
        defaults.set("made-up", forKey: key + ".string")
        defaults.set(["contoso"], forKey: key + ".strings")
        defaults.set(Data([1, 2]), forKey: key + ".data")
        #expect(defaults.bool(forKey: key + ".bool"))
        #expect(defaults.integer(forKey: key + ".int") == 7)
        #expect(defaults.string(forKey: key + ".string") == "made-up")
        #expect(defaults.stringArray(forKey: key + ".strings") == ["contoso"])
        #expect(defaults.data(forKey: key + ".data") == Data([1, 2]))
        #expect(defaults.stored.count == 5)
        // None of it reached the preferences of the process running the tests.
        for suffix in [".bool", ".int", ".string", ".strings", ".data"] {
            #expect(UserDefaults.standard.object(forKey: key + suffix) == nil, "\(suffix)")
        }

        defaults.removeObject(forKey: key + ".bool")
        #expect(!defaults.bool(forKey: key + ".bool"))
        #expect(defaults.stored.count == 4)

        // Launch arguments come first, and stay when a key is removed, as UserDefaults has it.
        let launched = MemoryDefaults(stored: ["switch": false], arguments: ["switch": true])
        #expect(launched.bool(forKey: "switch"))
        launched.removeObject(forKey: "switch")
        #expect(launched.bool(forKey: "switch"))
        #expect(launched.stored.isEmpty)
    }

    /// No test opens preferences of its own on disk, or changes the test process's.
    @Test func theTestsUseNoRealPreferences() throws {
        let preferences = try NSRegularExpression(pattern: [
            #"UserDefaults(\.init)?\s*\(\s*suiteName:"#,
            #"UserDefaults\.standard\.(set|remove|register)"#,
            #"(set|remove)(Persistent|Volatile)Domain\("#,
            #"\bCFPreferences(Set|Synchronize|AppSynchronize)"#,
        ].joined(separator: "|"))
        func opens(_ line: String) -> Bool {
            preferences.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }

        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let files = try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "MemoryDefaultsTests.swift" {
            scanned += 1
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where opens(line) {
                found.append("\(file.lastPathComponent):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(scanned > 10)
        #expect(found.isEmpty, "Keep the tests' preferences in MemoryDefaults: \(found.joined(separator: "; "))")

        // What it looks for, and what it doesn't.
        for line in ["UserDefaults(suiteName: suite)", "UserDefaults.init(suiteName: \"x\")", "UserDefaults.standard.set(true, forKey: k)",
                     "defaults.removePersistentDomain(forName: suite)", "UserDefaults.standard.setVolatileDomain(d, forName: n)"] {
            #expect(opens(line), "\(line)")
        }
        for line in ["super.init(suiteName: nil)!", "let defaults = MemoryDefaults()", "UserDefaults.standard.object(forKey: key)"] {
            #expect(!opens(line), "\(line)")
        }
    }
}
