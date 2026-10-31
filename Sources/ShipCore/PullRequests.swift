import Foundation

struct GitHubRepository: Equatable {
    let url: String

    init(remoteURL: String) throws {
        var raw = remoteURL
        if !raw.contains("://"), let colon = raw.firstIndex(of: ":"), raw[..<colon].contains("@") {
            let host = raw[..<colon].split(separator: "@").last ?? ""
            raw = "https://\(host)/" + raw[raw.index(after: colon)...]
        }
        guard let parts = URLComponents(string: raw), ["https", "ssh", "git"].contains(parts.scheme ?? ""),
              let host = parts.host, parts.query == nil, parts.fragment == nil else {
            throw ShipError.message("PRs need a GitHub HTTPS or SSH remote. Check git remote -v.")
        }
        var path = parts.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard path.range(of: "^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            throw ShipError.message("Couldn't identify the GitHub owner/repository from this remote.")
        }
        url = "https://\(host)/\(path)"
    }
}

private struct GitHubPR: Decodable {
    let number: Int
    let url: String
    let title: String
    let body: String
    let headRefOid: String
    let baseRefOid: String
    let headRefName: String
    let baseRefName: String
    let isCrossRepository: Bool
    let isDraft: Bool
    let state: String
    let mergeCommit: MergeCommit?
    struct MergeCommit: Decodable { let oid: String }
}

final class PullRequestFlow {
    let git: Git
    let console: Console
    let scanner: Scanning
    let model: Generating
    private let fields = "number,url,title,body,headRefOid,baseRefOid,headRefName,baseRefName,isCrossRepository,isDraft,state,mergeCommit"

    init(git: Git, console: Console, scanner: Scanning, model: Generating) {
        self.git = git; self.console = console; self.scanner = scanner; self.model = model
    }

