import Foundation

struct RepositoryState: Equatable {
    let branch: String
    let head: String?
    let tree: String
}

struct Change {
    let status: String
    let oldPath: String?
    let newPath: String?
    var paths: [String] { Array(Set([oldPath, newPath].compactMap { $0 })).sorted() }
    var path: String { newPath ?? oldPath! }
}

struct GitEntry {
    let mode: String
    let hash: String
}

struct PushComparison: Equatable {
    let reference: String?
    let hash: String?
    let commits: [String]
    let destinationExists: Bool
}

final class Git {
    let runner: ProcessRunner
    let executable: String
    let root: URL
    let remote: String
    private let base = ["--no-pager", "--literal-pathspecs", "-c", "color.ui=false", "-c", "core.quotePath=true"]
    let diffOptions = ["--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "--submodule=short"]

    init(runner: ProcessRunner, directory: URL, remote: String) throws {
        self.runner = runner
        self.remote = remote
        guard let executable = runner.executable("git") else { throw ShipError.message("git is not on PATH.") }
        self.executable = executable
        for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR"] where runner.environment[key] != nil {
            throw ShipError.message("Unset \(key) before running ship; a redirected repository/index is ambiguous.")
        }
        let result = try runner.run(executable, base + ["rev-parse", "--show-toplevel"], cwd: directory)
        guard result.status == 0 else {
            let metadata = try runner.run(executable, base + ["rev-parse", "--git-dir"], cwd: directory)
            guard metadata.status != 0 else {
                throw ShipError.message("You're in Git's storage folder. Run ship from the project folder containing your files.")
            }
            // Do not offer initialization over a broken or inaccessible repository.
            var ancestor = directory.standardizedFileURL
            while true {
                if (try? FileManager.default.attributesOfItem(atPath: ancestor.appendingPathComponent(".git").path)) != nil {
                    throw ShipError.message("Git couldn't open this repository. Run git status here to see what needs fixing.")
                }
                let parent = ancestor.deletingLastPathComponent()
                if parent.path == ancestor.path { break }
                ancestor = parent
            }
            throw ShipError.notRepository
        }
        root = URL(fileURLWithPath: try utf8(result.stdout).removingFinalNewline)
    }

    func run(_ args: [String], input: Data = Data(), accepted: Set<Int32> = [0]) throws -> CommandResult {
        // check-ignore takes literal filenames itself and rejects Git's global literal magic.
        let prefix = args.first == "check-ignore" ? base.filter { $0 != "--literal-pathspecs" } : base
        var environment = runner.environment
        for key in ["GIT_LITERAL_PATHSPECS", "GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS", "GIT_ICASE_PATHSPECS"] {
            environment.removeValue(forKey: key)
        }
        let result = try runner.run(executable, prefix + args, cwd: root, input: input, environment: environment, timeout: 0)
        guard accepted.contains(result.status) else {
            // Git/hook stderr can contain secrets, remote credentials, or source excerpts.
            throw ShipError.message("git \(args.first ?? "command") exited \(result.status). Review Git locally for details; ship did not print its raw diagnostics.")
        }
        return result
    }

    func text(_ args: [String]) throws -> String { try utf8(run(args).stdout).removingFinalNewline }

    func branch() throws -> String {
        let result = try run(["symbolic-ref", "--quiet", "HEAD"], accepted: [0, 1])
        guard result.status == 0 else { throw ShipError.message("Detached HEAD: check out a named branch first.") }
        let full = try utf8(result.stdout).removingFinalNewline
        guard full.hasPrefix("refs/heads/") else { throw ShipError.message("HEAD does not name a local branch.") }
        return String(full.dropFirst("refs/heads/".count))
    }

    func resolve(_ ref: String) throws -> String? {
        let result = try run(["rev-parse", "--verify", "--quiet", ref + "^{commit}"], accepted: [0, 1])
        return result.status == 0 ? try utf8(result.stdout).removingFinalNewline : nil
    }

    func state() throws -> RepositoryState {
        try RepositoryState(branch: branch(), head: resolve("HEAD"), tree: text(["write-tree"]))
    }

