# ship

Run `ship` in a project folder to get a commit message, review your changes, and upload them to GitHub. It asks before committing or pushing.

New project? `ship` offers to set up Git, then asks whether to create a **private** or **public** GitHub repository and what to name it. Press Enter to use the folder name, or type your own name (optionally `owner/name`). It connects the new repository and continues in the same run. You can also connect an existing repository or cancel. Creating the repository uploads no code; that happens only after the final review.

For normal use:

```sh
cd /path/to/your/project
ship
```

Plain `ship` includes all your changes, except ignored files. If you want to select only certain changes, use `git add` first, then `ship --staged`.

```sh
git add login.swift
ship --staged
```

That includes the selected changes to `login.swift` and leaves your other edits out.

Generation uses your existing Command Code login and selected model, including its normal allowance. A temporary adapter calls Command Code's documented `model.complete` API with no tools or transcript. Only the locally scanned payload is passed to that call; the normal coding-agent request never runs. No direct API key is required.

## Prerequisites and build

- macOS 13 or newer, Swift 5.9 or newer (Xcode or Command Line Tools).
- `git` on PATH. Git identity, signing, hooks, and remote authentication work as usual. You can start in a folder without a Git repository or remote.
- `gh` (GitHub CLI) if you want `ship` to create a GitHub repository. Install with `brew install gh`. If you are not signed in, `ship` offers to run `gh auth login`. You can also connect an existing repository without `gh`.
- `gitleaks` on PATH for local content scanning. Verified against **8.30.1**. Missing, incompatible, or failing scanners offer manual entry; they never mean “no findings.”
- Your existing `cmd` executable, logged in with `cmd login` and a working model selected in Command Code. The bridge was checked with **1.88.2**. No direct model SDK or API-key management is included. Shell aliases/functions are not executables; tools must be on an absolute PATH component.

```sh
swift build -c release
.build/release/ship --help
```

To install after building, copy the executable to a directory already on your PATH:

```sh
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/ship "$HOME/.local/bin/ship"
```

Nothing installs itself or edits shell configuration. Workflow tests use temporary repositories and local bare remotes. The bridge check uses fabricated text; development never sends repository content to a live model or pushes a real remote.

For restricted build environments that cannot write user caches:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build -c release --build-system native --cache-path .build/cache --disable-sandbox
```

## Usage

| Command | What it does |
| --- | --- |
| `ship` | Includes all changed, new, and deleted files in the project, except ignored files. Suggests a message and asks before committing and pushing. |
| `ship --staged` | Includes only changes you already selected with `git add`. Other edits stay out. |
| `ship --remote upstream` | Uses the Git connection named `upstream` instead of the usual `origin`. Most people do not need this. |
| `ship --help` | Shows usage instructions. |

Options can be combined, for example `ship --staged --remote upstream`.

When setup is needed, you will see prompts like:

```text
This folder isn't using Git yet: /path/to/my-project
[y] Set up Git here and continue  [N] Cancel

Create a GitHub repository?
  [1] Private — only people you grant access
  [2] Public — anyone can see it
  [e] Connect an existing repository instead
  [N] Cancel

Repository name [my-project] (Enter keeps it; /cancel cancels):
```

Enter cancels the setup menus; at the name prompt it accepts the suggested name. Type `/cancel` there to stop. Git initialization and a newly created empty GitHub repository remain if you cancel later. If the repository name is already taken, you can choose another name or connect an existing repository. Existing Git connections can also be selected instead of creating a repository. Setup never pushes code.

Stdin and stdout must both be interactive terminals. There is no `--yes` option.

**Default staging includes the whole repository, even from a subfolder.** “Staged” means selected for the next commit. `--staged` preserves that selection, including partially selected files. After initial staging, remediation never runs `git add -A` again.

The tool offers setup for missing repositories or connections. It stops before staging if HEAD is detached, conflicts are unresolved, or a merge, rebase, cherry-pick, revert, sequencer operation, or bisect is unfinished. Git operations run at the repository root. Redirecting `GIT_DIR`, `GIT_WORK_TREE`, `GIT_INDEX_FILE`, or `GIT_COMMON_DIR` is rejected to avoid acting on an ambiguous index.

`main`, `master`, and the selected remote's default branch from locally available `refs/remotes/REMOTE/HEAD` are protected. On those branches, enter a new branch name. On a work branch, keep that branch. Existing local or locally known remote branch names cannot be reused. No fetch happens automatically, so a remote name collision not known locally can still cause a push rejection. No history is rewritten or moved off the original branch.

Example final review:

```text
Current branch: main
Create branch:  fix/login-validation
Commit:         fix: reject empty login credentials
Push to:        origin/fix/login-validation

