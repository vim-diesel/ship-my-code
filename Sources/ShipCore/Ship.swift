import Foundation

public enum Ship {
    public static func run(arguments: [String], directory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) -> Int32 {
        let console = TerminalConsole()
        var workflow: Workflow?
        do {
            let options = try Options(arguments)
            if options.help { console.write(Options.usage); return 0 }
            let runner = ProcessRunner()
            let task = Workflow(options: options, directory: directory, runner: runner, console: console,
                                    scanner: GitleaksScanner(runner: runner), model: CommandCode(runner: runner))
            workflow = task
            try task.run()
            return 0
        } catch {
            console.write((error as? ShipError)?.description ?? "ship couldn't finish. Run git status to check the current state.")
            if let note = workflow?.localChangesNote { console.write(note) }
            if case ShipError.cancelled = error { return Interrupt.requested ? 130 : 0 }
            return 1
        }
    }
}

final class Workflow {
    let options: Options
    let directory: URL
    let runner: ProcessRunner
    let console: Console
    let scanner: Scanning
    let model: Generating
    private var remediationApplied = false
    private var activeGit: Git?

    var localChangesNote: String? {
        if remediationApplied { return "Your approved file and ignore changes have been kept." }
        if let git = activeGit, (try? git.hasChanges()) == true { return "Your selected changes are still staged for a future commit." }
        return nil
    }

    init(options: Options, directory: URL, runner: ProcessRunner, console: Console, scanner: Scanning, model: Generating) {
        self.options = options; self.directory = directory; self.runner = runner
        self.console = console; self.scanner = scanner; self.model = model
    }

