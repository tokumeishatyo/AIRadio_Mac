import Testing
@testable import AIRadioInfra

struct OsascriptRunnerTests {
    @Test func splitsMultilineIntoSeparateDashE() {
        let args = OsascriptRunner.arguments(for: "line1\nline2\nline3")
        #expect(args == ["-e", "line1", "-e", "line2", "-e", "line3"])
    }

    @Test func singleLineProducesSingleDashE() {
        #expect(OsascriptRunner.arguments(for: #"tell application "Spotify" to pause"#)
                == ["-e", #"tell application "Spotify" to pause"#])
    }

    @Test func multilinePlayerStateScriptKeepsEachStatementSeparate() {
        let script = """
        tell application "Spotify"
        set st to player state as string
        end tell
        """
        let args = OsascriptRunner.arguments(for: script)
        #expect(args == [
            "-e", #"tell application "Spotify""#,
            "-e", "set st to player state as string",
            "-e", "end tell",
        ])
    }
}
