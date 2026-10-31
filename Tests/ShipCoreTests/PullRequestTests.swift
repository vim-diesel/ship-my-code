import Foundation
import XCTest
@testable import ShipCore

final class PullRequestTests: XCTestCase {
    private func prepare(secret: Bool = false, existing: Bool = false, blockedMerge: Bool = false) throws -> Fixture {
        let f = try Fixture()
        let base = try XCTUnwrap(f.git.resolve("HEAD"))
        try f.workBranch("feat/pr-flow")
        try f.write("feature.swift", secret ? "let token = SHIP_TEST_SECRET\n" : "let value = 42\n")
        try f.stage()
        _ = try f.git.run(["commit", "-m", "feat: add branch feature"])
        let head = try XCTUnwrap(f.git.resolve("HEAD"))
        // Git's transport goes to the local bare remote; gh sees the selected GitHub URL.
        let remoteURL = "https://github.com/ship-test/project.git"
        _ = try f.git.run(["config", "url.\(f.remote.absoluteString).insteadOf", remoteURL])
        _ = try f.git.run(["remote", "set-url", "origin", remoteURL])
        let proposal = PullRequestProposal(title: "Add branch feature", body: "## Changes\n\nAdd the branch feature.")
        try f.modelResponse(String(decoding: JSONEncoder().encode(proposal), as: UTF8.self))
        var pr: [String: Any] = ["number": 12, "url": "https://github.com/ship-test/project/pull/12",
                                 "title": proposal.title, "body": proposal.body, "headRefOid": head, "baseRefOid": base,
                                 "headRefName": "feat/pr-flow", "baseRefName": "main", "isCrossRepository": false,
                                 "isDraft": false, "state": "OPEN", "mergeCommit": NSNull()]
        try JSONSerialization.data(withJSONObject: pr).write(to: f.temp.url.appendingPathComponent("open-pr.json"))
        try JSONSerialization.data(withJSONObject: existing ? [pr] : []).write(to: f.temp.url.appendingPathComponent("pr-list.json"))
        pr["state"] = "MERGED"; pr["mergeCommit"] = ["oid": head]
        try JSONSerialization.data(withJSONObject: pr).write(to: f.temp.url.appendingPathComponent("merged-pr.json"))
        let log = shellQuote(f.temp.url.appendingPathComponent("gh-args").path)
        let created = shellQuote(f.temp.url.appendingPathComponent("pr-created").path)
        let merged = shellQuote(f.temp.url.appendingPathComponent("pr-merged").path)
        let body = shellQuote(f.temp.url.appendingPathComponent("pr-body").path)
        try f.script("gh", """
        printf '%s\\n' "$@" >> \(log)
        if [ "$1" = pr ] && [ "$2" = list ]; then
          /bin/cat \(shellQuote(f.temp.url.appendingPathComponent("pr-list.json").path))
        elif [ "$1" = pr ] && [ "$2" = create ]; then
          /bin/cat > \(body)
          /usr/bin/touch \(created)
          printf '%s\\n' 'https://github.com/ship-test/project/pull/12'
        elif [ "$1" = pr ] && [ "$2" = edit ]; then
          /bin/cat > \(body)
        elif [ "$1" = pr ] && [ "$2" = view ]; then
          if [ -f \(merged) ]; then
            /bin/cat \(shellQuote(f.temp.url.appendingPathComponent("merged-pr.json").path))
          else
            /bin/cat \(shellQuote(f.temp.url.appendingPathComponent("open-pr.json").path))
          fi
        elif [ "$1" = pr ] && [ "$2" = merge ]; then
          \(blockedMerge ? "exit 1" : "/usr/bin/git --git-dir " + shellQuote(f.remote.path) + " update-ref refs/heads/main " + shellQuote(head))
          /usr/bin/touch \(merged)
        else
          exit 90
        fi
        """)
        return f
    }

    func testMainCanBeCommittedDirectlyOrOnSuggestedBranch() throws {
        for (choice, expected) in [("1", "main"), ("2", "feat/test-change")] {
            let f = try Fixture(); let previous = try f.git.resolve("HEAD")
            try f.write("a", "change\n")
            let c = ScriptConsole([choice])
            try f.workflow(c).run()
            XCTAssertEqual(try f.git.branch(), expected)
            XCTAssertEqual(try f.remoteHash(expected), try f.git.resolve("HEAD"))
            if choice == "2" { XCTAssertEqual(try f.remoteHash("main"), previous) }
            XCTAssertTrue(c.output.contains("Commit and push directly to main"))
        }
    }