    func run(merge: Bool, shipChanges: () throws -> Void) throws {
        let initialBranch = try git.branch()
        guard try !git.protectedBranches().contains(initialBranch) else {
            throw ShipError.message("You're on \(display(initialBranch)). PRs and merges start from a work branch. Use ship for a direct commit or to create a branch.")
        }
        guard try git.resolve("HEAD") != nil else { throw ShipError.message("Make your first commit with ship before opening a PR.") }
        guard let gh = git.runner.executable("gh") else { throw ShipError.message("Install GitHub CLI with brew install gh, then run gh auth login.") }
        let repository = try selectedRepository()
        if try git.dirty() {
            console.write("You asked for a \(merge ? "merge" : "PR"), but you still have uncommitted changes here.")
            console.write(display(try git.text(["status", "--short"]), multiline: true))
            guard try console.read("[s] Ship these changes first, then continue  [N] Cancel").lowercased() == "s" else { throw ShipError.cancelled }
            try shipChanges()
            guard try !git.dirty(), try git.branch() == initialBranch else {
                throw ShipError.message("Some changes remain, or the branch changed. Finish shipping them, then rerun ship \(merge ? "--merge" : "--pr").")
            }
        }
        let state = try git.state()
        let identity = try git.remoteIdentity()
        console.write("Checking branches on \(display(git.remote))…")
        try git.fetchBranches()
        let target = try selectTarget(source: state.branch)
        let targetRef = "refs/remotes/\(git.remote)/\(target)"
        guard let targetHead = try git.resolve(targetRef) else { throw ShipError.message("The selected target disappeared. Run ship again.") }
        let ancestor = try git.run(["merge-base", targetHead, state.head!], accepted: [0, 1])
        guard ancestor.status == 0 else { throw ShipError.message("These branches don't share history, so ship can't prepare their PR.") }
        let base = try utf8(ancestor.stdout).removingFinalNewline
        let commits = try git.text(["log", "--reverse", "--format=%h %s", targetHead + "..HEAD", "--"])
        guard !commits.isEmpty else { console.write("Nothing to merge: this branch has no commits beyond \(display(target))."); return }
        let existing = try existingPR(gh, repository: repository, source: state.branch, target: target)
        let remoteHead = try git.resolve("refs/remotes/\(git.remote)/\(state.branch)")
        let needsPush = remoteHead != state.head
        var proposal: PullRequestProposal
        var scan: ScanResult?
        if let existing {
            proposal = PullRequestProposal(title: existing.title, body: existing.body)
            console.write("Using existing PR: \(display(existing.url))")
        } else {
            let payload = try Payload.build(git: git, state: state, needsBranch: false, base: base, target: target)
            let result = scanner.scan(payload)
            scan = result
            if result.permitsModel {
                do { proposal = try model.generatePullRequest(payload.data) }
                catch ShipError.cancelled { throw ShipError.cancelled }
                catch {
                    console.write((error as? ShipError)?.description ?? "Couldn't generate PR text.")
                    guard try console.read("[m] Write PR details manually  [N] Cancel").lowercased() == "m" else { throw ShipError.cancelled }
                    proposal = try edit(nil)
                }
            } else {
                showFindings(result)
                console.write("Nothing was sent to cmd.")
                guard try console.read("[m] Write PR details manually  [N] Cancel").lowercased() == "m" else { throw ShipError.cancelled }
                proposal = try edit(nil)
            }
        }
        while true {
            try proposal.validate()
            console.write("\n\(display(state.branch)) → \(display(target))\nRepository: \(display(repository.url))")
            console.write("Commits included:\n" + display(commits, multiline: true))
            console.write("Title: \(display(proposal.title))\n\n" + display(proposal.body, multiline: true))
            if needsPush { console.write("The branch's committed changes will be pushed first.") }
            if let scan, !scan.permitsModel { showFindings(scan) }
            if merge { console.write("On approval: squash merge the PR, return to \(display(target)), and delete the work branch after verifying the merge. GitHub's required checks still apply.") }
            let action = merge ? "merge and clean up" : "create/update PR"
            switch try console.read("[y] \(action)  [e] Edit PR text  [d] Review branch diff  [N] Cancel").lowercased() {
            case "e": proposal = try edit(proposal)
            case "d": console.write(display(try git.branchDiff(from: base), multiline: true))
            case "y":
                try verify(state, identity: identity, repository: repository, targetRef: targetRef, targetHead: targetHead)
                if needsPush {
                    guard try git.resolve("refs/remotes/\(git.remote)/\(state.branch)") == remoteHead else { throw ShipError.message("The branch's remote state changed. Review again.") }
                    do { _ = try git.run(git.pushArguments(branch: state.branch)) }
                    catch { throw ShipError.message("The push didn't finish. Your commits are local; the remote may have received them. Rerun ship \(merge ? "--merge" : "--pr") to check before continuing.") }
                }
                try verify(state, identity: identity, repository: repository, targetRef: targetRef, targetHead: targetHead)
                let pr = try publish(gh, repository: repository, state: state, target: target, proposal: proposal, existing: existing)
                console.write("PR: \(display(pr.url))")
                guard merge else { return }
                try mergePR(gh, pr: pr, repository: repository, state: state, target: target, targetRef: targetRef, targetHead: targetHead, identity: identity)
                return
            default: throw ShipError.cancelled
            }
        }
    }

    private func selectedRepository() throws -> GitHubRepository {
        let push = try git.run(["config", "--get-all", "remote.\(git.remote).pushurl"], accepted: [0, 1])
        let data = push.status == 0 ? push.stdout : try git.run(["config", "--get-all", "remote.\(git.remote).url"]).stdout
        let urls = try utf8(data).split(separator: "\n").map(String.init)
        guard urls.count == 1 else { throw ShipError.message("PR operations need a remote with one repository destination.") }
        return try GitHubRepository(remoteURL: urls[0])
    }

    private func selectTarget(source: String) throws -> String {
        let branches = try git.remoteBranches().filter { $0 != source }.sorted {
            if $0 == "main" { return true }; if $1 == "main" { return false }; return $0 < $1
        }
        guard !branches.isEmpty else { throw ShipError.message("There's no other remote branch to merge into. Publish main first.") }
        console.write("Which branch do you want to merge into?")
        for (i, branch) in branches.enumerated() { console.write("  [\(i + 1)] \(display(branch))") }
        while true {
            let answer = try console.read("Target [1] (Enter selects 1; n cancels):").lowercased()
            if answer == "n" { throw ShipError.cancelled }
            if let choice = Int(answer.isEmpty ? "1" : answer), branches.indices.contains(choice - 1) { return branches[choice - 1] }
            console.write("Choose a branch number, or n to cancel.")
        }
    }

