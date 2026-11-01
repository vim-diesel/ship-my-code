# Product and workflow specification

All behaviors below are v1 requirements unless explicitly marked deferred. IDs are used by the validation matrix.

## Window and navigation

**P01 — Repository workspace.** Use a `WindowGroup` with one repository session per worktree and multiple windows allowed. A welcome view offers Open Folder and recent projects. Opening a child directory resolves the containing worktree root. A new non-Git folder enters setup. A broken/inaccessible repository does not become an initialization candidate.

Use a sidebar for recent/pinned projects and the active repository's branches, remotes, and tags. The central workspace has Changes / History / Pull Requests navigation tabs. A collapsible inspector shows the current selection. A bottom activity area shows structured operation progress and recovery. Sidebar groups, inspector visibility, column widths, and selection restore per repository.

At normal widths show sidebar + workspace + inspector. At narrow widths collapse the inspector first, then the sidebar, keeping the workspace usable. Use an approximately 1280 × 820 default window and a 900 × 600 minimum; verify these values with real content and accessibility text sizes.

Toolbar: project name, current branch, remote selector, explicit Fetch, Review & Ship, and a menu containing Create Pull Request / Merge & Clean Up. The current repository and source/target must remain clear in review sheets. No operation may silently apply to the previously focused window.

**P02 — Multiple windows.** Windows on the same worktree share live repository state and mutation exclusion. Linked worktrees share common-repository coordination. Independent repositories remain responsive during another repository's operation.

## Setup and dependencies

**P03 — Setup.** Show the chosen folder and ask before initializing Git on `main`. For a missing selected remote, offer existing remotes, connecting a repository URL, or creating an empty GitHub repository. Creation includes editable name and owner, private visibility as the initial selection, and explicit public visibility selection. It must not upload source during setup. Explain any completed initialization or remote creation if the user later cancels shipping.

**P04 — Tool readiness.** Settings lists detected executable paths, versions/capabilities, and authentication readiness. Git is required for repository operations. Command Code and Gitleaks are required for AI generation; manual entry remains available when either fails. `gh` is required only for GitHub setup/PR/merge features. Present actionable installation/login guidance and Recheck. Never install dependencies or change shell settings automatically.

## Changes and selection

**P05 — Changes view.** Show separate staged, unstaged, and untracked sections with file status, rename paths, addition/deletion counts where available, and a selectable diff. Clearly label staged versus working-tree content. Offer unified and side-by-side text diffs with line numbers and ordinary text selection. Binary changes and submodule pointers receive metadata views; no embedded source editor or binary editing in v1.

Use full local diffs, loaded per file and paged when large. A viewer limit must be labeled and offer continuing/loading or opening externally; it must not silently truncate the AI payload or claim a partial diff is complete. Local source display can contain secrets; scan summaries, activity, telemetry, and logs must not echo them.

**P06 — Selection scope.** Review & Ship defaults to All changes across the repository. Opening a repository, selecting a file, or changing a scope picker performs no staging. Starting preparation with All changes explicitly stages once with the existing semantics. Staged only preserves the index. Show the selected scope and excluded changes in the review.

File-level Stage / Unstage actions are explicit immediate index mutations. Stage means all current changes for that file; if a file is partially staged, explain that staging the file includes its remaining changes and require that choice explicitly. Unstage preserves working bytes, including for an unborn repository. After a manual file selection action, use Staged only for that preparation so All changes cannot unexpectedly reinclude excluded files. Do not repeatedly stage all after remediation.

Hunk selection is deferred. Existing partial staging must still survive review, remediation, and cancellation.

## Shipping

**P07 — Preparation.** Run preflight, prepare the selected index, capture state, build the outbound payload, scan it, and request a proposal if allowed. Display meaningful progress and Cancel. The app must be responsive while hooks, scans, Git, or the model run. Opening a repository never starts model generation.

**P08 — Proposal.** Display editable conventional commit message, proposal source (Command Code / Manual / Local suggestion), branch choice, selected files, scan outcome, destination, outgoing existing commits, and the proposed new commit. Include local-only full diff review. Preserve message and branch validation from the CLI. Invalid model output offers manual entry or cancellation, with no automatic retry loop. An explicit Generate Again action may start a newly validated request; scan its exact bytes before sending.

**P09 — Branch policy.**

| State | Behavior |
| --- | --- |
| Unborn `main` | First commit establishes `main`; no suggested work branch required. |
| Established `main` | Present Commit on main / Create suggested branch. Require an explicit destination choice for this operation. |
| Existing work branch | Keep its name; edit only the message. |
| `master` or another known remote default branch | Require a new work branch. |
| Detached HEAD | Allow history inspection; disable shipping with guidance to create/check out a named branch. |
| Existing conflict or unfinished Git operation | Allow inspection; explain why mutation is blocked and how to handle it externally. |

Do not persist a blanket permission to publish to `main`. Push-only recovery on `main` also needs a new explicit operation review. The initial-root-commit recovery exception remains supported.

**P10 — Approval and execution.** A click on Review & Ship prepares a proposal; it does not approve the final commit/push. The review button describes the actual effect (for example, Commit & Push to origin/main). Closing/dismissing or pressing Escape cancels. Do not bind plain Return to publication or deletion; use deliberate clicks or a documented modified keyboard shortcut. CLI Enter continues to cancel.

Before executing, revalidate the reviewed state and destination. Follow normal hooks. If the resulting commit/index/message/parent/branch differs from approval, stop before pushing and explain the local result. Push only the approved same-named branch with explicit refspec/upstream. Show an honest completed/partial/unknown result.