[y] proceed  [e] edit  [d] review complete staged diff locally  [N] cancel
```

Enter cancels at approval. EOF and Ctrl-C cancel. In the edit form, Enter retains a suggestion. Existing work branches cannot be renamed through the form. Messages must be single-line conventional commits, at most 500 UTF-8 bytes, with no terminal controls. Local diff review displays the complete staged diff, including remediation edits; terminal control characters are escaped. It can display sensitive content, only locally.

Cancellation before approval creates no branch or commit. Staged changes remain staged. Explicitly approved ignore/index edits and editor changes also remain; ship reports this instead of attempting rollback.

## Sensitive-data checks and remediation

Before any eligible generation request, ship builds one immutable in-memory payload, checks filenames, and feeds the exact bytes to `gitleaks stdin`. Any changed payload is rebuilt and scanned again. Flagged or unsuccessfully scanned payloads cannot reach the generation boundary.

Filename rules are case-insensitive and inspect both old and new paths of renames:

| Paths | Reason |
| --- | --- |
| `.env`, `.env.*` at any depth | Environment files |
| `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`, `identity` | Common private-key names |
| `*.key`, `*.pem`, `*.p12`, `*.pfx` | Potential private keys or bundles; public certificates may be false positives |
| `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.git-credentials` | Credential stores |
| `.aws/credentials`, `.docker/config.json`, `gcloud/application_default_credentials.json`, at any depth | Known credential-store paths |

Only `.env.example`, `.env.sample`, `.env.template`, and `.env.dist` are exempt from the environment filename rule. Their content is still scanned. Ordinary JSON/config/source filenames are not broadly flagged.

Gitleaks uses built-in rules via an isolated config containing `[extend] useDefault = true`, a fresh private temporary working directory, an empty ignore file, `--ignore-gitleaks-allow`, `--redact=100`, and no file-size skipping. `GITLEAKS_*` environment overrides are removed. Repository configs, baselines, ignore files, and inline `gitleaks:allow` comments cannot silently exempt the outbound payload. Installed help is checked and fabricated positive/negative probes verify stdin behavior: status 0 means no findings, explicitly configured status 23 means findings, and other statuses/report inconsistencies mean scanning failure.

The report template emits only rule IDs and line locations to stdout. Raw diagnostics are neither printed nor written to log files. Reports show repository-relative paths, locations when available, and reasons, never matched secrets or source excerpts. The only temporary files used by the scanner are non-secret rules, report template, and empty ignore file. Payload bytes stay in memory and travel through pipes.

Available actions depend on the finding:

- **New `.env.local`: “Ignore this file and keep it locally.”** Append an exact, root-anchored, escaped entry to root `.gitignore`, remove only that file from the index, and recheck. Local file bytes remain untouched. Already-staged and unstaged `.gitignore` contents are handled independently: only the intended extra rule is added to each version. Exact duplicate entries are avoided. This also works before the first commit.
- **Tracked credential file: “Stop tracking this file and keep it locally.”** First confirm that the next commit removes the file from version control, keeps the local copy, and leaves history unchanged. The resulting deletion diff may contain secrets. ship uses an explicitly local, editable suggestion, `chore: stop tracking local environment file`, and asks for a branch locally when necessary. No model invocation occurs.
- **Secret in source:** Open `VISUAL`, falling back to `EDITOR`, using parsed argument words with no shell execution or expansion. Configure GUI editors with a wait option, such as `code --wait`. For a fully staged file, review the local edit diff and approve before replacing its staged version. If it was partially staged or the index changed, ship leaves the selection alone and asks you to stage the intended fix in another terminal, then recheck.
- **False positive, missing scanner, or manual handling:** Enter details without the model or cancel. Unresolved findings and unsuccessful scanning remain visible at final approval. Manual mode does **not** mean the commit is secret-free.

Automated ignore actions refuse ambiguous cases such as a staged/unstaged `.gitignore` deletion, symlinks, newline-containing paths, or a nested ignore rule that overrides the root rule. They explain the issue and offer manual handling. Application source is never automatically rewritten or offered as an ignore target merely because its content matched a rule.

## Model generation through cmd

`ship` starts `cmd` in a fresh private temporary directory with a static bootstrap query:

```text
cmd -p "ship generation bridge; do not perform any task" \
  --max-turns 1 --no-session --no-skills --skip-onboarding \
  --no-auto-update --permission-mode dont-ask --mod /temporary/ship-generation.mjs