    func run() throws {
        guard console.interactive else { throw ShipError.message("ship requires an interactive terminal on stdin and stdout. Use ship --help for usage.") }
        let git = try RepositorySetup(runner: runner, console: console).prepare(directory: directory, remote: options.remote)
        activeGit = git
        try git.preflight()
        if !options.staged {
            console.write("Staging changes across the whole repository with git add -A.")
            _ = try git.run(["add", "-A", "--", "."])
        } else if try git.hasExcludedChanges() {
            console.write("--staged: unstaged and untracked changes are excluded and remain untouched.")
        }
        let initial = try git.state()
        let firstCommitOnMain = initial.head == nil && initial.branch == "main"
        let needsBranch = try !firstCommitOnMain && git.protectedBranches().contains(initial.branch)
        console.write("Repository: \(display(git.root.path))\nBranch:     \(display(initial.branch))")
        if firstCommitOnMain { console.write("Your first commit will establish main. Later changes will use work branches.") }
        var localSuggestion = false
        while true {
            try git.preflight()
            guard try git.branch() == initial.branch, try git.resolve("HEAD") == initial.head else {
                throw ShipError.message("Branch or HEAD changed during remediation. Run ship again for a fresh review.")
            }
            guard try git.hasChanges() else { try pushOnly(git); return }
            let state = try git.state()
            console.write(display(try git.text(["diff", "--cached", "--stat", "--no-ext-diff", "--no-textconv"]), multiline: true))
            let payload = try Payload.build(git: git, state: state, needsBranch: needsBranch)
            let scan = scanner.scan(payload)
            try git.verify(state)
            if localSuggestion {
                showFindings(scan)
                console.write("Local suggestion (no model invocation): chore: stop tracking local environment file")
                let proposal = try manual(git, needsBranch: needsBranch,
                                          existing: Proposal(branch: nil, message: "chore: stop tracking local environment file"))
                try reviewAndShip(git, state: state, proposal: proposal, scan: scan, source: "local suggestion, editable")
                return
            }
            if !scan.permitsModel {
                showFindings(scan)
                console.write("Nothing has been sent to the model.")
                let actions = try remediationActions(scan, git: git)
                for (i, action) in actions.enumerated() { console.write("  [\(i + 1)] \(action.label)") }
                let removedOnly = !scan.findings.isEmpty && scan.findings.allSatisfy(\.removed)
                if removedOnly { console.write("  [l] Use a local, editable secret-removal message") }
                console.write("  [r] Recheck after manually staging a fix in another terminal\n  [m] Enter commit details manually without the model\n  [N] Cancel")
                let choice = try console.read("Choose:").lowercased()
                if choice == "m" {
                    let proposal = try manual(git, needsBranch: needsBranch)
                    try reviewAndShip(git, state: state, proposal: proposal, scan: scan, source: "manual; no model invocation")
                    return
                }
                if choice == "l" && removedOnly {
                    console.write("Local suggestion (no model invocation): chore: remove sensitive local data")
                    let proposal = try manual(git, needsBranch: needsBranch,
                                              existing: Proposal(branch: nil, message: "chore: remove sensitive local data"))
                    try reviewAndShip(git, state: state, proposal: proposal, scan: scan, source: "local suggestion, editable")
                    return
                }
                if choice == "r" { continue }
                guard let number = Int(choice), actions.indices.contains(number - 1) else { throw ShipError.cancelled }
                let action = actions[number - 1]
                do {
                    if action.ignore {
                        if action.tracked {
                            console.write("The next commit will remove \(display(action.path)) from version control. The local copy will remain. Earlier history is unchanged.")
                            guard try console.read("[y] stop tracking and add an exact ignore rule  [N] cancel").lowercased() == "y" else { throw ShipError.cancelled }
                        }
                        try Remediation.ignoreAndUntrack(action.path, git: git, state: state)
                        remediationApplied = true
                        localSuggestion = action.tracked
                        console.write("Kept the local file, removed it from the index, and staged only the intended .gitignore addition. These edits remain if you cancel.")
                    } else {
                        try Remediation.editSource(action.path, git: git, console: console, state: state)
                    }
                } catch ShipError.cancelled { throw ShipError.cancelled }
                catch {
                    console.write((error as? ShipError)?.description ?? "Automatic remediation could not safely preserve the index/worktree. Handle the change manually.")
                    console.write("Use manual entry, or stage a fix in another terminal and recheck.")
                }
                continue
            }
            console.write("Local checks: no findings in the outbound payload (best effort).")
            var proposal: Proposal
            var source = "model suggestion"
            do {
                try git.verify(state)
                proposal = try model.generate(payload.data, needsBranch: needsBranch)
                try Proposal.validateMessage(proposal.message)
                if needsBranch {
                    guard let branch = proposal.branch else { throw ShipError.message("Model omitted the required new branch.") }
                    try git.validateNewBranch(branch)
                } else if proposal.branch != nil { throw ShipError.message("Model tried to rename an existing work branch.") }
            } catch ShipError.cancelled { throw ShipError.cancelled }
            catch {
                console.write((error as? ShipError)?.description ?? "Model generation failed. Raw output was withheld.")
                guard try console.read("[m] enter details manually without another model call  [N] cancel").lowercased() == "m" else { throw ShipError.cancelled }
                proposal = try manual(git, needsBranch: needsBranch)
                source = "manual"
            }
            try reviewAndShip(git, state: state, proposal: proposal, scan: scan, source: source)
            return
        }
    }

    private struct Action {
        let path: String
        let ignore: Bool
        let tracked: Bool
        var label: String {
            if ignore { return "\(tracked ? "Stop tracking this file" : "Ignore this file") and keep it locally: \(display(path))" }
            return "Open configured editor, then review and recheck: \(display(path))"
        }
    }

    private func remediationActions(_ scan: ScanResult, git: Git) throws -> [Action] {
        let paths = Set(scan.findings.compactMap(\.path)).sorted()
        return try paths.compactMap { path in
            guard Remediation.regularLocalFile(path, git: git), try git.entry(path) != nil else { return nil }
            return Action(path: path, ignore: Payload.sensitivePath(path) != nil,
                          tracked: try git.entry(path, head: true) != nil)
        }
    }

