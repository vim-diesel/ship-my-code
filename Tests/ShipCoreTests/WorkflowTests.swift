import Foundation
import XCTest
@testable import ShipCore

final class WorkflowTests: XCTestCase {
    func testProtectedBranchCreatesAndPushesApprovedBranchWithIdenticalScannedPayload() throws {
        let f = try Fixture()
        let original = try f.git.resolve("HEAD")
        try f.write("feature.swift", "let answer = 42\n")
        let c = ScriptConsole(["y"])
        try f.workflow(c).run()
        XCTAssertEqual(try f.git.branch(), "feat/test-change")
        XCTAssertEqual(try f.remoteHash("main"), original)
        XCTAssertEqual(try f.remoteHash("feat/test-change"), try f.git.resolve("HEAD"))
        XCTAssertEqual(try f.git.text(["rev-parse", "--abbrev-ref", "@{upstream}"]), "origin/feat/test-change")
        XCTAssertEqual(try Data(contentsOf: f.temp.url.appendingPathComponent("scanner-input")), try Data(contentsOf: f.temp.url.appendingPathComponent("model-input")))
        XCTAssertNotEqual(try String(contentsOf: f.temp.url.appendingPathComponent("model-cwd")).removingFinalNewline, f.root.path)
        XCTAssertEqual(f.model.calls, 1)
    }

    func testExistingWorkBranchAndPartialStagingRemainIntact() throws {
        let f = try Fixture()
        try f.workBranch()
        try f.write("readme.txt", "staged\n"); try f.stage("readme.txt")
        try f.write("readme.txt", "staged\nunstaged\n")
        try f.write("untracked.txt", "untouched\n")
        let c = ScriptConsole(["y"])
        try f.workflow(c, args: ["--staged"]).run()
        XCTAssertEqual(try f.git.branch(), "work/test")
        XCTAssertEqual(try f.git.text(["show", "HEAD:readme.txt"]), "staged")
        XCTAssertEqual(try f.read("readme.txt"), "staged\nunstaged\n")
        XCTAssertNil(try f.git.entry("untracked.txt"))
        XCTAssertTrue(c.output.contains("excluded"))
    }

    func testDefaultStagesWholeRepositoryFromSubdirectory() throws {
        let f = try Fixture()
        try f.write("outside.txt", "outside\n"); try f.write("nested/inside.txt", "inside\n")
        let c = ScriptConsole([""])
        XCTAssertThrowsError(try f.workflow(c, directory: f.root.appendingPathComponent("nested")).run())
        XCTAssertNotNil(try f.git.entry("outside.txt"))
        XCTAssertNotNil(try f.git.entry("nested/inside.txt"))
    }

    func testEditReviewDiffThenCancelCreatesNoBranchOrCommit() throws {
        let f = try Fixture()
        let original = try f.git.resolve("HEAD")
        try f.write("changed.txt", "complete diff marker\n")
        let c = ScriptConsole(["d", "e", "fix/edited", "fix: edited message", ""])
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertEqual(try f.git.branch(), "main")
        XCTAssertEqual(try f.git.resolve("HEAD"), original)
        XCTAssertNil(try f.git.resolve("refs/heads/fix/edited"))
        XCTAssertTrue(c.output.contains("+complete diff marker"))
        XCTAssertTrue(c.output.contains("Create branch:  fix/edited"))
        XCTAssertTrue(c.output.contains("Commit:         fix: edited message"))
        XCTAssertTrue(try f.git.hasChanges())
    }

    func testEditingExistingBranchDoesNotAskForBranch() throws {
        let f = try Fixture(); try f.workBranch()
        try f.write("a", "a\n")
        let c = ScriptConsole(["e", "fix: revised", "y"])
        try f.workflow(c).run()
        XCTAssertFalse(c.output.contains("New branch"))
        XCTAssertEqual(try f.git.text(["log", "-1", "--format=%s"]), "fix: revised")
    }

    func testInvalidModelOutputOffersManualWithoutRetry() throws {
        let f = try Fixture()
        try f.write("a", "a\n")
        try Data("```json\nnot json; TOP_SECRET_RAW_OUTPUT\n```".utf8).write(to: f.temp.url.appendingPathComponent("model-output"))
        let c = ScriptConsole(["m", "fix/manual", "fix: manually entered", "y"])
        try f.workflow(c).run()
        XCTAssertEqual(f.model.calls, 1)
        XCTAssertFalse(c.output.contains("TOP_SECRET_RAW_OUTPUT"))
        XCTAssertEqual(try f.git.branch(), "fix/manual")
    }

