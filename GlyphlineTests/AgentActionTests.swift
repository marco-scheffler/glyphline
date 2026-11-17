import XCTest
@testable import Glyphline

final class AgentActionTests: XCTestCase {
    private typealias Input = AgentAction.ToolInput

    func testBashPrefersItsDescription() {
        XCTAssertEqual(
            AgentAction.from(toolName: "Bash",
                             input: Input(description: "Run the tests", command: "xcodebuild test")),
            .running(description: "Run the tests")
        )
    }

    /// A command line can carry a token or a password; only the program's name
    /// may ever reach a bubble.
    func testBashWithoutDescriptionNamesOnlyTheProgram() {
        let action = AgentAction.from(
            toolName: "Bash",
            input: Input(command: "/usr/bin/curl -H 'Authorization: Bearer sk-ant-SECRET' https://x")
        )

        XCTAssertEqual(action, .runningProgram("curl"))
        XCTAssertFalse(action.text.contains("sk-ant"))
        XCTAssertFalse(action.text.contains("Bearer"))
    }

    /// An inline assignment is the usual way to hand a command a token, so the
    /// first word is not always the program.
    func testAnEnvAssignmentIsNeverTheProgram() {
        let action = AgentAction.from(toolName: "Bash",
                                      input: Input(command: "ANTHROPIC_API_KEY=sk-ant-XYZ curl https://x"))
        XCTAssertEqual(action, .runningProgram("curl"))
        XCTAssertFalse(action.text.contains("sk-ant"))
        XCTAssertFalse(action.text.contains("ANTHROPIC_API_KEY"))

        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "env GH_TOKEN=ghp_abc gh pr list")),
                       .runningProgram("gh"))
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "FOO=1 BAR=2")),
                       .usingTool("Bash"))
    }

    func testAQuotedProgramLosesItsQuotes() {
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "'/usr/bin/curl' -s")),
                       .runningProgram("curl"))
    }

    func testFileToolsUseTheFileName() {
        let path = "/a/b/OfficeRenderer.swift"
        XCTAssertEqual(AgentAction.from(toolName: "Edit", input: Input(file_path: path)),
                       .editing(file: "OfficeRenderer.swift"))
        XCTAssertEqual(AgentAction.from(toolName: "MultiEdit", input: Input(file_path: path)),
                       .editing(file: "OfficeRenderer.swift"))
        XCTAssertEqual(AgentAction.from(toolName: "NotebookEdit", input: Input(notebook_path: "/a/b/Plot.ipynb")),
                       .editing(file: "Plot.ipynb"))
        XCTAssertEqual(AgentAction.from(toolName: "Write", input: Input(file_path: path)),
                       .writing(file: "OfficeRenderer.swift"))
        XCTAssertEqual(AgentAction.from(toolName: "Read", input: Input(file_path: path)),
                       .reading(file: "OfficeRenderer.swift"))
    }

    func testSearchTools() {
        XCTAssertEqual(AgentAction.from(toolName: "Grep", input: Input(pattern: "stop_reason")),
                       .searching(pattern: "stop_reason"))
        XCTAssertEqual(AgentAction.from(toolName: "Glob", input: Input(pattern: "**/*.swift")),
                       .finding(pattern: "**/*.swift"))
        XCTAssertEqual(AgentAction.from(toolName: "WebSearch", input: Input(query: "swift canvas")),
                       .searchingWeb(query: "swift canvas"))
        XCTAssertEqual(AgentAction.from(toolName: "WebFetch", input: Input()), .readingWeb)
    }

    func testDelegationAndServers() {
        XCTAssertEqual(AgentAction.from(toolName: "Agent", input: Input(description: "Review task 1")),
                       .delegating("Review task 1"))
        XCTAssertEqual(AgentAction.from(toolName: "Task", input: Input(description: "Review task 1")),
                       .delegating("Review task 1"))
        XCTAssertEqual(AgentAction.from(toolName: "mcp__ccd_turn__update_plan", input: Input()),
                       .usingServer("ccd_turn"))
        XCTAssertEqual(AgentAction.from(toolName: "TodoWrite", input: Input()), .usingTool("TodoWrite"))
        XCTAssertEqual(AgentAction.from(toolName: "Edit", input: Input()), .usingTool("Edit"))
    }

    func testOnlyThinkingIsNotAToolAction() {
        XCTAssertFalse(AgentAction.thinking.isToolAction)
        let others: [AgentAction] = [
            .running(description: "x"), .runningProgram("x"), .editing(file: "x"),
            .writing(file: "x"), .reading(file: "x"), .searching(pattern: "x"),
            .finding(pattern: "x"), .delegating("x"), .readingWeb,
            .searchingWeb(query: "x"), .usingServer("x"), .usingTool("x"),
        ]
        for action in others {
            XCTAssertTrue(action.isToolAction, "\(action)")
        }
    }
}
