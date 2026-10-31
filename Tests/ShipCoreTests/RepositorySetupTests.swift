import Foundation
import XCTest
@testable import ShipCore

final class RepositorySetupTests: XCTestCase {
    private func fakeGitHub(_ f: Fixture) throws {
        try f.script("gh", """
        if [ "$1" = auth ]; then exit 0; fi
        /usr/bin/printf '%s\\n' "$@" > \(shellQuote(f.temp.url.appendingPathComponent("gh-args").path))
        for arg in "$@"; do if [ "$arg" = --push ]; then exit 90; fi; done
        /usr/bin/git -C "$6" remote add "$8" \(shellQuote(f.remote.path))
        """)
    }

    func testNewFolderInitializesCreatesPrivateRemoteAndShipsAfterApproval() throws {
        let f = try Fixture(initial: false)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(".git"))
        try fakeGitHub(f)
        let c = ScriptConsole(["y", "1", "", "y"])
        try f.workflow(c).run()
        XCTAssertEqual(try f.git.branch(), "feat/test-change")
        XCTAssertNotNil(try f.remoteHash("feat/test-change"))
        let args = try String(contentsOf: f.temp.url.appendingPathComponent("gh-args"))
        XCTAssertTrue(args.contains("--private\n"))
        XCTAssertTrue(args.contains("create\nwork\n"))
        XCTAssertTrue(c.output.contains("No code has been uploaded yet"))
    }

    func testPublicSetupRespectsSelectedRemoteAndCancellationDoesNotPublish() throws {
        let f = try Fixture()
        _ = try f.git.run(["remote", "remove", "origin"])
        try f.write("feature.swift", "let value = 1\n")
        try fakeGitHub(f)
        let c = ScriptConsole(["2", "my-custom-repo", ""])
        XCTAssertThrowsError(try f.workflow(c, args: ["--remote", "upstream"]).run())
        XCTAssertEqual(try f.git.remotes(), ["upstream"])
        XCTAssertNil(try f.remoteHash("feat/test-change"))
        XCTAssertEqual(try f.git.branch(), "main")
        let args = try String(contentsOf: f.temp.url.appendingPathComponent("gh-args"))
        XCTAssertTrue(args.contains("--public\n"))
        XCTAssertTrue(args.contains("create\nmy-custom-repo\n"))
        XCTAssertTrue(args.contains("--remote\nupstream\n"))
    }

    func testCancellingSetupLeavesFolderAndIndexAlone() throws {
        let f = try Fixture()
        _ = try f.git.run(["remote", "remove", "origin"])
        try f.write("unstaged.swift", "let value = 1\n")
        XCTAssertThrowsError(try f.workflow(ScriptConsole([""])).run())
        XCTAssertNil(try f.git.entry("unstaged.swift"))
        XCTAssertFalse(f.modelWasInvoked)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent(".git"))
        XCTAssertThrowsError(try f.workflow(ScriptConsole([""])).run())
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.root.appendingPathComponent(".git").path))
    }

    func testExistingRepositoryCanBeConnectedWithoutGitHubCLI() throws {
        let f = try Fixture()
        _ = try f.git.run(["remote", "remove", "origin"])
        let c = ScriptConsole(["e", f.remote.path])
        let git = try RepositorySetup(runner: f.runner, console: c).prepare(directory: f.root, remote: "origin")
        XCTAssertEqual(try git.remotes(), ["origin"])
        XCTAssertEqual(try git.text(["remote", "get-url", "origin"]), f.remote.path)
        XCTAssertFalse(f.modelWasInvoked)
    }

    func testExistingConnectionCanBeChosenAndBrokenGitDoesNotOfferInitialization() throws {
        let f = try Fixture()
        _ = try f.git.run(["remote", "rename", "origin", "upstream"])
        let git = try RepositorySetup(runner: f.runner, console: ScriptConsole(["r1"]))
            .prepare(directory: f.root, remote: "origin")
        XCTAssertEqual(git.remote, "upstream")
        let c = ScriptConsole(["y"])
        XCTAssertThrowsError(try RepositorySetup(runner: f.runner, console: c)
            .prepare(directory: f.root.appendingPathComponent(".git"), remote: "origin"))
        XCTAssertEqual(c.answers, ["y"])
    }
}
