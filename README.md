# ship

**Review, commit, and push your changes with one command.**

`ship` suggests a commit message and, when needed, a branch name. You review the proposal and approve it before anything is committed or pushed. It uses your existing [Command Code](https://commandcode.ai/docs/quickstart) (`cmd`) login and selected model.

## Why ship? The workflow it chooses

`ship` is an opinionated, AI-assisted workflow around Git and GitHub CLI. Git handles staging, branches, commits, and pushes. GitHub CLI already supports [creating PRs from commit messages](https://cli.github.com/manual/gh_pr_create) and [squash merging with branch deletion](https://cli.github.com/manual/gh_pr_merge). `ship` combines those operations with generated descriptions, local secret checks, and interactive review so you repeat fewer commands and decisions.

These are the choices it makes:

| Opinion | What it means for your workflow |
| --- | --- |
| **Ship the whole project by default.** | Plain `ship` stages changes across the entire repository, even from a subfolder. Use `--staged` when you want to select the changes yourself. |
| **Use conventional commit messages.** | Commit messages must be a single line in a format such as `fix: reject empty credentials`, including messages you enter manually. |
| **Keep branch decisions simple.** | The first commit on `main` stays there. Later commits on `main` offer a direct commit or a suggested new branch. `master` and other known remote default branches require a work branch. Existing work branches keep their names. |
| **Use your existing model setup.** | Command Code's selected model suggests commit messages, new branch names, and new PR descriptions. You can edit the suggestions or enter details manually. The model has no tools enabled. |
| **Check before sending changes to AI.** | Sensitive filename checks and Gitleaks check the outgoing model request. Findings or scanner failures block generation; you can fix the issue, enter details manually, or cancel. |
| **Review before publishing.** | Commits, pushes, PR publication, and merges require interactive approval. You can inspect the relevant diff or edit the proposal. Enter at the final approval prompt cancels. Staging and approved setup or remediation changes can remain after cancellation. |
| **Push to a predictable destination.** | The default remote is `origin`, with the same branch name locally and remotely. Use `--remote NAME` to choose another remote. Ordinary pushes do not force-update remote branches. |
| **Make PRs and merging explicit.** | Plain `ship` commits and pushes. `--pr` creates or reuses a PR; existing PR text stays unless you edit it. Only `--merge` requests merging. PR targets are selectable, with `main` listed first. |
| **Finish uncommitted work before a PR or merge.** | Both modes offer to ship outstanding changes first or cancel. They require a clean worktree before continuing. |
| **Squash merge and retire the work branch.** | `--merge` combines the PR's commits into one commit on the target. After confirming the merge, it updates and switches to the target, then deletes the reviewed work branch locally and remotely when safe. Blocked or unconfirmed merges keep the branch. |

`ship` leaves test execution to your configured Git hooks and CI; it does not launch a test suite itself or resolve merge conflicts. Normal Git hooks run, and GitHub's required checks and reviews still apply. Secret checks are best effort checks of model requests, not a guarantee that everything being pushed is secret-free. Manual entry can proceed with unresolved findings or an incomplete scan after review.

## Install

You need **macOS 13+**, **Swift 5.9+**, **Git**, **Command Code**, and **Gitleaks**. Install Apple's command-line tools with `xcode-select --install` if Swift or Git is missing.

Install [Command Code](https://commandcode.ai/docs/quickstart) first. Then, with [Homebrew](https://brew.sh), install Gitleaks for local secret checks and GitHub CLI for creating repositories:

```sh
brew install gitleaks gh
cmd login
gh auth login
```

Already signed in? Skip the login commands. `gh` is required for creating GitHub repositories, PRs, and merges. Normal commits and pushes to an existing remote work without it.

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

You're on main. Where should this commit go?
  [1] Commit and push directly to main
  [2] Use the suggested new branch: fix/login-validation

[1] proceed on main  [2] proceed on new branch  [e] edit  [d] review diff  [N] cancel
```

- **On `main`: `1`** commits directly there; **`2`** uses the suggested new branch.
- **On a work branch: `y`** commits and pushes to that branch.
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

| Command                  | What it does                                                      |
| ------------------------ | ----------------------------------------------------------------- |
| `ship`                   | Include all changes, review, commit, and push.                    |
| `ship --staged`          | Include only changes already selected with `git add`.             |
| `ship --remote upstream` | Use the Git connection named `upstream` instead of `origin`.      |
| `ship --pr`              | Generate and review a pull request from your current work branch. |
| `ship --merge`           | Create/reuse a PR, squash merge, and clean up the work branch. **Deletes the branch after**    |
| `ship --help`            | Show help.                                                        |

Options can be combined: `ship --staged --remote upstream`.

## New project?

Run `ship` in the project folder. It offers to initialize Git and create a GitHub repository. You can also connect an existing repository instead.

Setup creates an empty GitHub repository. Uploading code still requires approval at the commit review.

## How branches work

| Where you are                                | What `ship` does                                              |
| -------------------------------------------- | ------------------------------------------------------------- |
| A new project on `main`, with no commits yet | Make the first commit on `main`.                              |
| `main` after the first commit                | Choose a direct commit to `main` or the suggested new branch. |
| An existing work branch                      | Keep that branch and suggest a commit message.                |

Direct commits to `main` require choosing that option at review.

Use direct commits for small fixes when you want to keep things simple. Use a work branch when you have larger changes or need to test one change at a time.

## PRs and merging

From a work branch, run either:

```sh
ship --pr       # Create a PR and leave it open
ship --merge    # Create/reuse a PR, then merge and clean up
```

Both commands ask which remote branch to target. For a new PR, Command Code generates the title and description from the branch's committed changes after local secret checks. You can edit the text or review the diff before approving. An existing open PR is reused; its text is kept unless you edit it.

`--merge` warns if you still have staged, unstaged, or untracked changes. It offers to **ship those changes first and continue**, or **cancel**. `--pr` uses the same check so your PR includes the work you intended.

After approval, `ship` pushes the branch if needed. `--pr` prints the PR link. `--merge` performs a squash merge, respecting GitHub's checks and review requirements. Once the merge is confirmed, it updates your local target branch, switches you to it, and **removes the reviewed work branch locally and remotely**. If merging is blocked or cleanup cannot safely finish, it reports what happened and keeps the remaining branch/work.

There is no automatic merge when running plain `ship` or `ship --pr`. Use `--remote NAME` with any mode to choose a different repository connection. `--staged` is for committing; run it separately before a PR/merge if you want to select only some changes.

## Secrets and failures

Before asking Command Code for a suggestion, `ship` checks sensitive filenames and scans the exact outgoing text with Gitleaks. Possible secrets block generation. It offers appropriate actions: keep a local file out of Git, open your editor to fix source, enter a message manually, or cancel.

For commits, the model receives staged text changes and file metadata, including deleted lines. For PR text, it receives the branch diff from its shared ancestor with the target and the included commit subjects. Binary contents, unstaged changes, other Git history, and remote URLs are excluded. Checks are best effort; manual entry does not make a commit secret-free.

If Command Code or Gitleaks is unavailable or fails, you can enter commit details manually or cancel. If a commit succeeds but its push fails, the commit stays local: run `ship --staged` again to review a push-only retry, or use the retry command it prints.

## Updating and development

After pulling source updates, repeat the build and `install` commands. Run `swift test` for the test suite. See [implementation notes](docs/implementation.md) for the model adapter, scanning rules, Git safeguards, and development setup.
