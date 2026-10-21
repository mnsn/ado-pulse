import ADOPulseCore
import Combine
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Short summaries written on this Mac by Apple Intelligence's on-device model. Nothing leaves the Mac:
/// it uses only the on-device system model, never Private Cloud Compute or any other model. Each
/// summary is about one item, which the app picked: the model words things, it doesn't decide what matters.
@MainActor
final class Summarizer: ObservableObject {
    struct Request: Hashable, Sendable {
        var prompt: String
        var instructions: String
    }

    @Published private(set) var results: [Request: String] = [:]
    private var failed: Set<Request> = []
    private var queue: [Request] = []
    private var isWorking = false
    /// Off when the setting is off: nothing new is asked for, and the views show plain text.
    var isEnabled = true

    /// Whether the on-device model can be used on this Mac right now.
    var isAvailable: Bool { Self.modelIsAvailable() }

    func text(for request: Request) -> String? {
        isEnabled ? results[request] : nil
    }

    /// Asks for a summary unless it's known or underway; `results` changes when it arrives.
    func request(_ request: Request) {
        guard isEnabled, results[request] == nil, !failed.contains(request), !queue.contains(request), isAvailable else { return }
        // The newest asks first: they're what's on screen.
        queue.insert(request, at: 0)
        runNext()
    }

    /// Asks for summaries and waits for them, up to `timeout` (for `--render`).
    func complete(_ requests: [Request], timeout: TimeInterval) async {
        requests.forEach(request)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, requests.contains(where: { results[$0] == nil && !failed.contains($0) }) {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runNext() {
        guard !isWorking, !queue.isEmpty else { return }
        let next = queue.removeFirst()
        isWorking = true
        Task {
            let text = await Self.generate(next)
            if let text {
                results[next] = text
            } else {
                failed.insert(next)
            }
            isWorking = false
            runNext()
        }
    }

    nonisolated static func modelIsAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    nonisolated private static func generate(_ request: Request) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await respond(request) }
            group.addTask {
                try? await Task.sleep(for: .seconds(20))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    nonisolated private static func respond(_ request: Request) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            do {
                // Explicitly the on-device model.
                let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: request.instructions)
                let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 90)
                let response = try await session.respond(to: request.prompt, options: options)
                return clean(response.content)
            } catch {
                Log.app.info("On-device summary unavailable: \(String(describing: error), privacy: .public)")
                return nil
            }
        }
        #endif
        return nil
    }

    /// One line, without wrapping quotes or a "Summary:" label.
    nonisolated static func clean(_ text: String) -> String? {
        var line = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        for label in ["Summary:", "Update:", "Phrase:"] where line.hasPrefix(label) {
            line = String(line.dropFirst(label.count)).trimmingCharacters(in: .whitespaces)
        }
        line = line.replacingOccurrences(of: "`", with: "")
        line = line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'*").union(.whitespaces))
        guard line.count >= 3 else { return nil }
        line = curlyQuotes(line)
        return line.count > 220 ? String(line.prefix(219)) + "…" : line
    }

    /// "Title" → “Title”, matching the plain sentences.
    nonisolated static func curlyQuotes(_ text: String) -> String {
        var opening = true
        return String(text.map { character in
            guard character == "\"" else { return character }
            defer { opening.toggle() }
            return opening ? "“" : "”"
        })
    }
}
