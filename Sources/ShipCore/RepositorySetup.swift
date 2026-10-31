import Foundation

/// First-run setup stays in the same invocation. Creating a GitHub repository
/// creates an empty destination; uploading code still requires the final review.
struct RepositorySetup {
    let runner: ProcessRunner
    let console: Console

    func prepare(directory: URL, remote: String) throws -> Git {
        guard console.interactive else { throw ShipError.message("Run ship in an interactive terminal to set up this project.") }
        let git: Git
        do {
            git = try Git(runner: runner, directory: directory, remote: remote)
        } catch ShipError.notRepository {
            console.write("This folder isn't using Git yet: \(display(directory.path))")
            guard try console.read("[y] Set up Git here and continue  [N] Cancel").lowercased() == "y" else { throw ShipError.cancelled }
            guard let executable = runner.executable("git") else { throw ShipError.message("Install Git first (xcode-select --install), then run ship again.") }
            let result = try runner.run(executable, ["init", "--initial-branch=main"], cwd: directory)
            guard result.status == 0 else { throw ShipError.message("Couldn't initialize Git here. Check that you can write to this folder, then run ship again.") }
            console.write("Git is set up. Your files haven't been committed yet.")
            git = try Git(runner: runner, directory: directory, remote: remote)
        }
        try git.preflight(requireRemote: false)
        guard try !git.remotes().contains(remote) else { return git }
        return try connect(git)
    }

    private func connect(_ git: Git) throws -> Git {
        let others = try git.remotes()
        var name = suggestedName(git.root.lastPathComponent)
        while true {
            console.write("\nThere's no '\(display(git.remote))' connection for uploading this project.")
            for (index, remote) in others.enumerated() {
                console.write("  [r\(index + 1)] Use the existing '\(display(remote))' connection")
            }
            console.write("Create a GitHub repository?\n  [1] Private — only people you grant access\n  [2] Public — anyone can see it\n  [e] Connect an existing repository instead\n  [N] Cancel")
            let choice = try console.read("Choose:").lowercased()
            if choice.hasPrefix("r"), let index = Int(choice.dropFirst()), others.indices.contains(index - 1) {
                return try Git(runner: runner, directory: git.root, remote: others[index - 1])
            }
            if choice == "e" { try connectExisting(git); return git }
            let visibility: String
            switch choice {
            case "1", "private": visibility = "--private"
            case "2", "public": visibility = "--public"
            default: throw ShipError.cancelled
            }
            name = try readName(defaultName: name)
            guard let gh = runner.executable("gh") else {
                console.write("GitHub CLI isn't installed. Install it with brew install gh, then run gh auth login.")
                if try console.read("[e] Connect an existing repository URL now  [N] Cancel").lowercased() == "e" {
                    try connectExisting(git); return git
                }
                throw ShipError.cancelled
            }
            var environment = runner.environment
            environment["GH_PROMPT_DISABLED"] = "1"
            let host = environment["GH_HOST"] ?? "github.com"
            let auth = try runner.run(gh, ["auth", "status", "--active", "--hostname", host], cwd: git.root, environment: environment, timeout: 20)
            if auth.status != 0 {
                console.write("GitHub CLI couldn't verify your login to \(display(host)).")
                guard try console.read("[l] Sign in with gh now  [N] Cancel").lowercased() == "l" else { throw ShipError.cancelled }
                let login = try runner.run(gh, ["auth", "login", "--hostname", host], cwd: git.root, timeout: 0, interactive: true)
                guard login.status == 0 else { throw ShipError.message("GitHub sign-in didn't finish. Run gh auth login, then run ship again.") }
            }
            // --source/--remote connect the new repository. Deliberately no --push:
            // creation must not upload any code or bypass the later commit review.
            let result: CommandResult
            do {
                result = try runner.run(gh, ["repo", "create", name, visibility, "--source", git.root.path, "--remote", git.remote],
                                        cwd: git.root, environment: environment, timeout: 60)
            } catch ShipError.cancelled { throw ShipError.cancelled }
            catch {
                throw ShipError.message("GitHub setup didn't finish. Check gh repo list before trying again; the empty repository may have been created. Your code hasn't been uploaded by ship.")
            }
            if result.status == 0, try git.remotes().contains(git.remote) {
                console.write("Created a \(visibility == "--private" ? "private" : "public") GitHub repository and connected it. No code has been uploaded yet.")
                return git
            }
            // A timeout/failure can follow remote creation. Never silently create
            // another repository or change visibility when the outcome is unclear.
            if try git.remotes().contains(git.remote) {
                throw ShipError.message("GitHub setup reported a problem after adding the connection. No code was uploaded by ship. Check gh repo view, then run ship again.")
            }
            let diagnostic = String(decoding: result.stderr, as: UTF8.self).lowercased()
            if diagnostic.contains("already exists") || diagnostic.contains("name already") {
                console.write("A GitHub repository named '\(display(name))' already exists.")
            } else {
                console.write("GitHub couldn't finish creating or connecting the repository. Check gh repo list before trying again; an empty repository may already exist.")
            }
            let next = try console.read("[r] Try a different repository name  [e] Connect an existing repository  [N] Cancel").lowercased()
            if next == "e" { try connectExisting(git); return git }
            guard next == "r" else { throw ShipError.cancelled }
        }
    }

    private func connectExisting(_ git: Git) throws {
        while true {
            let url = try console.read("Paste the repository's HTTPS or SSH URL (Enter cancels):")
            if url.isEmpty { throw ShipError.cancelled }
            guard isSingleLine(url), !url.hasPrefix("-") else { console.write("Enter a repository URL, such as https://github.com/you/project.git."); continue }
            _ = try git.run(["remote", "add", "--", git.remote, url])
            console.write("Repository connected. Continuing to review your changes.")
            return
        }
    }

    private func suggestedName(_ folder: String) -> String {
        let name = folder.replacingOccurrences(of: "[^A-Za-z0-9_.-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return name.isEmpty ? "my-project" : name
    }

    private func readName(defaultName: String) throws -> String {
        while true {
            let input = try console.read("Repository name [\(display(defaultName))] (Enter keeps it; /cancel cancels):")
            if input == "/cancel" { throw ShipError.cancelled }
            let name = input.isEmpty ? defaultName : input
            if name.range(of: "^[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)?$", options: .regularExpression) != nil { return name }
            console.write("Use letters, numbers, dots, hyphens or underscores, for example my-project.")
        }
    }
}
