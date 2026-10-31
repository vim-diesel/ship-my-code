import Foundation
import XCTest
@testable import ShipCore

final class SafetyTests: XCTestCase {
    func testBranchValidationRejectsInvalidProtectedAndKnownNames() throws {
        let f = try Fixture()
        for name in ["main", "master", "HEAD", "refs/heads/foo", "-option", "a..b", "a b", "a\nname", "@{-1}"] {
            XCTAssertThrowsError(try f.git.validateNewBranch(name), name)
        }
        _ = try f.git.run(["branch", "local-existing"])
        _ = try f.git.run(["update-ref", "refs/remotes/origin/remote-existing", "HEAD"])
        XCTAssertThrowsError(try f.git.validateNewBranch("local-existing"))
        XCTAssertThrowsError(try f.git.validateNewBranch("remote-existing"))
        XCTAssertNoThrow(try f.git.validateNewBranch("fix/valid-name"))
    }

    func testMessageAndJSONValidation() throws {
        for value in ["", "two\nlines", "fix: value\rmore", "fix: \u{1B}[2J", "fix: \u{202E}evil", "fix: \u{0085}", "not conventional", "fix: "] {
            XCTAssertThrowsError(try Proposal.validateMessage(value), value)
        }
        XCTAssertNoThrow(try Proposal.validateMessage("fix(auth)!: reject empty credentials"))
        for json in [#"{"message":"fix: valid"}"#, #"{"branch":"oops","message":"fix: valid"}"#, #"{"branch":null,"message":"fix: valid","command":"rm"}"#] {
            XCTAssertThrowsError(try Proposal.decode(Data(json.utf8), needsBranch: false))
        }
        XCTAssertNoThrow(try Proposal.decode(Data(#"{"branch":null,"message":"fix: valid"}"#.utf8), needsBranch: false))
    }

    func testPreciseFilenameRulesAndRenameOldPath() throws {
        for name in [".env", "sub/.env.production", "keys/server.pem", "id_ed25519", "cert.p12", "bundle.pfx", ".aws/credentials", ".docker/config.json"] {
            XCTAssertNotNil(Payload.sensitivePath(name), name)
        }
        for name in ["config.json", "package.json", "configuration.swift", ".env.example", ".env.template", "id_ed25519.pub", "environment.swift"] {
            XCTAssertNil(Payload.sensitivePath(name), name)
        }
        let f = try Fixture()
        try f.write(".env", "plain text\n"); try f.stage(); _ = try f.git.run(["commit", "-m", "test: path fixture"])
        _ = try f.git.run(["mv", ".env", "ordinary.txt"])
        let payload = try Payload.build(git: f.git, state: f.git.state(), needsBranch: true)
        XCTAssertTrue(payload.filenameFindings.contains { $0.path == ".env" })
    }

    func testBinaryContentsOmittedEvenWhenAttributesForceText() throws {
        let f = try Fixture()
        try f.write(".gitattributes", "*.bin diff\n")
        try f.writeData("data.bin", Data([0, 1, 2]) + Data("BINARY_CONTENT_MARKER".utf8))
        try f.stage()
        let payload = try Payload.build(git: f.git, state: f.git.state(), needsBranch: true)
        let text = try utf8(payload.data)
        XCTAssertTrue(text.contains("Binary change: contents omitted"))
        XCTAssertFalse(text.contains("BINARY_CONTENT_MARKER"))
    }

    func testTemplateFileStillScannedAndMetadataIsScanned() throws {
        let f = try Fixture()
        try f.write(".env.example", "SHIP_TEST_SECRET\n")
        try f.write("SHIP_TEST_SECRET.txt", "ordinary\n")
        try f.stage()
        let payload = try Payload.build(git: f.git, state: f.git.state(), needsBranch: true)
        XCTAssertTrue(payload.filenameFindings.isEmpty)
        let scan = f.scanner.scan(payload)
        XCTAssertNil(scan.unavailable)
        XCTAssertFalse(scan.permitsModel)
        XCTAssertTrue(scan.findings.contains { $0.path == ".env.example" })
        XCTAssertTrue(scan.findings.contains { $0.path == "SHIP_TEST_SECRET.txt" })
    }

    func testActualGitleaksBuiltinsInlineAllowAndRepositoryOverrides() throws {
        guard FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/gitleaks") else {
            throw XCTSkip("Optional real-scanner check: gitleaks not installed at /opt/homebrew/bin/gitleaks")
        }
        let f = try Fixture()
        let fake = f.bin.appendingPathComponent("gitleaks")
        try FileManager.default.removeItem(at: fake)
        try FileManager.default.createSymbolicLink(at: fake, withDestinationURL: URL(fileURLWithPath: "/opt/homebrew/bin/gitleaks"))
        let fabricated = "ghp_" + "8Qm4Zp9Xc2Vr7Nb5Ws1Yt6Kd3Hj0LfAeUiRo"
        try f.write(".gitleaks.toml", "[allowlist]\nregexes = ['.*']\n")
        try f.write(".gitleaksignore", "*\n")
        try f.write("source.swift", "let token = \"\(fabricated)\" // gitleaks:allow\n")
        try f.stage("source.swift")
        var env = f.runner.environment
        env["GITLEAKS_CONFIG_TOML"] = "[allowlist]\nregexes = ['.*']\n"
        let scanner = GitleaksScanner(runner: ProcessRunner(environment: env))
        let payload = try Payload.build(git: f.git, state: f.git.state(), needsBranch: true)
        let scan = scanner.scan(payload)
        XCTAssertNil(scan.unavailable, scan.unavailable ?? "")
        XCTAssertFalse(scan.permitsModel)
        XCTAssertTrue(scan.findings.contains { $0.path == "source.swift" })
        XCTAssertFalse(scan.findings.map(\.reason).joined().contains(fabricated))
    }

    func testScannerFailureExitOneIsNotTreatedAsNoFindingsOrLeakStatus() throws {
        let f = try Fixture()
        try f.write("a", "a\n"); try f.stage()
        try f.script("gitleaks", """
        if [ "$2" = "--help" ]; then
          echo '--config --redact --ignore-gitleaks-allow --gitleaks-ignore-path --exit-code --max-target-megabytes --report-format --report-template --report-path --no-banner --no-color --log-level'
        else
          echo '[]'; exit 1
        fi
        """)
        let scan = f.scanner.scan(try Payload.build(git: f.git, state: f.git.state(), needsBranch: true))
        XCTAssertNotNil(scan.unavailable)
        XCTAssertFalse(scan.permitsModel)
    }

    func testIgnoreDoesNotDuplicateAndHandlesLeadingDashAndWhitespace() throws {
        let f = try Fixture()
        let name = "- odd [x]*?#\\.pem"
        let rule = try Remediation.ignoreRule(name)
        try f.write(".gitignore", rule + "\n"); try f.stage(".gitignore")
        try f.write(name, "contents\n"); _ = try f.git.run(["add", "-f", "--", name])
        try Remediation.ignoreAndUntrack(name, git: f.git, state: f.git.state())
        XCTAssertEqual(try f.read(".gitignore"), rule + "\n")
        XCTAssertEqual(try f.read(name), "contents\n")
        XCTAssertThrowsError(try Remediation.ignoreRule("bad\nname.pem"))
    }

    func testStagedIgnoreDeletionAndSymlinksAreNotOverwritten() throws {
        let f = try Fixture()
        try f.write(".gitignore", "rule\n"); try f.stage(); _ = try f.git.run(["commit", "-m", "chore: rules"])
        _ = try f.git.run(["rm", "--cached", ".gitignore"])
        try f.write(".env", "local\n"); try f.stage(".env")
        let state = try f.git.state()
        XCTAssertThrowsError(try Remediation.ignoreAndUntrack(".env", git: f.git, state: state))
        XCTAssertEqual(try f.git.state(), state)
        XCTAssertEqual(try f.read(".gitignore"), "rule\n")
    }

    func testNestedIgnoreOverrideRestoresWorktreeAndIndex() throws {
        let f = try Fixture()
        try f.write("sub/.gitignore", "!.env\n")
        try f.write("sub/.env", "local\n"); try f.stage()
        let before = try f.git.state()
        XCTAssertThrowsError(try Remediation.ignoreAndUntrack("sub/.env", git: f.git, state: before))
        XCTAssertEqual(try f.git.state(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".gitignore").path))
        XCTAssertEqual(try f.read("sub/.env"), "local\n")
    }

    func testEditorParsingDoesNotEvaluateShellSyntax() throws {
        XCTAssertEqual(try Remediation.editorWords("'/Applications/My Editor' --wait \"two words\""), ["/Applications/My Editor", "--wait", "two words"])
        for config in ["vim; touch /tmp/unsafe", "$(id)", "vim | cat", "vim `id`", "vim 'unfinished"] {
            XCTAssertThrowsError(try Remediation.editorWords(config))
        }
        // A quoted metacharacter is an inert literal argument, never shell code.
        XCTAssertEqual(try Remediation.editorWords("editor '$(id)'"), ["editor", "$(id)"])
    }

    func testEditorPreservesPartialStagingAndRequiresManualSelection() throws {
        let f = try Fixture(); try f.workBranch()
        try f.write("source.swift", "SHIP_TEST_SECRET\nstaged\n"); try f.stage("source.swift")
        try f.write("source.swift", "SHIP_TEST_SECRET\nstaged\nunstaged\n")
        try f.script("editor", "printf 'clean\\nstaged\\nunstaged\\n' > \"$1\"")
        let selected = try f.git.entry("source.swift")!.hash
        let c = ScriptConsole(["1", "r", "m", "fix: manual partial review", ""])
        XCTAssertThrowsError(try f.workflow(c, args: ["--staged"]).run())
        XCTAssertEqual(try f.git.entry("source.swift")!.hash, selected)
        XCTAssertTrue(try f.read("source.swift").contains("unstaged"))
        XCTAssertTrue(c.output.contains("partially staged"))
        XCTAssertFalse(f.modelWasInvoked)
    }

    func testEditorFullyStagedFileShowsDiffAndWaitsForApproval() throws {
        let f = try Fixture(); try f.workBranch()
        try f.write("source.swift", "SHIP_TEST_SECRET\n"); try f.stage()
        try f.script("editor", "printf 'clean\\n' > \"$1\"")
        let c = ScriptConsole(["1", "y", "y"])
        try f.workflow(c, args: ["--staged"]).run()
        XCTAssertTrue(c.output.contains("+clean"))
        XCTAssertTrue(c.output.contains("stage these edits"))
        XCTAssertEqual(try f.git.text(["show", "HEAD:source.swift"]), "clean")
        XCTAssertEqual(f.model.calls, 1)
    }

    func testPushDoesNotHonorMirrorTagsOrAdditionalPushRefspecs() throws {
        let f = try Fixture(); try f.workBranch()
        _ = try f.git.run(["branch", "unapproved"])
        _ = try f.git.run(["tag", "unapproved-tag"])
        _ = try f.git.run(["config", "push.followTags", "true"])
        _ = try f.git.run(["config", "remote.origin.mirror", "true"])
        _ = try f.git.run(["config", "remote.origin.push", "refs/heads/unapproved:refs/heads/unapproved"])
        let c = ScriptConsole(["y"])
        try f.workflow(c).run()
        XCTAssertNil(try f.remoteHash("unapproved"))
        let tag = try f.runner.run("/usr/bin/git", ["--git-dir", f.remote.path, "show-ref", "--verify", "--quiet", "refs/tags/unapproved-tag"], cwd: f.root)
        XCTAssertNotEqual(tag.status, 0)
        XCTAssertNotNil(try f.remoteHash("main"))
    }

    func testRemoteStateChangeAtApprovalStopsPush() throws {
        let f = try Fixture(); try f.workBranch()
        let c = ScriptConsole(["y"])
        c.onPrompt = { _ in _ = try f.git.run(["remote", "set-url", "origin", f.temp.url.appendingPathComponent("different.git").path]) }
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertNil(try f.remoteHash("work/test"))
    }

    func testProcessConcurrentPipesLargePayloadAndEarlyStdinClose() throws {
        let f = try Fixture()
        try f.script("pipes", """
        /usr/bin/head -c 262144 /dev/zero >&2
        /usr/bin/head -c 262144 /dev/zero
        /bin/cat
        """)
        let payload = Data(repeating: 65, count: 2 * 1024 * 1024)
        let result = try f.runner.run(f.bin.appendingPathComponent("pipes").path, [], cwd: f.root, input: payload, timeout: 10)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.stdout.count, payload.count + 262144)
        XCTAssertEqual(result.stderr.count, 262144)
        try f.script("early", "exit 3")
        XCTAssertThrowsError(try f.runner.run(f.bin.appendingPathComponent("early").path, [], cwd: f.root, input: payload, timeout: 5))
    }

    func testNoYesFlagAndEOFDefaultsToCancellation() throws {
        XCTAssertThrowsError(try Options(["--yes"]))
        let f = try Fixture(); try f.write("a", "a\n")
        let head = try f.git.resolve("HEAD")
        XCTAssertThrowsError(try f.workflow(ScriptConsole([])).run())
        XCTAssertEqual(try f.git.resolve("HEAD"), head)
        XCTAssertEqual(try f.git.branch(), "main")
    }
}