    func testUnsupportedCommandCodeOffersManualWithoutSendingPayload() throws {
        let f = try Fixture(); try f.write("a", "a\n")
        let c = ScriptConsole(["m", "fix/manual", "fix: manual metadata", "y"])
        try f.workflow(c, model: CommandCode(runner: f.runner)).run()
        XCTAssertFalse(f.modelWasInvoked)
        XCTAssertTrue(c.output.contains("lacks the generation bridge controls"))
    }

    func testFailedModelOffersManual() throws {
        let f = try Fixture(); try f.write("a", "a\n")
        try f.script("cmd", "echo RAW_ERROR >&2; exit 7")
        let c = ScriptConsole(["m", "fix/manual", "fix: manual details", "y"])
        try f.workflow(c).run()
        XCTAssertFalse(c.output.contains("RAW_ERROR"))
        XCTAssertEqual(f.model.calls, 1)
    }

    func testSensitiveFilenameBlocksModelAndManualReviewKeepsFinding() throws {
        let f = try Fixture(); try f.write(".env.local", "value=not-a-secret\n")
        let c = ScriptConsole(["m", "chore/manual", "chore: record local file", ""])
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertFalse(f.modelWasInvoked)
        XCTAssertTrue(c.output.contains("Unresolved findings remain in the proposed commit/diff"))
        XCTAssertTrue(c.output.contains(".env.local"))
    }

    func testAddedDeletedAndContextSecretsBlockModelWithoutExcerpts() throws {
        for kind in ["added", "deleted", "context"] {
            let f = try Fixture(); try f.workBranch()
            if kind != "added" {
                try f.write("source.swift", "let key = SHIP_TEST_SECRET\nold\n")
                try f.stage(); _ = try f.git.run(["commit", "-m", "test: fabricated fixture"])
            }
            let changed = kind == "added" ? "let key = SHIP_TEST_SECRET\n" : (kind == "deleted" ? "old\n" : "let key = SHIP_TEST_SECRET\nnew\n")
            try f.write("source.swift", changed)
            let c = ScriptConsole([""])
            XCTAssertThrowsError(try f.workflow(c).run())
            XCTAssertFalse(f.modelWasInvoked, kind)
            XCTAssertFalse(c.output.contains("SHIP_TEST_SECRET"), kind)
            XCTAssertTrue(c.output.contains(kind + " line"), c.output)
            XCTAssertFalse(c.output.contains("Ignore this file"))
        }
    }

    func testMissingAndFailingScannerCannotReachModel() throws {
        for missing in [true, false] {
            let f = try Fixture(); try f.write("a", "a\n")
            if missing { try FileManager.default.removeItem(at: f.bin.appendingPathComponent("gitleaks")) }
            else { try f.script("gitleaks", "echo SECRET_DIAGNOSTIC >&2; exit 1") }
            let c = ScriptConsole(["m", "fix/manual", "fix: manual commit", "y"])
            try f.workflow(c).run()
            XCTAssertFalse(f.modelWasInvoked)
            XCTAssertTrue(c.output.contains("NOT SCANNED"))
            XCTAssertFalse(c.output.contains("SECRET_DIAGNOSTIC"))
        }
    }

    func testIgnoreNewFilePreservesLocalContentsAndRescans() throws {
        let f = try Fixture(); try f.write(".env.local", "SHIP_TEST_SECRET\n")
        let c = ScriptConsole(["1", "y"])
        try f.workflow(c).run()
        XCTAssertEqual(try f.read(".env.local"), "SHIP_TEST_SECRET\n")
        XCTAssertNil(try f.git.entry(".env.local"))
        XCTAssertEqual(try f.git.text(["show", "HEAD:.gitignore"]), "/.env.local")
        XCTAssertFalse(try String(contentsOf: f.temp.url.appendingPathComponent("model-input")).contains("SHIP_TEST_SECRET"))
    }

