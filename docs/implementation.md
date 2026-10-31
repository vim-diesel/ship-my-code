# Implementation notes

For installation and normal use, start with the [README](../README.md).

## Project layout

A Swift package with no third-party Swift dependencies:

- `Sources/ship/main.swift`: executable entry point and signal handling.
- `Sources/ShipCore/Ship.swift`: interactive workflow and final approval.
- `RepositorySetup.swift`: Git initialization and GitHub setup through `gh`.
- `Git.swift`: repository checks, staged changes, branch validation, and explicit pushes.
- `Privacy.swift`: immutable request construction and Gitleaks scanning.
- `Model.swift`: commit/PR proposal validation and Command Code adapter.
- `PullRequests.swift`: GitHub PR generation, target selection, merge verification, and branch cleanup.
- `Remediation.swift`: ignore/untrack and editor actions.
- `ProcessRunner.swift`: concurrent subprocess input, output, cancellation, and timeouts.
- `Support.swift`: terminal input, options, temporary directories, and shared helpers.

## Command Code adapter

The integration was checked with Command Code **1.88.2**. It uses the documented [Mod API](https://commandcode.ai/docs/mods), specifically `cmd.model.complete`, which makes a completion on the session's selected model without transcript context or tools. No model SDK or separate API key is required.

For each generation request, `ship` creates a private temporary directory containing a static adapter module. It starts `cmd` there with a static bootstrap query and sends the scanned payload through stdin. The adapter reads the stream through EOF, invokes `model.complete`, returns a JSON envelope, and exits before the ordinary agent request runs. The adapter is removed afterward; request contents are not written to a prompt file or session transcript.

The CLI invocation uses `--mod`, `--no-session`, `--no-skills`, `--skip-onboarding`, `--no-auto-update`, `--permission-mode dont-ask`, and `--max-turns 1`. Tools are filtered out and a blocking tool hook provides an additional guard. The turn and session flags alone are not tool restrictions. Effort is not forced because supported effort levels differ by model.

The model request includes instructions, old/new relative paths, change metadata, and complete staged text patches: additions, deletions, and context. Binary changes are metadata-only, including when Git attributes force a text diff. Repository roots, remote URLs, Git history, unstaged content, and binary bodies are excluded.

For a commit, the expected response is one JSON object with exactly `branch` and `message`. For a PR it has exactly `title` and `body`; titles are single-line and up to 256 UTF-8 bytes, descriptions up to 16 KB with no terminal controls except newline/tab. The completion output budget is 1024 tokens for commits and 4096 for PRs. `branch` must be null when keeping the current branch. Messages must be single-line conventional commits of at most 500 UTF-8 bytes, without terminal controls. New branch names are validated by Git and checked against protected, local, and locally known remote names. Generated values are never executed as commands.

A generation subprocess has a 90-second timeout and no automatic generation retry. Unsupported capabilities, failed requests, and invalid output offer manual entry or cancellation. Raw model output and subprocess diagnostics are withheld. The bootstrap query contains no repository data if the adapter cannot load.

## Local sensitive-data checks

Filename checks are case-insensitive and cover old and new rename paths:

| Pattern | Reason |
| --- | --- |
| `.env`, `.env.*` at any depth | Environment files |
| `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`, `identity` | Common private-key names |
| `*.key`, `*.pem`, `*.p12`, `*.pfx` | Keys or bundles; public certificates can be false positives |
| `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.git-credentials` | Credential stores |
| `.aws/credentials`, `.docker/config.json`, `gcloud/application_default_credentials.json` | Known credential paths at any depth |

Only `.env.example`, `.env.sample`, `.env.template`, and `.env.dist` are exempt from the environment filename rule. Their content is still scanned. Ordinary JSON and configuration files are not broadly excluded.

Gitleaks was checked with **8.30.1**. It scans the same immutable request bytes later delivered to the adapter. Changed requests must be rebuilt and scanned again. Configuration extends built-in rules in a private temporary directory, with an empty ignore file, inline allow comments disabled, full redaction, and no file-size skipping. Ambient `GITLEAKS_*` overrides are removed. Installed help and fabricated positive/negative probes establish the stdin contract: exit 0 is clean, configured exit 23 means findings, and other statuses or inconsistent reports mean failure.

Reports contain rule IDs and line locations, never matched secrets or source excerpts. Only static scanner rules, a report template, and an empty ignore file are written to disk. Scanning is best-effort protection of the model request, not an audit of all confidential data, binary contents, or outgoing Git history.

Remediation preserves unrelated changes and partial staging:

- New sensitive local files can be removed from the index and exactly ignored while retaining their bytes. Staged and unstaged `.gitignore` versions are handled independently.
- Stopping tracking an existing file requires confirmation. Secret-bearing deletion diffs use local, editable commit suggestions rather than a model call.
- Source edits use `VISUAL` or `EDITOR`, parsed as arguments without shell evaluation. GUI editors should use a wait option, such as `code --wait`. Replacing a fully staged version requires local diff review and approval; ambiguous or partial selections require manual staging.
- Unresolved findings and unsuccessful scans stay visible during manual review. Approved remediation edits remain if the user later cancels.

## Git behavior and recovery

Git operations use argument arrays at the repository root. Default staging includes the entire repository; `--staged` preserves the current selection. The tool checks for detached HEAD, conflicts, unfinished Git operations, and redirected repository/index environment variables before staging. New repositories and missing remotes use the interactive setup flow; `gh repo create` is never called with `--push`.

The first commit on an unborn `main` stays on `main`. On an established `main`, the final review explicitly offers a direct commit or the proposed new work branch. The direct-main permission applies only to that approved operation, including push-only recovery. `master` and other known remote default branches still require a work branch. A single root commit on `main` can also be published during recovery if there is no locally known destination branch. Existing work branches retain their names.

Push previews use local remote-tracking information without fetching. Comparisons can be stale; an unavailable comparison is reported as unknown. Before approved actions, branch, HEAD, staged tree, destination, and the local comparison are rechecked. Normal Git hooks run; a changed commit tree, index, message, parent, or branch stops the push.

Pushes use an explicit same-named branch refspec and upstream, with follow-tags, mirror behavior, and recursive submodule pushing disabled. Normal shipping never merges, rewrites history, stashes, resets, deletes branches, or creates PRs. Only the explicit `--pr`/`--merge` modes perform GitHub PR operations.

If committing fails after branch creation, the branch remains and the current state is reported. If pushing fails, the commit remains local and an exact shell-quoted retry command is printed. A later invocation supports push-only recovery. A transport error can occur after a remote accepts a push, so failure does not imply the remote is unchanged.

## PR and merge operations

`--pr` and `--merge` start from a committed work branch. A dirty worktree/index offers to run the normal ship flow first, or cancel. No edits are stashed, discarded, or silently excluded. These modes fetch the selected remote's heads before target selection; plain ship still uses local comparisons without fetching.

Targets are remote branches, with main first and the source excluded. The model payload uses the merge-base-to-HEAD diff, reusing the same binary omission, filename checks, line mapping, and Gitleaks scanner as commit generation. Metadata and commit subjects are included in the scanned bytes. Flagged/failed scans or generation failures permit manual PR text or cancellation.

GitHub CLI receives an explicit repository, head, base, title, and a description through `--body-file -`. Remote URLs are normalized to an HTTPS repository identifier without credentials. Open PRs for the same repository/head/base are reused rather than duplicated; existing text is changed only if edited during review. Branch/HEAD/index, worktree cleanliness, destination, and target ref are rechecked before publication.

Merges use `gh pr merge --squash --match-head-commit SHA`, with no administrator bypass. PR head/base identity is verified. A queued or unconfirmed merge leaves branches intact. After a confirmed merge, ship fetches the target and verifies it contains GitHub's reported merge commit before switching/fast-forwarding locally. Divergence or new local edits stop cleanup. Remote source deletion is conditional on the reviewed tip via a lease; it cannot delete a branch that acquired new commits. The local source ref is removed with a compare-and-delete against its reviewed SHA, which also handles squash merges without relying on ancestry.

PR creation or merging can succeed remotely even if the following network request fails. Errors retain the PR URL when known and direct the user to inspect GitHub; no destructive rollback or automatic mutation retry is attempted.

## Development

```sh
swift build -c release
swift test
```

Tests use temporary repositories, local bare remotes, fake executables, and fabricated data. The workflow fixtures call the production Command Code adapter against a fake `cmd`, including its capability checks and JSON envelope. They do not require a live model or real GitHub repository. An optional scanner check uses installed Gitleaks with fabricated credentials.

For environments that cannot write user caches:

```sh
CLANG_MODULE_CACHE_PATH="$PWD/.build/clang-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PWD/.build/module-cache" \
swift build -c release --build-system native --cache-path .build/cache --disable-sandbox
```

Editor launch configuration uses the current workspace folder. Local `.build`, `.swiftpm`, `.commandcode`, and `.DS_Store` files are ignored by Git.