    private func invoke(_ gh: String, _ args: [String], repository: GitHubRepository, input: Data = Data()) throws -> CommandResult {
        var environment = git.runner.environment
        environment["GH_PROMPT_DISABLED"] = "1"
        return try git.runner.run(gh, args + ["--repo", repository.url], cwd: git.root, input: input, environment: environment, timeout: 90)
    }

    private func existingPR(_ gh: String, repository: GitHubRepository, source: String, target: String) throws -> GitHubPR? {
        let result = try invoke(gh, ["pr", "list", "--state", "open", "--head", source, "--base", target, "--limit", "20", "--json", fields], repository: repository)
        guard result.status == 0, let prs = try? JSONDecoder().decode([GitHubPR].self, from: result.stdout) else {
            throw ShipError.message("Couldn't check existing PRs. Check gh auth status and your connection, then rerun ship.")
        }
        return prs.first { !$0.isCrossRepository && $0.headRefName == source && $0.baseRefName == target }
    }

    private func view(_ gh: String, number: Int, repository: GitHubRepository) throws -> GitHubPR {
        let result = try invoke(gh, ["pr", "view", String(number), "--json", fields], repository: repository)
        guard result.status == 0, let pr = try? JSONDecoder().decode(GitHubPR.self, from: result.stdout), pr.number == number else {
            throw ShipError.message("Couldn't confirm the PR's current state. Check it on GitHub before rerunning ship.")
        }
        return pr
    }

    private func publish(_ gh: String, repository: GitHubRepository, state: RepositoryState, target: String,
                         proposal: PullRequestProposal, existing: GitHubPR?) throws -> GitHubPR {
        let number: Int
        if let existing {
            number = existing.number
            if proposal != PullRequestProposal(title: existing.title, body: existing.body) {
                let result = try invoke(gh, ["pr", "edit", String(number), "--title", proposal.title, "--body-file", "-"], repository: repository, input: Data(proposal.body.utf8))
                guard result.status == 0 else { throw ShipError.message("Couldn't update the PR text. Check \(display(existing.url)) before retrying.") }
            }
        } else {
            let result = try invoke(gh, ["pr", "create", "--base", target, "--head", state.branch, "--title", proposal.title, "--body-file", "-"], repository: repository, input: Data(proposal.body.utf8))
            let url = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.status == 0, url.lowercased().hasPrefix(repository.url.lowercased() + "/pull/"), let value = Int(url.split(separator: "/").last ?? ""), value > 0 else {
                throw ShipError.message("PR creation didn't finish cleanly. Rerun ship --pr to check for an existing PR before trying again.")
            }
            number = value
        }
        let pr = try view(gh, number: number, repository: repository)
        guard !pr.isCrossRepository, pr.headRefName == state.branch, pr.baseRefName == target, pr.headRefOid == state.head else {
            throw ShipError.message("The PR's branch or commits differ from your review. Stopped before merging; inspect the PR on GitHub.")
        }
        return pr
    }

    private func verify(_ state: RepositoryState, identity: Data, repository: GitHubRepository, targetRef: String, targetHead: String) throws {
        try git.verify(state)
        guard try !git.dirty(), try git.remoteIdentity() == identity, try selectedRepository() == repository, try git.resolve(targetRef) == targetHead else {
            throw ShipError.message("Your changes, destination, or target branch changed during review. Stopped; run ship again.")
        }
    }