    private func showFindings(_ scan: ScanResult) {
        if let unavailable = scan.unavailable { console.write(unavailable) }
        for finding in scan.findings {
            let location = finding.location.map { " (\($0))" } ?? ""
            console.write("  \(display(finding.path ?? "outbound payload"))\(location): \(finding.reason)")
        }
    }

    private func manual(_ git: Git, needsBranch: Bool, existing: Proposal? = nil) throws -> Proposal {
        var branch = existing?.branch
        if needsBranch {
            while true {
                let input = try console.read("New branch\(branch.map { " [\(display($0))]" } ?? ""):")
                let value = input.isEmpty ? (branch ?? "") : input
                do { try git.validateNewBranch(value); branch = value; break }
                catch { console.write((error as? ShipError)?.description ?? "Invalid branch.") }
            }
        }
        while true {
            let input = try console.read("Commit message\(existing.map { " [\(display($0.message))]" } ?? ""):")
            let value = input.isEmpty ? (existing?.message ?? "") : input
            do { try Proposal.validateMessage(value); return Proposal(branch: needsBranch ? branch : nil, message: value) }
            catch { console.write((error as? ShipError)?.description ?? "Invalid message.") }
        }
    }

    private func showComparison(_ comparison: PushComparison, newCommit: Bool) {
        console.write("Push preview uses locally known remote state, which may be stale; no fetch was performed.")
        guard let reference = comparison.reference, comparison.hash != nil else {
            console.write("Outgoing commit count is unknown: no reliable local comparison is available. Existing history may accompany this \(newCommit ? "commit" : "branch").")
            return
        }
        console.write("Existing local commits beyond \(display(reference)): \(comparison.commits.count)\(newCommit ? " (plus the proposed new commit)" : "")")
        for commit in comparison.commits { console.write("  " + display(commit)) }
    }

    private func reviewAndShip(_ git: Git, state: RepositoryState, proposal initialProposal: Proposal, scan: ScanResult, source: String) throws {
        var proposal = initialProposal
        while true {
            let branch = proposal.branch ?? state.branch
            let comparison = try git.comparison(branch: branch)
            let identity = try git.remoteIdentity()
            console.write("\nCurrent branch: \(display(state.branch))")
            if let newBranch = proposal.branch { console.write("Create branch:  \(display(newBranch))") }
            console.write("Commit:         \(display(proposal.message))\nPush to:        \(display(git.remote))/\(display(branch))\nDetails:        \(source)")
            if !scan.findings.isEmpty {
                console.write("Unresolved findings remain in the proposed commit/diff. Manual entry does not make this commit secret-free.")
                showFindings(scan)
                if scan.findings.contains(where: \.removed) { console.write("Deleted-line/path findings still occur in the deletion diff; earlier history is unchanged.") }
            } else if let unavailable = scan.unavailable {
                console.write("Content was NOT SCANNED successfully; this commit has not been checked for secrets. \(unavailable)")
            }
            showComparison(comparison, newCommit: true)
            switch try console.read("[y] proceed  [e] edit  [d] review complete staged diff locally  [N] cancel").lowercased() {
            case "e": proposal = try manual(git, needsBranch: proposal.branch != nil, existing: proposal)
            case "d":
                try git.verify(state)
                console.write("Complete staged diff (local only; may contain sensitive data):")
                console.write(display(try git.stagedDiff(), multiline: true))
            case "y":
                try git.verify(state)
                try validatePushReview(git, branch: branch, comparison: comparison, identity: identity)
                if let newBranch = proposal.branch { try git.validateNewBranch(newBranch) }
                try Proposal.validateMessage(proposal.message)
                try commitAndPush(git, state: state, proposal: proposal, identity: identity)
                return
            default:
                if remediationApplied { console.write("Approved ignore/index edits remain in place.") }
                throw ShipError.cancelled
            }
        }
    }

