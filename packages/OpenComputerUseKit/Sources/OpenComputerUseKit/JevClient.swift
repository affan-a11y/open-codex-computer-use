import Foundation

/// Jev, TypeSafe's judgment model: every question about one `state` answered in one request.
/// One client for the whole process, so its connection stays open between requests.
/// Without `TYPESAFE_API_KEY` there is no client, and nothing that uses Jev runs.
final class JevClient: Sendable {
    typealias Answers = [String: [String: Any]]

    static let shared: JevClient? = {
        guard let key = ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"], !key.isEmpty else {
            return nil
        }
        return JevClient(key: key)
    }()

    private let url = URL(string: "https://api.typesafe.ai/v1/systemone")!
    private let session = URLSession(configuration: .ephemeral)
    private let key: String

    private init(key: String) {
        self.key = key
    }

    /// Ask without waiting. `completion` gets the answers by question id, or nil when Jev
    /// could not be reached or did not answer.
    func ask(state: [String: Any], questions: [String: Any], completion: @escaping (Answers?) -> Void) {
        let body: [String: Any] = ["model": "jev-latest", "state": state, "questions": questions]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        session.dataTask(with: request) { data, _, _ in
            completion(data.flatMap(Self.answers))
        }.resume()
    }

    /// Ask and wait for the answer: for a caller that cannot go on without it.
    func ask(state: [String: Any], questions: [String: Any]) -> Answers? {
        let answered = DispatchSemaphore(value: 0)
        var answers: Answers?
        ask(state: state, questions: questions) { reply in
            answers = reply
            answered.signal()
        }
        answered.wait()
        return answers
    }

    private static func answers(from data: Data) -> Answers? {
        let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return reply?["answers"] as? Answers
    }
}