    private func mergePR(_ gh: String, pr: GitHubPR, repository: GitHubRepository, state: RepositoryState,
                         target: String, targetRef: String, targetHead: String, identity: Data) throws {
        try verify(state, identity: identity, repository: repository, targetRef: targetRef, targetHead: targetHead)
        guard pr.baseRefOid == targetHead, pr.state == "OPEN", !pr.isDraft else {
            throw ShipError.message("The target changed, or this PR is draft/closed. Review \(display(pr.url)) before merging.")
        }
        let result = try invoke(gh, ["pr", "merge", String(pr.number), "--squash", "--match-head-commit", state.head!], repository: repository)
        guard result.status == 0 else {
            throw ShipError.message("GitHub didn't complete the merge. Check required checks/reviews or conflicts at \(display(pr.url)). Your work branch has been kept.")
        }
        let merged = try view(gh, number: pr.number, repository: repository)
        guard merged.state == "MERGED", let commit = merged.mergeCommit?.oid else {
            console.write("The PR is waiting on GitHub; it isn't confirmed merged yet. Your branch has been kept. Check \(display(pr.url)).")
            return
        }
        console.write("Merged into \(display(target)): \(display(pr.url))")
        do {
            try verify(state, identity: identity, repository: repository, targetRef: targetRef, targetHead: targetHead)
            try git.fetchBranches()
            guard try git.state() == state, try !git.dirty(), try git.remoteIdentity() == identity else {
                throw ShipError.message("Local work changed after the merge; cleanup was stopped.")
            }
            guard let updatedTarget = try git.resolve(targetRef),
                  try git.run(["merge-base", "--is-ancestor", commit, updatedTarget], accepted: [0, 1]).status == 0 else {
                throw ShipError.message("Couldn't confirm the merged commit on the target branch.")
            }
            if let localTarget = try git.resolve("refs/heads/" + target) {
                guard try git.run(["merge-base", "--is-ancestor", localTarget, updatedTarget], accepted: [0, 1]).status == 0 else {
                    throw ShipError.message("Your local target branch has extra commits; it needs manual reconciliation.")
                }
                _ = try git.run(["switch", target])
                _ = try git.run(["merge", "--ff-only", updatedTarget])
            } else { _ = try git.run(["switch", "--track", "-c", target, targetRef]) }
            guard try !git.dirty(), try git.branch() == target, try git.resolve("refs/heads/" + state.branch) == state.head,
                  try git.remoteIdentity() == identity, try selectedRepository() == repository else {
                throw ShipError.message("Local work changed; branch cleanup was stopped.")
            }
            if let remoteSource = try git.resolve("refs/remotes/\(git.remote)/\(state.branch)") {
                guard remoteSource == state.head else { throw ShipError.message("The remote work branch has new commits; it has been kept.") }
                // A lease makes deletion conditional on the exact reviewed branch tip.
                _ = try git.run(["-c", "push.followTags=false", "-c", "remote.\(git.remote).mirror=false", "push", "--no-follow-tags", "--recurse-submodules=no",
                                 "--force-with-lease=refs/heads/\(state.branch):\(state.head!)", "--delete", "--", git.remote, state.branch])
            }
            // Squash merges do not retain ancestry; compare-and-delete the reviewed ref.
            _ = try git.run(["update-ref", "-d", "refs/heads/" + state.branch, state.head!])
            _ = try? git.run(["config", "--remove-section", "branch." + state.branch])
            console.write("Back on \(display(target)). Removed the merged work branch locally and on \(display(git.remote)).")
        } catch {
            console.write("The PR is merged, but local sync/cleanup didn't finish. " + ((error as? ShipError)?.description ?? "Check git status before continuing."))
        }
    }

    private func edit(_ current: PullRequestProposal?) throws -> PullRequestProposal {
        while true {
            let title = try console.read("PR title\(current.map { " [\(display($0.title))]" } ?? ""):")
            console.write("Description: enter Markdown lines, then a single . to finish.\(current == nil ? "" : " A single . keeps the current description.")")
            var lines: [String] = []
            while true {
                let line = try console.read(">")
                if line == "." { break }
                lines.append(line)
                if lines.joined(separator: "\n").utf8.count > 16000 { throw ShipError.message("PR description exceeds 16 KB.") }
            }
            let proposal = PullRequestProposal(title: title.isEmpty ? (current?.title ?? "") : title,
                                               body: lines.isEmpty ? (current?.body ?? "") : lines.joined(separator: "\n"))
            do { try proposal.validate(); return proposal }
            catch { console.write((error as? ShipError)?.description ?? "Invalid PR text.") }
        }
    }

    private func showFindings(_ scan: ScanResult) {
        if let unavailable = scan.unavailable { console.write(unavailable) }
        for finding in scan.findings { console.write("\(display(finding.path ?? "PR payload")): \(display(finding.reason))") }
        console.write("Unresolved findings or an incomplete scan remain. Manual PR text does not audit the commits being published.")
    }
}
