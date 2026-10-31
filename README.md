# ship

**Review, commit, and push your changes with one command.**

`ship` suggests a commit message and, when needed, a branch name. You review the proposal and approve it before anything is committed or pushed. It uses your existing [Command Code](https://commandcode.ai/docs/quickstart) (`cmd`) login and selected model.

## Install

You need **macOS 13+**, **Swift 5.9+**, **Git**, **Command Code**, and **Gitleaks**. Install Apple's command-line tools with `xcode-select --install` if Swift or Git is missing.

Install [Command Code](https://commandcode.ai/docs/quickstart) first. Then, with [Homebrew](https://brew.sh), install Gitleaks for local secret checks and GitHub CLI for creating repositories:

```sh
brew install gitleaks gh
cmd login
gh auth login
```

Already signed in? Skip the login commands. `gh` is optional if your project already has a Git remote or you connect an existing repository URL.

Build and install `ship`:

```sh
git clone https://github.com/vim-diesel/ship-my-code.git
cd ship-my-code
swift build -c release
mkdir -p "$HOME/.local/bin"
install -m 755 .build/release/ship "$HOME/.local/bin/ship"
```

If your terminal can't find `ship`, add this line to `~/.zshrc`, then open a new terminal:

```sh
export PATH="$HOME/.local/bin:$PATH"
```

## Use it

Go to your project and run:

```sh
cd /path/to/your/project
ship
```

`ship` gathers your changes, checks for possible secrets locally, and suggests what to commit:

```text
Current branch: main
Create branch:  fix/login-validation
Commit:         fix: reject empty login credentials
Push to:        origin/fix/login-validation

[y] proceed  [e] edit  [d] review complete staged diff locally  [N] cancel
```

- **`y`** — commit and push.
- **`e`** — edit the message or proposed branch name. Enter keeps a suggestion.
- **`d`** — inspect the full staged diff, then return to the proposal.
- **Enter or `n`** — cancel. Your changes remain selected for the next commit.

**Plain `ship` includes all changes across the whole repository**, even when run from a subfolder. New files covered by `.gitignore` stay out; files Git already tracks can still be included.

To include only specific changes, select them with `git add` first. Git calls these changes **staged**:

```sh
git add login.swift
ship --staged
```

Other edited or untracked files stay out of that commit.

| Command | What it does |
| --- | --- |
| `ship` | Include all changes, review, commit, and push. |
| `ship --staged` | Include only changes already selected with `git add`. |
| `ship --remote upstream` | Use the Git connection named `upstream` instead of `origin`. |
| `ship --help` | Show help. |

Options can be combined: `ship --staged --remote upstream`.

## New project?

Run `ship` in the project folder. It offers to initialize Git and create a GitHub repository. Choose **private or public**, then enter a **repository name**. Press Enter to use the folder name, or enter `owner/name` to choose an owner. You can also connect an existing repository instead.

Setup creates an empty GitHub repository. Uploading code still requires approval at the commit review. If you cancel later, Git setup and the empty repository remain.

## How branches work

| Where you are | What `ship` does |
| --- | --- |
| A new project on `main`, with no commits yet | Make the first commit on `main`. |
| `main` after the first commit | Suggest a new branch for your changes. |
| An existing work branch | Keep that branch and suggest a commit message. |

`master` and the selected remote's known default branch are also protected after setup.

Keep using one work branch for a related change. When finished, open a pull request on GitHub, merge it into `main`, and delete the work branch. Then start your next change from the updated `main`:

```sh
git switch main
git pull --ff-only
```

`ship` handles committing and pushing. Pull requests, merging, and branch cleanup are separate steps.

## Secrets and failures

Before asking `cmd` for a suggestion, `ship` checks sensitive filenames and scans the exact outgoing text with Gitleaks. Possible secrets block generation. It offers appropriate actions: keep a local file out of Git, open your editor to fix source, enter a message manually, or cancel.

The model receives staged text changes and file metadata, including deleted lines. Binary contents, unstaged changes, Git history, and remote URLs are excluded. Checks are best effort; manual entry does not make a commit secret-free.

If `cmd` or Gitleaks is unavailable or fails, you can enter commit details manually or cancel. If a commit succeeds but its push fails, the commit stays local: run `ship --staged` again to review a push-only retry, or use the retry command it prints.

## Updating and development

After pulling source updates, repeat the build and `install` commands. Run `swift test` for the test suite. See [implementation notes](docs/implementation.md) for the model adapter, scanning rules, Git safeguards, and development setup.
