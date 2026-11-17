import Foundation

/// What a session is doing right now, named after its last tool call.
///
/// A case per kind of call rather than a ready string, so tests can assert the
/// case and localisation happens once, in `text`. This says nothing about
/// whether the session is working or waiting — `AgentActivity` alone decides
/// that.
enum AgentAction: Equatable, Sendable {
    /// `Bash` with a `description`.
    case running(description: String)
    /// `Bash` without one: the program's name only, never the command line,
    /// which can carry a token or a password.
    case runningProgram(String)
    case editing(file: String)
    case writing(file: String)
    case reading(file: String)
    case searching(pattern: String)
    case finding(pattern: String)
    case delegating(String)
    case readingWeb
    case searchingWeb(query: String)
    /// An MCP tool, named by its server.
    case usingServer(String)
    case usingTool(String)
    /// An assistant record without a call, or a prompt just typed.
    case thinking

    /// The fields of a `tool_use` block's `input` that any case reads. Every
    /// other field — above all a Bash `command`'s arguments — is never kept.
    struct ToolInput: Decodable, Equatable, Sendable {
        var description: String?
        var command: String?
        var file_path: String?
        var notebook_path: String?
        var pattern: String?
        var query: String?
    }

    /// A field the case needs that is missing or empty falls back to the tool
    /// name, which is always true.
    static func from(toolName: String, input: ToolInput) -> AgentAction {
        // Runs of whitespace, newlines and tabs included, become one space: a
        // bubble is one line, and a multi-line description must not draw as two.
        func present(_ value: String?) -> String? {
            guard let value else { return nil }
            let collapsed = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return collapsed.isEmpty ? nil : collapsed
        }
        func fileName(_ path: String?) -> String? {
            present(path).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        let fallback = AgentAction.usingTool(toolName)

        switch toolName {
        case "Bash":
            if let description = present(input.description) {
                return .running(description: description)
            }
            guard let program = programName(in: input.command ?? "") else { return fallback }
            return .runningProgram(program)
        case "Edit", "MultiEdit":
            return fileName(input.file_path).map { .editing(file: $0) } ?? fallback
        case "NotebookEdit":
            return fileName(input.notebook_path).map { .editing(file: $0) } ?? fallback
        case "Write":
            return fileName(input.file_path).map { .writing(file: $0) } ?? fallback
        case "Read":
            return fileName(input.file_path).map { .reading(file: $0) } ?? fallback
        case "Grep":
            return present(input.pattern).map { .searching(pattern: $0) } ?? fallback
        case "Glob":
            return present(input.pattern).map { .finding(pattern: $0) } ?? fallback
        case "Agent", "Task":
            return present(input.description).map { .delegating($0) } ?? fallback
        case "WebFetch":
            return .readingWeb
        case "WebSearch":
            return present(input.query).map { .searchingWeb(query: $0) } ?? fallback
        default:
            // `mcp__<server>__<tool>`; the server is the part a person recognises.
            let parts = toolName.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp", !parts[1].isEmpty {
                return .usingServer(parts[1])
            }
            return fallback
        }
    }

    /// The program a command line runs, and nothing else from it — or nil
    /// whenever that cannot be said safely.
    ///
    /// Deliberately not a shell parser, and it skips nothing but a leading `env`
    /// or `sudo`: every token skipped is a chance for later command text — an
    /// assignment's quoted or escaped value — to surface as the "program". The
    /// first word is named only when it plainly is a program path; an
    /// assignment, a flag, a quote or anything unusual gives up instead.
    private static func programName(in command: String) -> String? {
        let tokens = command.split(whereSeparator: \.isWhitespace)
        let index = tokens.first == "env" || tokens.first == "sudo" ? 1 : 0
        guard index < tokens.count else { return nil }
        let candidate = tokens[index]
        guard !candidate.contains("="),
              !candidate.hasPrefix("-"),
              candidate.wholeMatch(of: /[A-Za-z0-9._\/+-]{1,128}/) != nil
        else { return nil }
        let name = URL(fileURLWithPath: String(candidate)).lastPathComponent
        return name.wholeMatch(of: /[A-Za-z0-9._+-]{1,32}/) != nil ? name : nil
    }

    var isToolAction: Bool { self != .thinking }

    var text: String {
        switch self {
        case .running(let description):
            return description
        case .runningProgram(let program):
            return String(localized: "Running \(program)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a program name such as 'curl'.")
        case .editing(let file):
            return String(localized: "Editing \(file)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a file name.")
        case .writing(let file):
            return String(localized: "Writing \(file)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a file name.")
        case .reading(let file):
            return String(localized: "Reading \(file)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a file name.")
        case .searching(let pattern):
            return String(localized: "Searching for “\(pattern)”",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a search pattern.")
        case .finding(let pattern):
            return String(localized: "Finding \(pattern)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a file pattern such as '**/*.swift'.")
        case .delegating(let description):
            return String(localized: "Delegating: \(description)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: what a subagent was asked to do.")
        case .readingWeb:
            return String(localized: "Reading the web",
                          comment: "Speech bubble over a session's figure, keep it short.")
        case .searchingWeb(let query):
            return String(localized: "Searching the web: \(query)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a web search query.")
        case .usingServer(let server):
            return String(localized: "Using \(server)",
                          comment: "Speech bubble over a session's figure, keep it short. Placeholder: a tool server's name.")
        case .usingTool(let tool):
            return tool
        case .thinking:
            return String(localized: "Thinking…",
                          comment: "Speech bubble over a session's figure, keep it short. The session is between tool calls.")
        }
    }
}