    func preflight(requireRemote: Bool = true) throws {
        _ = try branch()
        guard isSingleLine(remote), !remote.hasPrefix("-") else {
            throw ShipError.message("Use a remote name such as origin or upstream.")
        }
        if requireRemote, try !remotes().contains(remote) {
            throw ShipError.message("The Git connection '\(display(remote))' is missing. Run ship again to connect a repository.")
        }
        for operation in ["MERGE_HEAD", "rebase-merge", "rebase-apply", "CHERRY_PICK_HEAD", "REVERT_HEAD", "sequencer", "BISECT_LOG"] {
            let item = try text(["rev-parse", "--git-path", operation])
            let url = item.hasPrefix("/") ? URL(fileURLWithPath: item) : root.appendingPathComponent(item)
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw ShipError.message("Finish or abort the existing Git operation (\(operation)) before running ship. The index was not changed.")
            }
        }
        guard try run(["ls-files", "--unmerged", "-z"]).stdout.isEmpty else {
            throw ShipError.message("Resolve Git conflicts first. The index was not changed.")
        }
    }

    func remotes() throws -> [String] { try text(["remote"]).split(separator: "\n").map(String.init) }

    func verify(_ expected: RepositoryState) throws {
        try preflight()
        guard try state() == expected else {
            throw ShipError.message("Branch, HEAD, or staged tree changed after review. Nothing further was done; run ship again for a fresh review.")
        }
    }

    func defaultRemoteRef() throws -> String? {
        let result = try run(["symbolic-ref", "--quiet", "refs/remotes/\(remote)/HEAD"], accepted: [0, 1])
        guard result.status == 0 else { return nil }
        let ref = try utf8(result.stdout).removingFinalNewline
        return ref.hasPrefix("refs/remotes/\(remote)/") ? ref : nil
    }

    func protectedBranches() throws -> Set<String> {
        var protected: Set<String> = ["main", "master"]
        if let ref = try defaultRemoteRef() { protected.insert(String(ref.dropFirst("refs/remotes/\(remote)/".count))) }
        return protected
    }

    func validateNewBranch(_ name: String) throws {
        guard isSingleLine(name), !name.hasPrefix("-"), name != "HEAD",
              !name.hasPrefix("refs/"), !name.contains("@{"),
              try run(["check-ref-format", "refs/heads/" + name], accepted: [0, 1]).status == 0 else {
            throw ShipError.message("Invalid branch name. Use a name such as fix/login-validation.")
        }
        guard try !protectedBranches().contains(name) else { throw ShipError.message("That branch name is protected.") }
        // show-ref also catches non-commit refs; never silently reuse an existing branch.
        for ref in ["refs/heads/\(name)", "refs/remotes/\(remote)/\(name)"] {
            let result = try run(["show-ref", "--verify", "--quiet", ref], accepted: [0, 1])
            guard result.status == 1 else { throw ShipError.message("That branch already exists locally or on the locally known remote. Choose another name.") }
        }
    }

    func hasChanges() throws -> Bool {
        try run(["diff", "--cached", "--quiet", "--no-ext-diff"], accepted: [0, 1]).status == 1
    }

    func hasExcludedChanges() throws -> Bool {
        if try run(["diff", "--quiet", "--no-ext-diff"], accepted: [0, 1]).status == 1 { return true }
        return try !run(["ls-files", "--others", "--exclude-standard", "-z"]).stdout.isEmpty
    }

    func changes() throws -> [Change] {
        let fields = try utf8(run(["diff", "--cached", "--name-status", "-z", "--find-renames", "--no-ext-diff"]).stdout)
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [Change] = []
        var i = 0
        while i < fields.count {
            let status = fields[i]; i += 1
            guard i < fields.count else { throw ShipError.message("Malformed Git change list.") }
            let first = fields[i]; i += 1
            if status.hasPrefix("R") || status.hasPrefix("C") {
                guard i < fields.count else { throw ShipError.message("Malformed Git rename.") }
                changes.append(Change(status: status, oldPath: first, newPath: fields[i])); i += 1
            } else {
                changes.append(Change(status: status, oldPath: status == "A" ? nil : first, newPath: status == "D" ? nil : first))
            }
        }
        return changes
    }

    func entry(_ path: String, head: Bool = false) throws -> GitEntry? {
        if try head && resolve("HEAD") == nil { return nil }
        let data = try run(head ? ["ls-tree", "-z", "HEAD", "--", path] : ["ls-files", "--stage", "-z", "--", path]).stdout
        let rows = try utf8(data).split(separator: "\0")
        for row in rows {
            guard let tab = row.firstIndex(of: "\t"), String(row[row.index(after: tab)...]) == path else { continue }
            let metadata = row[..<tab].split(separator: " ").map(String.init)
            guard metadata.count == 3 else { throw ShipError.message("Malformed Git entry.") }
            return GitEntry(mode: metadata[0], hash: metadata[head ? 2 : 1])
        }
        return nil
    }

    func blob(_ entry: GitEntry) throws -> Data {
        if entry.mode == "160000" { return Data() }
        return try run(["cat-file", "blob", entry.hash]).stdout
    }

    func stagedDiff(paths: [String] = []) throws -> String {
        try utf8(run(["diff", "--cached"] + diffOptions + ["--"] + paths).stdout)
    }

    func comparison(branch: String) throws -> PushComparison {
        let destination = "refs/remotes/\(remote)/\(branch)"
        let destinationHash = try resolve(destination)
        let reference = try destinationHash != nil ? destination : defaultRemoteRef()
        let hash = try reference.flatMap { try resolve($0) }
        let head = try resolve("HEAD")
        var commits: [String] = []
        if let hash, head != nil {
            commits = try text(["log", "--reverse", "--format=%h %s", hash + "..HEAD", "--"]).split(separator: "\n").map(String.init)
        }
        return PushComparison(reference: reference, hash: hash, commits: commits, destinationExists: destinationHash != nil)
    }

    func pushArguments(branch: String) -> [String] {
        ["-c", "push.followTags=false", "-c", "remote.\(remote).mirror=false", "push", "--no-follow-tags",
         "--recurse-submodules=no", "--set-upstream", "--", remote, "refs/heads/\(branch):refs/heads/\(branch)"]
    }

    func retryCommand(branch: String) -> String {
        (["git", "-C", root.path] + pushArguments(branch: branch)).map(shellQuote).joined(separator: " ")
    }

    func remoteIdentity() throws -> Data { try run(["remote", "get-url", "--push", "--all", remote]).stdout }
}