    func testIgnorePreservesIndependentStagedAndUnstagedIgnoreEditsAndUnusualPath() throws {
        let f = try Fixture()
        try f.write(".gitignore", "base\n"); try f.stage(); _ = try f.git.run(["commit", "-m", "chore: ignore base"])
        try f.write(".gitignore", "base\nstaged-only\n"); try f.stage(".gitignore")
        try f.write(".gitignore", "base\nstaged-only\nwork-only\n")
        let path = "odd [*] #!\\dir/.env.local"
        try f.write(path, "SHIP_TEST_SECRET\n"); try f.stage(path)
        let c = ScriptConsole(["1", ""])
        XCTAssertThrowsError(try f.workflow(c, args: ["--staged"]).run())
        let staged = try f.git.text(["show", ":.gitignore"])
        XCTAssertTrue(staged.contains("staged-only")); XCTAssertFalse(staged.contains("work-only"))
        XCTAssertTrue(try f.read(".gitignore").contains("work-only"))
        XCTAssertEqual(try f.read(path), "SHIP_TEST_SECRET\n")
        XCTAssertNil(try f.git.entry(path))
        XCTAssertEqual(try f.git.run(["check-ignore", "--quiet", "--", path], accepted: [0, 1]).status, 0)
    }

    func testUntrackedGitignoreDoesNotStageItsOtherContents() throws {
        let f = try Fixture()
        try f.write(".gitignore", "user-unstaged-rule\n")
        try f.write(".env", "x\n"); try f.stage(".env")
        try Remediation.ignoreAndUntrack(".env", git: f.git, state: f.git.state())
        XCTAssertEqual(try f.git.text(["show", ":.gitignore"]), "/.env")
        XCTAssertEqual(try f.read(".gitignore"), "user-unstaged-rule\n/.env\n")
    }

    func testUnbornRepositoryCanIgnoreAndCommit() throws {
        let f = try Fixture(initial: false)
        try f.write(".env", "SHIP_TEST_SECRET\n")
        let c = ScriptConsole(["1", "y"])
        try f.workflow(c).run()
        XCTAssertEqual(try f.git.branch(), "main")
        XCTAssertEqual(try f.read(".env"), "SHIP_TEST_SECRET\n")
        XCTAssertNotNil(try f.remoteHash("main"))
    }

    func testStopTrackingUsesLocalSuggestionAndKeepsFile() throws {
        let f = try Fixture()
        try f.write(".env", "SHIP_TEST_SECRET old\n"); try f.stage(); _ = try f.git.run(["commit", "-m", "test: fabricated tracked file"])
        try f.write(".env", "SHIP_TEST_SECRET new\n")
        let c = ScriptConsole(["1", "y", "chore/untrack-env", "", "y"])
        try f.workflow(c).run()
        XCTAssertFalse(f.modelWasInvoked)
        XCTAssertEqual(try f.read(".env"), "SHIP_TEST_SECRET new\n")
        XCTAssertNil(try f.git.entry(".env", head: true))
        XCTAssertEqual(try f.git.text(["log", "-1", "--format=%s"]), "chore: stop tracking local environment file")
        XCTAssertTrue(c.output.contains("Earlier history is unchanged"))
        XCTAssertTrue(c.output.contains("Local suggestion"))
        XCTAssertTrue(c.output.contains("Unresolved findings"))
    }

    func testSecretRemovalDiffOffersLocalMessage() throws {
        let f = try Fixture(); try f.workBranch()
        try f.write("code.swift", "SHIP_TEST_SECRET\nkeep\n"); try f.stage(); _ = try f.git.run(["commit", "-m", "test: fixture"])
        try f.write("code.swift", "keep\n")
        let c = ScriptConsole(["l", "", "y"])
        try f.workflow(c).run()
        XCTAssertFalse(f.modelWasInvoked)
        XCTAssertEqual(try f.git.text(["log", "-1", "--format=%s"]), "chore: remove sensitive local data")
    }

    func testPushFailureThenPushOnlyRerunRecovery() throws {
        let f = try Fixture(); try f.workBranch()
        try f.hook("pre-receive", "exit 1", bare: true)
        try f.write("a", "a\n")
        let c = ScriptConsole(["y"])
        XCTAssertThrowsError(try f.workflow(c).run())
        let committed = try f.git.resolve("HEAD")
        XCTAssertTrue(c.output.contains("commit exists locally"))
        XCTAssertTrue(c.output.contains(f.git.retryCommand(branch: "work/test")))
        try FileManager.default.removeItem(at: f.remote.appendingPathComponent("hooks/pre-receive"))
        let recovery = ScriptConsole(["y"])
        try f.workflow(recovery).run()
        XCTAssertEqual(try f.remoteHash("work/test"), committed)
        XCTAssertEqual(f.model.calls, 1)
        XCTAssertTrue(recovery.output.contains("No staged changes"))
    }

