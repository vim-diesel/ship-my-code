import Foundation

enum Remediation {
    static func ignoreRule(_ path: String) throws -> String {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              !path.contains("\n"), !path.contains("\r"), !path.contains("\0") else {
            throw ShipError.message("This path cannot be represented by one exact .gitignore rule. Handle it manually.")
        }
        return "/" + path.map { "\\*?[]!# ".contains($0) ? "\\" + String($0) : String($0) }.joined()
    }

    private static func adding(_ rule: String, to bytes: Data) throws -> Data {
        let original = try utf8(bytes)
        if original.split(separator: "\n", omittingEmptySubsequences: false).contains(Substring(rule)) { return bytes }
        return Data((original + (original.isEmpty || original.hasSuffix("\n") ? "" : "\n") + rule + "\n").utf8)
    }

    static func regularLocalFile(_ path: String, git: Git) -> Bool {
        let url = git.root.appendingPathComponent(path)
        // Reject symlink ancestors too: an editor/ignore action must not wander outside the tree.
        guard url.resolvingSymlinksInPath().path == url.standardizedFileURL.path else { return false }
        return (try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) == .typeRegular
    }

    static func ignoreAndUntrack(_ path: String, git: Git, state: RepositoryState) throws {
        guard path != ".gitignore", regularLocalFile(path, git: git), try git.entry(path) != nil else {
            throw ShipError.message("The selected path is not a regular staged local file. Use manual handling; its local copy was not changed.")
        }
        let rule = try ignoreRule(path)
        let file = git.root.appendingPathComponent(".gitignore")
        let manager = FileManager.default
        let workExists = manager.fileExists(atPath: file.path)
        if workExists && !regularLocalFile(".gitignore", git: git) {
            throw ShipError.message("Root .gitignore is not a regular file. Automatic remediation cannot safely preserve it.")
        }
        // fileExists follows dangling symlinks; check the directory entry itself as well.
        if (try? manager.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw ShipError.message("Root .gitignore is a symlink; use manual handling.")
        }
        let indexEntry = try git.entry(".gitignore")
        let headEntry = try git.entry(".gitignore", head: true)
        if (headEntry != nil && indexEntry == nil) || (indexEntry != nil && !workExists) {
            throw ShipError.message("Root .gitignore has a staged or unstaged deletion. Appending would undo that selection; handle the ignore rule manually.")
        }
        if let indexEntry, !["100644", "100755"].contains(indexEntry.mode) {
            throw ShipError.message("The staged .gitignore is not a regular file; use manual handling.")
        }
        let previousWork = workExists ? try Data(contentsOf: file) : Data()
        let previousIndex = try indexEntry.map { try git.blob($0) } ?? Data()
        let newWork = try adding(rule, to: previousWork)
        let newIndex = try adding(rule, to: previousIndex)
        let permissions = workExists ? try manager.attributesOfItem(atPath: file.path)[.posixPermissions] : nil
        let hash = try git.textHash(newIndex)
        try git.verify(state)
        guard (workExists == manager.fileExists(atPath: file.path)),
              try !workExists || Data(contentsOf: file) == previousWork else {
            throw ShipError.message(".gitignore changed while preparing remediation. Nothing was applied; review again.")
        }
        try newWork.write(to: file, options: .atomic)
        if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
        do {
            // A deeper .gitignore can override a root rule. Verify before touching the index.
            let ignored = try git.run(["check-ignore", "--no-index", "--quiet", "--", "./" + path], accepted: [0, 1])
            guard ignored.status == 0 else {
                throw ShipError.message("A nested ignore rule overrides the root entry. Handle that rule manually; the index was not changed.")
            }
            try git.verify(state)
            // One Git index transaction: add ONLY our .gitignore delta to its staged version,
            // then remove exactly the chosen path. Local sensitive-file contents are never written.
            let mode = indexEntry?.mode ?? "100644"
            let zeros = String(repeating: "0", count: state.tree.count)
            let records = "\(mode) \(hash)\t.gitignore\0" + "0 \(zeros)\t\(path)\0"
            _ = try git.run(["update-index", "-z", "--index-info"], input: Data(records.utf8))
        } catch {
            // Only undo our own worktree delta if nobody edited it in the meantime.
            if (try? Data(contentsOf: file)) == newWork {
                if workExists {
                    try previousWork.write(to: file, options: .atomic)
                    if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: file.path) }
                }
                else { try manager.removeItem(at: file) }
            }
            throw error
        }
    }

    /// Shell-style words only. No shell expansion, substitutions, pipelines, or evaluation.
    static func editorWords(_ value: String) throws -> [String] {
        var words: [String] = [], word = ""
        var quote: Character?, escaped = false, started = false
        for c in value {
            if escaped { word.append(c); escaped = false; started = true; continue }
            if c == "\\" && quote != "'" { escaped = true; started = true; continue }
            if let current = quote {
                if c == current { quote = nil } else { word.append(c) }
                started = true
            } else if c == "'" || c == "\"" { quote = c; started = true }
            else if c == " " || c == "\t" {
                if started { words.append(word); word = ""; started = false }
            } else {
                guard !";|&<>`$\r\n\0".contains(c) else {
                    throw ShipError.message("VISUAL/EDITOR must be an executable and quoted arguments, without shell syntax or expansion.")
                }
                word.append(c); started = true
            }
        }
        guard quote == nil, !escaped else { throw ShipError.message("VISUAL/EDITOR has an unfinished quote or escape.") }
        if started { words.append(word) }
        guard !words.isEmpty, !words[0].isEmpty else { throw ShipError.message("Set VISUAL or EDITOR to an editor executable (with a wait option for GUI editors).") }
        if words[0].hasPrefix("~/") { words[0] = FileManager.default.homeDirectoryForCurrentUser.path + String(words[0].dropFirst()) }
        return words
    }

    static func editSource(_ path: String, git: Git, console: Console, state: RepositoryState) throws {
        guard regularLocalFile(path, git: git), try git.entry(path) != nil else {
            throw ShipError.message("This finding has no regular staged local file to edit. Stage a fix manually in another terminal.")
        }
        let config = git.runner.environment["VISUAL"] ?? git.runner.environment["EDITOR"] ?? ""
        let words = try editorWords(config)
        guard let editor = git.runner.executable(words[0]) else { throw ShipError.message("Configured editor executable was not found.") }
        let partial = try git.run(["diff", "--quiet", "--no-ext-diff", "--", path], accepted: [0, 1]).status == 1
        try git.verify(state)
        let result = try git.runner.run(editor, Array(words.dropFirst()) + [git.root.appendingPathComponent(path).path],
                                        cwd: git.root, timeout: 0, interactive: true)
        guard result.status == 0 else { throw ShipError.message("Editor exited unsuccessfully. Local edits remain; stage them manually.") }
        guard try git.branch() == state.branch, try git.resolve("HEAD") == state.head else {
            throw ShipError.message("Branch or HEAD changed while editing. Run ship again for a fresh review.")
        }
        if try partial || git.state() != state {
            console.write("This file was partially staged, or the index changed. ship will not replace your selection.")
            console.write("Stage only the intended edits in another terminal, for example: git add -p -- \(shellQuote(path))")
            guard try console.read("[r] recheck after manual staging  [N] cancel").lowercased() == "r" else { throw ShipError.cancelled }
            return
        }
        guard regularLocalFile(path, git: git) else { throw ShipError.message("Editor changed the file type or removed it; stage this manually.") }
        let file = git.root.appendingPathComponent(path)
        let edited = try Data(contentsOf: file)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        console.write("Local diff to replace the staged version (may contain sensitive data):")
        console.write(display(try git.text(["diff"] + git.diffOptions + ["--", path]), multiline: true))
        guard try console.read("[y] stage these edits  [N] cancel").lowercased() == "y" else { throw ShipError.cancelled }
        try git.verify(state)
        guard try Data(contentsOf: file) == edited,
              try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber == permissions else {
            throw ShipError.message("The edited file changed after review. Stage it manually and review again.")
        }
        _ = try git.run(["add", "--", path])
    }
}

extension Git {
    func textHash(_ data: Data) throws -> String { try utf8(run(["hash-object", "-w", "--stdin"], input: data).stdout).removingFinalNewline }
}
