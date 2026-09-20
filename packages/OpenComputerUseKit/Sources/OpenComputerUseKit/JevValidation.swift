import Foundation

/// `cua.validate(fact)`: a program says what must be true after a step, and goes on.
///
/// The window's text is read at once, on the program's thread. Only the question to Jev
/// travels in the background, so the program never waits for it. A no is asked once more on
/// a newer read of the window; a second no is a failure, which the program's next `cua` call
/// throws. The end of a cell waits for the answers still out. When Jev cannot be reached,
/// nothing fails.
final class JevValidation {
    typealias WindowText = (_ app: String) throws -> String

    private static let attempts = 2

    /// One question sent to Jev. `sure` is written once, before `answered` is signalled.
    private final class Question {
        let app: String
        let fact: String
        let attempt: Int
        let answered = DispatchSemaphore(value: 0)
        var sure: Double?

        init(app: String, fact: String, attempt: Int) {
            self.app = app
            self.fact = fact
            self.attempt = attempt
        }
    }

    private let windowText: WindowText
    private var waiting: [Question] = []

    init(windowText: @escaping WindowText) {
        self.windowText = windowText
    }

    func validate(app: String, fact: String) {
        ask(Question(app: app, fact: fact, attempt: 1))
    }

    /// The first fact Jev denied twice, if any. `patient` waits for the answers still out.
    func failure(patient: Bool) -> String? {
        var stillWaiting: [Question] = []
        defer { waiting = stillWaiting + waiting }
        while !waiting.isEmpty {
            let question = waiting.removeFirst()
            // Every question is answered: by Jev, or by the request's own failure.
            let timeout: DispatchTime = patient ? .distantFuture : .now()
            guard question.answered.wait(timeout: timeout) == .success else {
                stillWaiting.append(question)
                continue
            }
            guard let sure = question.sure, sure < 0.5 else { continue }
            if question.attempt == Self.attempts {
                return "validate failed, this is not true on the screen: \(question.fact)"
            }
            ask(Question(app: question.app, fact: question.fact, attempt: question.attempt + 1))
        }
        return nil
    }

    private func ask(_ question: Question) {
        guard let jev = JevClient.shared, let text = try? windowText(question.app) else { return }
        let instructions = [
            "question": "Is this true of the screen now: \(question.fact)",
            "note": "Judge only from `screen`.",
        ]
        let questions = ["fact": ["type": "noul", "instructions": instructions]]
        waiting.append(question)
        jev.ask(state: ["screen": String(text.prefix(80_000))], questions: questions) { answers in
            question.sure = answers?["fact"]?["noul"] as? Double
            question.answered.signal()
        }
    }
}