    func testStateChangedAtApprovalDoesNotCommitOrCreateBranch() throws {
        for kind in ["index", "head", "branch"] {
            let f = try Fixture(); try f.write("a", "a\n")
            let c = ScriptConsole(["y"])
            c.onPrompt = { prompt in
                if prompt.contains("proceed") {
                    switch kind {
                    case "index": try f.write("b", "b\n"); try f.stage("b")
                    case "head": _ = try f.git.run(["commit", "--allow-empty", "-m", "chore: concurrent commit"])
                    default: _ = try f.git.run(["switch", "-c", "other"])
                    }
                }
            }
            XCTAssertThrowsError(try f.workflow(c).run()) { error in
                XCTAssertTrue(String(describing: error).contains("changed after review"))
            }
            XCTAssertNil(try f.git.resolve("refs/heads/feat/test-change"))
            XCTAssertNil(try f.remoteHash("feat/test-change"))
        }
    }

    func testHookChangedTreeStopsBeforePush() throws {
        let f = try Fixture(); try f.write("a", "a\n")
        try f.hook("pre-commit", "printf 'hook content\\n' > hook.txt\ngit add hook.txt")
        let c = ScriptConsole(["y"])
        XCTAssertThrowsError(try f.workflow(c).run()) { error in XCTAssertTrue(String(describing: error).contains("differs from the reviewed")) }
        XCTAssertNotNil(try f.git.entry("hook.txt", head: true))
        XCTAssertNil(try f.remoteHash("feat/test-change"))
    }

    func testFailedCommitLeavesCreatedBranchCheckedOut() throws {
        let f = try Fixture(); try f.write("a", "a\n")
        let original = try f.git.resolve("HEAD")
        try f.hook("pre-commit", "exit 1")
        let c = ScriptConsole(["y"])
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertEqual(try f.git.branch(), "feat/test-change")
        XCTAssertEqual(try f.git.resolve("HEAD"), original)
        XCTAssertTrue(c.output.contains("Currently checked out: feat/test-change"))
    }

    func testProtectedBranchesNeverPushOnlyAndKnownRemoteDefaultIsProtected() throws {
        for branch in ["main", "master", "trunk"] {
            let f = try Fixture(branch: branch)
            _ = try f.git.run(["commit", "--allow-empty", "-m", "chore: ahead"])
            let c = ScriptConsole([])
            try f.workflow(c).run()
            XCTAssertTrue(c.output.contains("Nothing to ship."))
            XCTAssertEqual(f.model.calls, 0)
            XCTAssertTrue(try f.git.protectedBranches().contains(branch))
        }
    }

    func testNothingToShipAndNewWorkBranchPublishWithoutModel() throws {
        let f = try Fixture(); try f.workBranch()
        let c = ScriptConsole(["y"])
        try f.workflow(c).run()
        XCTAssertEqual(f.model.calls, 0)
        XCTAssertNotNil(try f.remoteHash("work/test"))
        let again = ScriptConsole([])
        try f.workflow(again).run()
        XCTAssertTrue(again.output.contains("Nothing to ship."))
    }

    func testPreflightRejectsOperationsAndNoninteractiveBeforeStaging() throws {
        for operation in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer"] {
            let f = try Fixture(); try f.write("a", "unstaged\n")
            try Data("marker".utf8).write(to: f.root.appendingPathComponent(".git/" + operation))
            XCTAssertThrowsError(try f.workflow(ScriptConsole([])).run())
            XCTAssertNil(try f.git.entry("a"))
        }
        let f = try Fixture(); try f.write("a", "unstaged\n")
        let c = ScriptConsole([]); c.interactive = false
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertNil(try f.git.entry("a"))
    }

    func testMissingRemoteAndDetachedHeadBeforeStaging() throws {
        let f = try Fixture(); try f.write("a", "a\n")
        XCTAssertThrowsError(try f.workflow(ScriptConsole([]), args: ["--remote", "missing"]).run())
        _ = try f.git.run(["checkout", "--detach"])
        XCTAssertThrowsError(try f.workflow(ScriptConsole([])).run())
        XCTAssertNil(try f.git.entry("a"))
    }

    func testUnknownPushComparisonAndExistingOutgoingCommitSubjects() throws {
        let f = try Fixture(); try f.workBranch()
        _ = try f.git.run(["commit", "--allow-empty", "-m", "chore: previous work"])
        let c = ScriptConsole([""])
        XCTAssertThrowsError(try f.workflow(c).run())
        XCTAssertTrue(c.output.contains("chore: previous work"))
        _ = try f.git.run(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
        let unknown = ScriptConsole([""])
        XCTAssertThrowsError(try f.workflow(unknown).run())
        XCTAssertTrue(unknown.output.contains("Outgoing commit count is unknown"))
    }
}
