import Foundation
import XCTest
@testable import ShipCore

final class ScriptConsole: Console {
    var interactive = true
    var answers: [String]
    var output = ""
    var onPrompt: ((String) throws -> Void)?
    init(_ answers: [String]) { self.answers = answers }
    func write(_ text: String) { output += text + "\n" }
    func read(_ prompt: String) throws -> String {
        output += prompt + "\n"
        try onPrompt?(prompt)
        guard !answers.isEmpty else { throw ShipError.cancelled }
        return answers.removeFirst()
    }
}

// Exercise the production adapter against the fixture's fake cmd executable.
final class RecordingModel: Generating {
    private let commandCode: CommandCode
    var calls = 0
    init(runner: ProcessRunner) { commandCode = CommandCode(runner: runner) }
    func generate(_ payload: Data, needsBranch: Bool) throws -> Proposal {
        calls += 1
        return try commandCode.generate(payload, needsBranch: needsBranch)
    }
    func generatePullRequest(_ payload: Data) throws -> PullRequestProposal {
        calls += 1
        return try commandCode.generatePullRequest(payload)
    }
}

final class Fixture {
    let temp: TemporaryDirectory
    let root: URL
    let remote: URL
    let bin: URL
    let runner: ProcessRunner
    let git: Git
    let scanner: GitleaksScanner
    let model: RecordingModel

    init(initial: Bool = true, branch: String = "main") throws {
        temp = try TemporaryDirectory()
        root = temp.url.appendingPathComponent("work")
        remote = temp.url.appendingPathComponent("remote.git")
        bin = temp.url.appendingPathComponent("bin")
        for url in [root, bin] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["PATH"] = bin.path + ":/usr/bin:/bin"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_AUTHOR_NAME"] = "Ship Test"
        env["GIT_AUTHOR_EMAIL"] = "ship@example.invalid"
        env["GIT_COMMITTER_NAME"] = "Ship Test"
        env["GIT_COMMITTER_EMAIL"] = "ship@example.invalid"
        env["LC_ALL"] = "C"
        env["VISUAL"] = bin.appendingPathComponent("editor").path
        runner = ProcessRunner(environment: env)
        _ = try runner.run("/usr/bin/git", ["init", "--initial-branch", branch, root.path], cwd: temp.url)
        _ = try runner.run("/usr/bin/git", ["init", "--bare", "--initial-branch", branch, remote.path], cwd: temp.url)
        _ = try runner.run("/usr/bin/git", ["-C", root.path, "remote", "add", "origin", remote.path], cwd: temp.url)
        git = try Git(runner: runner, directory: root, remote: "origin")
        scanner = GitleaksScanner(runner: runner)
        model = RecordingModel(runner: runner)
        try write("readme.txt", "initial\n")
        if initial {
            _ = try git.run(["add", "readme.txt"])
            _ = try git.run(["commit", "-m", "chore: initial"])
            _ = try git.run(git.pushArguments(branch: branch))
            _ = try git.run(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/" + branch])
        }
        try modelOutput((branch == "main" && initial) || branch == "master" ? "feat/test-change" : nil)
        try script("cmd", """
        if [ "$1" = "--help" ]; then
          printf '%s\\n' 'Command Code --mod --no-skills --no-session --max-turns --permission-mode --no-auto-update --skip-onboarding'
          exit 0
        fi
        /bin/cat > \(shellQuote(temp.url.appendingPathComponent("model-input").path))
        /bin/pwd > \(shellQuote(temp.url.appendingPathComponent("model-cwd").path))
        /bin/cat \(shellQuote(temp.url.appendingPathComponent("model-output").path))
        printf '%s\\n' 'stderr must not be parsed as JSON' >&2
        """)
        try script("gitleaks", """
        if [ "$2" = "--help" ]; then
          printf '%s\\n' '--config --redact --ignore-gitleaks-allow --gitleaks-ignore-path --exit-code --max-target-megabytes --report-format --report-template --report-path --no-banner --no-color --log-level'
          exit 0
        fi
        /bin/cat > \(shellQuote(temp.url.appendingPathComponent("scanner-input").path))
        /usr/bin/awk '
          BEGIN { printf "["; found=0 }
          /SHIP_TEST_SECRET|ghp_/ {
            if(found) printf ",";
            printf "{\\"line\\":%d,\\"endLine\\":%d,\\"rule\\":\\"test-secret\\"}", NR, NR;
            found=1
          }
          END { print "]"; if(found) exit 23 }
        ' \(shellQuote(temp.url.appendingPathComponent("scanner-input").path))
        """)
    }

    func write(_ name: String, _ text: String) throws { try writeData(name, Data(text.utf8)) }
    func writeData(_ name: String, _ data: Data) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }
    func read(_ name: String) throws -> String { try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8) }
    func script(_ name: String, _ body: String) throws {
        let url = bin.appendingPathComponent(name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
    func hook(_ name: String, _ body: String, bare: Bool = false) throws {
        let file = (bare ? remote : root.appendingPathComponent(".git")).appendingPathComponent("hooks/" + name)
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    }
    func modelOutput(_ branch: String?, message: String = "feat: add test change") throws {
        let object: [String: Any] = ["branch": branch as Any? ?? NSNull(), "message": message]
        let proposal = try JSONSerialization.data(withJSONObject: object)
        try modelResponse(String(decoding: proposal, as: UTF8.self))
    }
    func modelResponse(_ text: String) throws {
        try JSONSerialization.data(withJSONObject: ["shipBridge": 1, "text": text])
            .write(to: temp.url.appendingPathComponent("model-output"))
    }
    func workBranch(_ branch: String = "work/test") throws {
        _ = try git.run(["switch", "-c", branch])
        try modelOutput(nil)
    }
    func stage(_ path: String = ".") throws { _ = try git.run(["add", "--", path]) }
    func workflow(_ console: ScriptConsole, args: [String] = [], model: Generating? = nil, directory: URL? = nil) throws -> Workflow {
        try Workflow(options: Options(args), directory: directory ?? root, runner: runner, console: console,
                     scanner: scanner, model: model ?? self.model)
    }
    func remoteHash(_ branch: String) throws -> String? {
        let result = try runner.run("/usr/bin/git", ["--git-dir", remote.path, "rev-parse", "--verify", "--quiet", "refs/heads/" + branch], cwd: temp.url)
        return result.status == 0 ? try utf8(result.stdout).removingFinalNewline : nil
    }
    var modelWasInvoked: Bool { FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("model-input").path) }
}
