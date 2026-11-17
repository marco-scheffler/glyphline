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

    /// An inline assignment is the usual way to hand a command a token. Rather
    /// than skip it and risk surfacing later text, the bubble stays generic.
    func testAnEnvAssignmentIsNeverTheProgram() {
        let action = AgentAction.from(toolName: "Bash",
                                      input: Input(command: "ANTHROPIC_API_KEY=sk-ant-XYZ curl https://x"))
        XCTAssertEqual(action, .usingTool("Bash"))
        XCTAssertFalse(action.text.contains("sk-ant"))
        XCTAssertFalse(action.text.contains("ANTHROPIC_API_KEY"))

        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "env GH_TOKEN=ghp_abc gh pr list")),
                       .usingTool("Bash"))
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "FOO=1 BAR=2")),
                       .usingTool("Bash"))
    }

    func testAnEscapedSpaceNeverLeaks() {
        let action = AgentAction.from(toolName: "Bash",
                                      input: Input(command: #"AUTH=Bearer\ sk-ant-XYZ curl"#))
        XCTAssertEqual(action, .usingTool("Bash"))
        XCTAssertFalse(action.text.contains("sk-ant"))
        XCTAssertFalse(action.text.contains("Bearer"))
    }

    func testEnvAndSudoStillNameTheirProgram() {
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "sudo /usr/bin/make install")),
                       .runningProgram("make"))
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "env python3 x.py")),
                       .runningProgram("python3"))
    }

    func testAQuotedProgramIsNotNamed() {
        XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: "'/usr/bin/curl' -s")),
                       .usingTool("Bash"))
    }

    /// Splitting on whitespace cuts a quoted value apart, so its second half
    /// would otherwise look like the program.
    func testAQuotedAssignmentNeverLeaks() {
        let action = AgentAction.from(toolName: "Bash",
                                      input: Input(command: #"AUTH="Bearer sk-ant-XYZ" curl https://x"#))
        XCTAssertEqual(action, .usingTool("Bash"))
        XCTAssertFalse(action.text.contains("sk-ant"))
        XCTAssertFalse(action.text.contains("Bearer"))
    }

    func testAFlagIsNeverTheProgram() {
        for command in ["sudo -u root curl", "env -i FOO=bar cmd", "env --unset=X cmd"] {
            XCTAssertEqual(AgentAction.from(toolName: "Bash", input: Input(command: command)),
                           .usingTool("Bash"), command)
        }
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

    /// A bubble is one line: a multi-line description, pattern or query must
    /// not draw as two.
    func testWhitespaceRunsCollapseToOneSpace() {
        XCTAssertEqual(
            AgentAction.from(toolName: "Bash",
                             input: Input(description: "Run the\n\ttests  now\n", command: "x")),
            .running(description: "Run the tests now")
        )
        XCTAssertEqual(AgentAction.from(toolName: "Grep", input: Input(pattern: "a\nb")),
                       .searching(pattern: "a b"))
        XCTAssertEqual(AgentAction.from(toolName: "WebSearch", input: Input(query: " swift\r\ncanvas ")),
                       .searchingWeb(query: "swift canvas"))
        XCTAssertEqual(AgentAction.from(toolName: "Grep", input: Input(pattern: " \n ")),
                       .usingTool("Grep"))
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