```

The adapter uses the documented [Command Code Mod API](https://commandcode.ai/docs/mods): `cmd.model.complete({prompt, maxOutputTokens: 1024})` makes one completion on the session's selected model, with no transcript and no tools. The installed 1.88.2 implementation was inspected to confirm that it sends only the supplied prompt and an empty tool array. This uses your existing Command Code authentication and model access. `ship` does not choose a different model or force `--effort low`, which some models reject.

The adapter runs before the normal agent request, reads the exact scanned bytes from stdin, calls this completion API, writes a small result envelope, and exits the subprocess. The payload never enters the coding agent's messages, automatic repository context, or session transcript. Only static adapter code is written to the temporary directory; it is removed afterward. Tool filtering and a blocking tool hook provide additional guards. `--max-turns` and `--no-session` alone are not treated as tool restrictions. No user authentication or settings files are changed or copied.

The model receives static instructions, old/new relative paths, change metadata, and complete staged text patches (added, deleted, and context lines). No repository root, remote URLs, Git history, unstaged files, or binary bodies are included. Binary changes are metadata-only, even if `.gitattributes` forces a textual diff. The instructions treat all diff/metadata content as untrusted and request one JSON object with `branch` and `message`; existing work branches require `branch: null`. Output is validated as data, never commands.

If `cmd` is missing, its bridge controls or completion API are unavailable, authentication/network/model access fails, or output is invalid, `ship` offers manual entry or cancellation. There are no automatic generation retries. Raw model output and diagnostics are withheld. The subprocess has a 90-second timeout. The bootstrap query is static, so a bridge that fails to load does not expose the payload to the normal agent.

A fabricated prompt was used for the live integration check. No repository content was sent to a live model during development, and no real remote was pushed.

Scanning is **best-effort protection of the model request**, not a complete confidentiality audit, secret-free-commit guarantee, or audit of outgoing Git history. Binary content and secrets outside the patch are not audited. Built-in rules can miss confidential material and can produce false positives. Deleted secrets still occur in deletion diffs and earlier history. Git hooks, clean filters, editors, and the selected remote remain normal locally configured external programs.

## Push preview and failure recovery

Before approval, ship lists existing outgoing commits with abbreviated hashes and subjects. It compares to the same-named remote-tracking branch, or the selected remote's known default for a new branch. All comparisons are explicitly local and potentially stale. If no reliable comparison exists, the outgoing commit count is **unknown**; publishing may include older history.

Push uses an explicit `refs/heads/BRANCH:refs/heads/BRANCH` refspec, sets upstream, disables follow-tags, remote mirror behavior, and recursive submodule pushing. Ambient push refspecs cannot add other branches. There is no force push, merge, rebase, stash, reset, branch deletion, or PR creation.

With no staged changes, an ahead work branch offers push-only confirmation; a work branch without a known destination offers publication with the same caveats. No model or scanner is invoked for push-only operation. Protected branches are never offered for push. Otherwise the tool prints `Nothing to ship.`

Before actions, ship rechecks the reviewed branch, HEAD, staged tree, remote identity, and local comparison. Changes stop the operation for fresh review. Normal hooks run. After commit, the committed tree, index, parent, message, and branch must still match approval before push.

- **Commit succeeds, push fails:** The commit remains local. ship prints the exact shell-quoted retry command. Rerun `ship` (or `ship --staged` to exclude other work) for push-only recovery. A transport failure can happen after a remote accepts a push, so check the reported state; ship does not claim the remote stayed unchanged.
- **Branch creation succeeds, commit fails:** The new branch remains; ship reports the currently checked-out branch. No silent rollback.
- **Hook changes the commit:** Stop before push and inspect the local result. ship does not undo hook changes.

## Tests

`swift test` uses XCTest, temporary worktrees, local bare remotes, executable scanner/model doubles, and fabricated tokens. It exercises protected/work branches, partial staging, subdirectory staging, editor/diff/edit/cancel paths, scanner/model failures, redacted findings, additions/deletions/context/metadata, binary omission, exact ignore rules, independent `.gitignore` versions, unborn repositories, local secret-removal messages, hook changes, race checks, narrow push behavior, large subprocess pipes, and push-only recovery. An optional test runs installed Gitleaks against fabricated data to verify built-ins and ignore isolation; it skips when Gitleaks is unavailable.