    private func validatePushReview(_ git: Git, branch: String, comparison: PushComparison, identity: Data) throws {
        let state = try git.state()
        let initialMain = try branch == state.branch && git.allowsInitialMain(state)
        guard try initialMain || !git.protectedBranches().contains(branch) else { throw ShipError.message("Refusing to commit or push to a protected branch.") }
        guard try git.comparison(branch: branch) == comparison, try git.remoteIdentity() == identity else {
            throw ShipError.message("Remote destination or locally known remote state changed after review. Run ship again for a fresh review.")
        }
    }

    private func commitAndPush(_ git: Git, state: RepositoryState, proposal: Proposal, identity: Data) throws {
        let branch = proposal.branch ?? state.branch
        if proposal.branch != nil {
            _ = try git.run(["switch", "-c", branch])
            console.write("Created and checked out \(display(branch)).")
        }
        let approved = RepositoryState(branch: branch, head: state.head, tree: state.tree)
        do {
            try git.verify(approved)
            _ = try git.run(["-c", "commit.verbose=false", "commit", "--no-status", "--cleanup=verbatim", "-m", proposal.message])
        } catch {
            if proposal.branch != nil { console.write("The new branch \(display(branch)) was created; no rollback was attempted.") }
            if let current = try? git.branch() { console.write("Currently checked out: \(display(current)).") }
            if let current = try? git.resolve("HEAD"), current != state.head { console.write("HEAD changed during the commit attempt; a commit may exist locally. Nothing was pushed.") }
            throw error
        }
        console.write("Commit created locally.")
        // Hooks may change the index, tree, message, parent, or even the checked-out branch.
        let actual = try git.state()
        let message = try git.text(["log", "-1", "--format=%B"])
        let parents = try git.text(["log", "-1", "--format=%P"])
        let tree = try git.text(["rev-parse", "HEAD^{tree}"])
        guard actual.branch == branch, actual.head != state.head, tree == state.tree,
              actual.tree == state.tree, message.removingFinalNewline == proposal.message,
              parents == (state.head ?? "") else {
            throw ShipError.message("The commit/hook result differs from the reviewed branch, content, message, or parent. The commit exists locally. Stopped before pushing; inspect it locally.")
        }
        guard try git.remoteIdentity() == identity else { throw ShipError.message("Commit exists locally, but the remote destination changed. Stopped before pushing.") }
        try push(git, state: actual, branch: branch)
    }

    private func pushOnly(_ git: Git) throws {
        let state = try git.state()
        guard state.head != nil, try git.allowsInitialMain(state) || !git.protectedBranches().contains(state.branch) else {
            console.write("Nothing to ship."); return
        }
        let comparison = try git.comparison(branch: state.branch)
        if comparison.destinationExists && comparison.commits.isEmpty { console.write("Nothing to ship."); return }
        let identity = try git.remoteIdentity()
        console.write("No staged changes. \(comparison.destinationExists ? "Push existing local commits" : "Publish this work branch") to \(display(git.remote))/\(display(state.branch)).")
        showComparison(comparison, newCommit: false)
        guard try console.read("[y] push this branch only  [N] cancel").lowercased() == "y" else { throw ShipError.cancelled }
        try git.verify(state)
        try validatePushReview(git, branch: state.branch, comparison: comparison, identity: identity)
        try push(git, state: state, branch: state.branch)
    }

    private func push(_ git: Git, state: RepositoryState, branch: String) throws {
        try git.verify(state)
        let initialMain = try branch == state.branch && git.allowsInitialMain(state)
        guard try initialMain || !git.protectedBranches().contains(branch) else { throw ShipError.message("Refusing to push a protected branch. Any new commit remains local.") }
        do { _ = try git.run(git.pushArguments(branch: branch)) }
        catch {
            console.write("Push did not complete successfully. The commit exists locally; the remote may have received it. Rerun ship to review recovery, or retry exactly:")
            console.write(git.retryCommand(branch: branch))
            throw error
        }
        console.write("Shipped \(display(branch)) to \(display(git.remote))/\(display(branch)); upstream set.")
    }
}