**P11 — Nothing to commit / push-only.** If existing commits need publication, offer a reviewed push without a model call. Otherwise show Nothing to ship. Comparisons use local remote-tracking information, with last-fetch/staleness information. Unknown outgoing counts remain unknown. Plain preparation does not silently fetch.

## Scanning and remediation

**P12 — Outcomes.** Distinguish Not checked / Checking / No findings in outbound request / Findings / Check unavailable or failed. Findings and failures prevent all model transmission. Manual entry is allowed with the unresolved state visible through final review. There is no Send anyway control. Describe scanning as best-effort protection of the model request, not certification of all outgoing Git history.

**P13 — Actions.**

| Finding | Offered action |
| --- | --- |
| New sensitive local file | Ignore and keep locally; remove from index; stage only the intended exact ignore entry. |
| Already tracked sensitive file | Stop tracking and keep locally after explaining the next commit removes it from version control and prior history is unchanged. |
| Secret in source | Open configured editor, then explicitly Recheck; review staging changes before replacing the selected version. |
| Secret-bearing deletion | Local editable cleanup message, with no model call. |
| False positive, unavailable scanner, or generation failure | Manual details or Cancel. |

Preserve independently staged and unstaged `.gitignore` edits, unrelated changes, unusual paths, symlinks, and partial staging. If a safe automated repair is ambiguous, provide manual handling and Recheck. Never suggest ignoring application source merely because it contains a secret. Approved index/ignore edits survive later cancellation and must be reported.

Findings display path, location when known, and rule/reason only. Review may navigate to the local diff, but matched secret/source excerpts never become finding-report fields.

## PRs and merging

**P14 — Dirty-work gate.** PR/merge starts from a committed work branch. If staged, unstaged, or untracked changes exist, show Ship changes first and continue / Cancel. Shipping still receives its own reviewed approval. On return require a clean worktree, the same source branch, and a fresh snapshot. Do not stash, discard, or silently omit remaining work.

**P15 — PR preparation.** Fetch selected remote heads as a visible preparation step. Select a remote target, with `main` first and source excluded. Show source → target, commit list, merge-base diff, and outgoing branch publication if needed. Generate title/body only after scanning the branch payload, or use manual text. Reuse the matching same-repository/head/base open PR and retain existing text unless edited. No model request is needed just to reuse it. Provide edit/preview tabs for plain Markdown text; external images/content must not auto-load.

Create Pull Request publishes the reviewed branch if needed and creates/updates the approved PR, then shows its URL. It does not merge. Fork PR creation and cross-repository merge management are deferred; display unsupported cases clearly.

**P16 — Merge & Clean Up.** Prepare/reuse the PR and then show a separate final merge review identifying PR, source SHA, target, squash behavior, and intended cleanup. This is distinct from approving commit/push or PR publication. Display checks/review status when available and link to GitHub. GitHub remains authoritative; no administrative bypass or auto-merge enrollment.

On approved merge, match the reviewed head SHA. A queued, rejected, or unconfirmed result preserves branches. After confirmed merge, fetch and verify the target contains GitHub's reported merge commit; safely update/switch the local target; remove the remote and local source only when they still match the reviewed tip. Divergence, dirty state, changed identity, another worktree using a branch, or changed refs stops the affected cleanup. Show completed and remaining steps separately.

**P17 — Pull Requests view.** List open PRs for the selected repository with source/target, title, state, and status details when available. Support selection, Open on GitHub, and manual Refresh. PR mutations are enabled only for the matching checked-out local work branch and supported repository identity. Selecting an unrelated PR may offer a reviewed branch switch; selection alone never checks out or merges. Preserve offline/unavailable status rather than claiming checks passed.

## History, activity, and recovery

**P18 — History actions.** Implement the required [Git graph interactions](git-graph.md), including comparison, branch creation/switching, drag-to-prepare PR/merge, and conservative stale-branch cleanup.

**P19 — Activity and recovery.** Show structured events such as Staged changes, Checked request, Created branch, Committed locally, Pushed, Created PR, Merged, Updated target, and Deleted reviewed branch. Events identify partial completion without raw subprocess output. Keep an in-memory searchable activity list; persisted recovery records contain only the minimal metadata defined in architecture.

| Result | Required next action |
| --- | --- |
| Branch created, commit failed | Show actual branch/HEAD; preserve branch/work; offer fresh review. |
| Commit created, push failed | Show local SHA and possible remote acceptance; inspect remote/read fresh state before reviewed retry; provide exact safely quoted retry command. |
| Hook changed commit | Show local commit exists and publication stopped; require a new review. |
| PR publication/merge response uncertain | Retain known PR identity/URL; Refresh status before retrying; never blindly repeat mutation. |
| Merged, cleanup incomplete | Show confirmed merge plus exact remaining steps; revalidate before any retry. |
| App closed/crashed mid-operation | On reopening, inspect Git/GitHub and reconcile state; never replay an approval or assume rollback. |

**P20 — Cancellation and app lifecycle.** Cancellation stops future steps and cooperatively stops owned subprocess work where possible; it cannot undo an already accepted remote action. Keep observing/reconciling the result before unlocking the repository. If closing the owning window during mutation, offer Keep running / Cancel operation, with the operation owned by the application session rather than the view task. Quit during active mutation requires a clear user choice; persist enough metadata to reconcile an interrupted operation.

## Completion boundary

All P01–P20 are required across M1–M6. General Git conflict editing, history rewriting, integrated test running, alternative AI providers, and automatic branch pruning are not shortcuts for missing v1 behavior. Git hooks and CI continue to own test execution in the shipping workflow.
