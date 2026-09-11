import Foundation

/// Runs an App Intent by app/action identity from inside the JavaScript program.
///
/// macOS has no unentitled API that invokes an App Intent directly: the private
/// LinkServices executor rejects any client that is not a validated bundle. The one
/// supported route is Shortcuts, whose workflow action identifier for an App Intent is
/// `<bundle id>.<intent name>` — the two fields the inventory already stores. So a
/// workflow holding just that action is generated, signed with `shortcuts sign`, and
/// opened for the agent to add once. `shortcuts list` is the record of what is added;
/// there is no separate binding table to drift from it.
enum AppIntentExecution {
    /// Deadline for a single `shortcuts` invocation. An intent that prompts will hit it.
    private static let deadline: TimeInterval = 120

    /// An App Intent's action is `<bundle id>.<intent name>`. The inventory also holds
    /// built-in Shortcuts actions, whose `action_id` is already the whole identifier.
    static func identifier(bundleID: String, actionID: String) -> String {
        actionID.contains(".") ? actionID : "\(bundleID).\(actionID)"
    }

    static func run(bundleID: String, actionID: String,
                    parameters: [String: Any], input: String?) throws -> ToolCallResult {
        let action = identifier(bundleID: bundleID, actionID: actionID)
        let name = "cua.\(action)"
        let installed = try shortcuts(["list"]).split(separator: "\n").contains { $0 == name }
        guard installed else {
            let file = try install(name: name, action: action, parameters: parameters)
            return try json(["installed": false, "shortcut": name, "file": file.path,
                             "next": "Shortcuts is showing an Add Shortcut sheet for \(name). "
                                   + "Prepare Shortcuts, click Add Shortcut, then call run_intent again."])
        }
        var arguments = ["run", name]
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("cua-intent-\(UUID().uuidString)")
        if let input {
            let path = output.appendingPathExtension("in")
            try input.write(to: path, atomically: true, encoding: .utf8)
            arguments += ["--input-path", path.path]
        }
        arguments += ["--output-path", output.path]
        let log = try shortcuts(arguments)
        let text = (try? String(contentsOf: output, encoding: .utf8)) ?? ""
        try? FileManager.default.removeItem(at: output)
        return try json(["installed": true, "shortcut": name, "output": text, "log": log])
    }

    /// Writes the signed workflow and opens it so the agent can add it once.
    private static func install(name: String, action: String,
                                parameters: [String: Any]) throws -> URL {
        let workflow: [String: Any] = [
            "WFWorkflowClientVersion": "2038.0.6",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowTypes": ["NCWidget"],
            "WFWorkflowInputContentItemClasses": ["WFStringContentItem"],
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 946986751, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [],
            "WFQuickActionSurfaces": [],
            "WFWorkflowActions": [[
                "WFWorkflowActionIdentifier": action,
                "WFWorkflowActionParameters": parameters,
            ]],
        ]
        let directory = FileManager.default.temporaryDirectory
        let unsigned = directory.appendingPathComponent("\(name).unsigned.shortcut")
        let signed = directory.appendingPathComponent("\(name).shortcut")
        try PropertyListSerialization
            .data(fromPropertyList: workflow, format: .binary, options: 0)
            .write(to: unsigned)
        _ = try shortcuts(["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path])
        _ = try execute("/usr/bin/open", ["-a", "Shortcuts", signed.path])
        return signed
    }

    private static func shortcuts(_ arguments: [String]) throws -> String {
        try execute("/usr/bin/shortcuts", arguments)
    }

    /// Runs a tool to completion with no stdin. `shortcuts` reads stdin when it is left
    /// attached, which would consume this runtime's own JS protocol pipe.
    private static func execute(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Reading to end of file returns only when the child exits, so the deadline has to
        // end the child. An intent that sits waiting for something would otherwise hold
        // this thread for the rest of the run.
        let timeout = DispatchWorkItem { process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: timeout)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit else {
            throw ComputerUseError.stateUnavailable(
                "\(path) \(arguments[0]) was killed at the \(Int(deadline))s deadline: \(text)")
        }
        guard process.terminationStatus == 0 else {
            throw ComputerUseError.stateUnavailable("\(path) \(arguments[0]) failed: \(text)")
        }
        return text
    }

    private static func json(_ value: Any) throws -> ToolCallResult {
        .text(String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