    func testPRGeneratesScannedTextPushesBranchAndPreservesMultilineBody() throws {
        let f = try prepare(); let original = try f.git.resolve("HEAD")
        let c = ScriptConsole(["1", "y"])
        try f.workflow(c, args: ["--pr"]).run()
        XCTAssertEqual(try f.git.branch(), "feat/pr-flow")
        XCTAssertEqual(try f.git.resolve("HEAD"), original)
        XCTAssertEqual(try f.remoteHash("feat/pr-flow"), original)
        XCTAssertEqual(f.model.calls, 1)
        XCTAssertEqual(try Data(contentsOf: f.temp.url.appendingPathComponent("model-input")),
                       try Data(contentsOf: f.temp.url.appendingPathComponent("scanner-input")))
        XCTAssertEqual(try String(contentsOf: f.temp.url.appendingPathComponent("pr-body")), "## Changes\n\nAdd the branch feature.")
        let args = try String(contentsOf: f.temp.url.appendingPathComponent("gh-args"))
        XCTAssertTrue(args.contains("--base\nmain\n--head\nfeat/pr-flow\n"))
        XCTAssertTrue(args.contains("--repo\nhttps://github.com/ship-test/project\n"))
        XCTAssertTrue(c.output.contains("[1] main"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-merged").path))
    }

    func testMergeReusesPRReturnsToMainAndDeletesOnlyReviewedBranch() throws {
        let f = try prepare(existing: true)
        let c = ScriptConsole(["1", "y"])
        try f.workflow(c, args: ["--merge"]).run()
        XCTAssertEqual(try f.git.branch(), "main")
        XCTAssertEqual(try f.git.resolve("HEAD"), try f.remoteHash("main"))
        XCTAssertNil(try f.git.resolve("refs/heads/feat/pr-flow"))
        XCTAssertNil(try f.remoteHash("feat/pr-flow"))
        XCTAssertEqual(f.model.calls, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-created").path))
        let args = try String(contentsOf: f.temp.url.appendingPathComponent("gh-args"))
        XCTAssertTrue(args.contains("--squash\n--match-head-commit\n"))
        XCTAssertFalse(args.contains("--admin"))
    }

    func testDirtyMergeCancellationPreservesStagedAndUnstagedChanges() throws {
        let f = try prepare()
        try f.write("readme.txt", "staged version\n"); try f.stage("readme.txt")
        try f.write("readme.txt", "staged version\nunstaged version\n")
        let tree = try f.git.state().tree
        let c = ScriptConsole([""])
        XCTAssertThrowsError(try f.workflow(c, args: ["--merge"]).run())
        XCTAssertEqual(try f.git.state().tree, tree)
        XCTAssertEqual(try f.read("readme.txt"), "staged version\nunstaged version\n")
        XCTAssertTrue(c.output.contains("still have uncommitted changes"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("gh-args").path))
        XCTAssertEqual(f.model.calls, 0)
    }

    func testBlockedPRPayloadCannotReachModelOrCreatePR() throws {
        let f = try prepare(secret: true)
        let c = ScriptConsole(["1", ""])
        XCTAssertThrowsError(try f.workflow(c, args: ["--pr"]).run())
        XCTAssertFalse(f.modelWasInvoked)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-created").path))
        XCTAssertFalse(c.output.contains("SHIP_TEST_SECRET"))
    }

    func testDirtyPRCanShipChangesThenContinueWithFreshHead() throws {
        let f = try prepare()
        try f.write("feature.swift", "let value = 43\n")
        try f.modelOutput(nil, message: "fix: update the feature")
        let c = ScriptConsole(["s", "y", "1", "y"])
        c.onPrompt = { prompt in
            if prompt.hasPrefix("Target [1]") {
                try f.modelResponse(String(decoding: JSONEncoder().encode(PullRequestProposal(title: "Update feature", body: "Update the branch feature.")), as: UTF8.self))
                let url = f.temp.url.appendingPathComponent("open-pr.json")
                var pr = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                pr["headRefOid"] = try f.git.resolve("HEAD")
                try JSONSerialization.data(withJSONObject: pr).write(to: url)
            }
        }
        try f.workflow(c, args: ["--pr"]).run()
        XCTAssertFalse(try f.git.dirty())
        XCTAssertEqual(try f.remoteHash("feat/pr-flow"), try f.git.resolve("HEAD"))
        XCTAssertEqual(f.model.calls, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-created").path))
    }

    func testRejectedMergeKeepsWorkBranchAndReportsPR() throws {
        let f = try prepare(blockedMerge: true)
        let c = ScriptConsole(["1", "y"])
        XCTAssertThrowsError(try f.workflow(c, args: ["--merge"]).run())
        XCTAssertEqual(try f.git.branch(), "feat/pr-flow")
        XCTAssertNotNil(try f.remoteHash("feat/pr-flow"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-merged").path))
        XCTAssertTrue(c.output.contains("https://github.com/ship-test/project/pull/12"))
    }

    func testChangeDuringPRReviewStopsPublication() throws {
        let f = try prepare()
        let c = ScriptConsole(["1", "y"])
        c.onPrompt = { prompt in
            if prompt.contains("create/update PR") { try f.write("new-file", "unreviewed\n") }
        }
        XCTAssertThrowsError(try f.workflow(c, args: ["--pr"]).run())
        XCTAssertNil(try f.remoteHash("feat/pr-flow"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.temp.url.appendingPathComponent("pr-created").path))
    }

    func testPRProposalAndOptionsValidation() throws {
        XCTAssertThrowsError(try PullRequestProposal(title: "bad\ntitle", body: "Description").validate())
        XCTAssertThrowsError(try PullRequestProposal(title: "Title", body: "escape \u{1B}").validate())
        XCTAssertThrowsError(try PullRequestProposal.decode(Data(#"{"title":"Title","body":"Body","command":"shell"}"#.utf8)))
        XCTAssertThrowsError(try Options(["--merge", "--staged"]))
        XCTAssertTrue(try Options(["--pr"]).pullRequest)
        XCTAssertTrue(try Options(["--merge"]).merge)
        XCTAssertEqual(try GitHubRepository(remoteURL: "git@github.com:you/project.git").url, "https://github.com/you/project")
    }
}
