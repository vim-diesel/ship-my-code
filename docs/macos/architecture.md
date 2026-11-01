# Architecture and execution contracts

This specifies responsibilities and observable contracts. Type names below are proposed names, not a mandate to create an abstraction for every row.

## Targets and source layout

Keep the root Swift package and existing executable. Add a `ShipCore` library product referencing the existing target. Keep the package's macOS 13 deployment target. The app uses the local package dependency; do not copy core sources into the app target.

Create a checked-in native Xcode project with a shared `ShipMac` scheme:

```text
Package.swift
Sources/ShipCore/                 shared domain/services and workflow engine
Sources/ship/                    CLI entry point and terminal adapter
Tests/ShipCoreTests/              existing and new core integration tests
Apps/ShipMac/ShipMac.xcodeproj/    app + app test targets, shared ShipMac scheme
Apps/ShipMac/Sources/             App, presentation models, feature views, graph renderer
Apps/ShipMac/Resources/           asset catalog, app icon, configuration resources
Apps/ShipMac/Tests/               presentation and layout tests
Apps/ShipMac/UITests/             focused XCUITest workflows
```

Use `ShipMac`, `ShipMacTests`, and `ShipMacUITests` as target names. Display name is Ship; use `com.vimdiesel.Ship` as the initial bundle identifier, replaceable for signing if necessary. Do not invent a development team. Use Swift 6 language mode for new app targets. The shared package can retain its existing language mode while concurrency boundaries are audited; full migration must not block app functionality or change CLI behavior unnecessarily.

Prefer Foundation, SwiftUI, AppKit where needed, and the existing command-line tools. Do not introduce an Xcode project generator, database, web renderer, dependency-injection framework, or Git replacement for v1.

## Ownership

| Component | Responsibility |
| --- | --- |
| `AppModel` (`@MainActor`, observable) | Recent projects, window routing, settings, application-owned sessions. |
| `RepositorySession` (observable presentation state) | Selected worktree/remote, refreshed snapshots, current operation, UI selections; never directly issues mutating Git commands. |
| Repository service | Discovery, read snapshots, explicit staging, diffs, ref/worktree enumeration, history, dependency capabilities. |
| Workflow engine/session | Typed prepare/review/execute/recover state machine for ship, PR, merge, and reviewed branch actions. |
| Mutation coordinator | Explicit exclusive operation lease keyed by canonical common Git directory; lifecycle spans awaited work. |
| Process executor | Argument-array execution, environment policy, concurrent pipe I/O, limits, timeout, cancellation, structured failures. |
| Scanning/generation services | Existing immutable request construction, Gitleaks and Command Code contracts. |
| GitHub service | Explicit remote identity, PR read/create/edit/merge, merge verification; no UI text. |
| History loader/layout | Deterministic commit/ref data and lane geometry; renderer independent of workflow policy. |
| Metadata store | Atomic, versioned local app state and minimal recovery records. |

A single actor is not sufficient to serialize mutations across `await`: actor methods are reentrant. Acquire an explicit lease/token and reject or queue conflicting actions until release. Keep the lease across scans, prompts, and approved mutations, or explicitly invalidate review if the lease is released. For v1, hold one workflow lease from preparation through terminal state; reads may continue but must be revision-aware. The same window can cancel its preparation to perform unrelated staging.

Do not claim exclusion of external Git processes. Git locks, fresh validation, expected-SHA ref updates, and postcondition checks are still necessary. Avoid long-lived custom `.git/index.lock` files and never delete another process's Git lock. Map linked worktrees through `git rev-parse --git-common-dir` and their individual Git directories, not assumptions about a `.git` folder.

## Typed workflow boundary

The core emits data, not English prompts to parse. Establish these concepts:

| Value | Required information |
| --- | --- |
| Repository identity | Canonical worktree root, worktree Git directory, common Git directory. |
| Snapshot | Symbolic HEAD or detached state, optional HEAD OID, staged tree when valid, working-state signature, operation/conflict status, selected remote identity, relevant local refs and comparison. |
| Prepared request | Immutable bytes, request identifier/digest, source snapshot, line map, filename findings, intended generation kind. |
| Scan result | Findings and successful-scan versus unavailable/failure; bound to exact request bytes. |
| Proposal | Validated commit/branch or PR title/body, source, scan outcome, snapshot/revision. |
| Review | Operation/request ID, revision, exact source/destination/target, intended effects, warnings, outgoing commits or explicit unknown state. |
| Decision | Typed user choice tied to the currently pending request/revision; edited values revalidated. |
| Operation event | Phase, progress if measurable, structured result/error, completed effects, recovery options. |
| Recovery record | Operation kind/ID, repository reference, timestamps, completed phases, expected OIDs/refs, known normalized PR identity; no approval authorization. |

Expose asynchronous operations and an event stream (for example, `AsyncStream<WorkflowEvent>`). A pending decision may use a typed continuation/request ID. Reject duplicate, late, mismatched, or already-consumed decisions. Cancellation resumes pending waits exactly once. Avoid generic prompt-string protocols in the GUI and boolean `approved` flags without a review identity.

The CLI parses its own options and choices into the same decisions. Keep help text, interactive-terminal requirement, exit codes, first-commit behavior, explicit main choice, and Enter-to-cancel behavior. Move TTY handling and process signal registration to the CLI boundary. The app must never install CLI-wide signal handlers or use the global `Interrupt.requested` flag for individual operations.

## State transitions

```text
idle → preflight → setup decision (when needed) → selection preparation
     → capture snapshot → build payload → scan
         ├─ findings/failure → remediation or manual details or cancel
         │                       └─ changed payload → capture + build + scan again
         └─ clean → generate or manually enter proposal
     → review → validate current state → execute → verify → completed
                                                └─ partial/uncertain → reconcile/recovery
```

PR/merge adds dirty-work handling, visible fetch, target selection, merge-base capture, PR lookup, PR review/publication, and a separate merge review. Existing PR reuse bypasses generation unless the user explicitly requests new generated text; any generation still requires scanning.

Changing staged content, target, provider request, or relevant repository state invalidates dependent proposals/scan results and approvals. Merely editing the commit message locally requires validation and refreshed review, not a new AI call. AI regeneration uses a freshly validated request. An old clean scan cannot authorize different bytes.

## Process execution and concurrency

- First make the existing executor usable away from the UI thread. A bounded blocking-I/O queue bridged with continuations is acceptable; a nominally async method that blocks the main actor or cooperative executor is not.
- Drain stdout and stderr concurrently while delivering stdin; retain bounded output and detect partial transfers. History streaming needs a separate bounded/paged contract, not unbounded capture.
- Keep cancellation operation-scoped. Track owned processes, close owned pipes, and await completion/reconciliation before releasing the lease. Never terminate unrelated processes.
- Respect Git hooks and existing timeout semantics. A long Git/hook action must remain cancellable and visibly running; do not indiscriminately apply the model timeout to hooks. Model generation retains its 90-second limit.
- GUI processes must not inherit terminal stdin/stdout for interactive authentication. Prefer existing credential helpers/SSH agent. Disable unavailable terminal prompting for app-initiated Git operations and show a specific authentication-recovery action if interaction is required. Preserve CLI behavior separately.
- Resolve executables once per operation after capability checks. Do not evaluate login shells, source user shell files, or search relative/repository PATH entries. Details are in [platform.md](platform.md#command-line-dependencies).
- Prefer `Sendable` immutable results and narrow isolation. Audit existing `@unchecked Sendable` captures rather than declaring the entire core unchecked.

## Freshness and file observation

Observe the worktree and resolved Git/common directories using a thin native file-observation adapter. Debounce events, ignore self-generated bursts, and run bounded refresh jobs. Also refresh on activation, after owned operations, and on explicit Refresh. Watch events can be dropped; treat them as hints, not the source of truth.

Each refresh has a revision/request ID; discard late results after repository/remote/selection changes. Capture related refs consistently or detect/refetch a changed snapshot. During an active review, a relevant external change marks the review stale and disables execution. An unrelated file edit excluded from Staged only should not automatically stage it; enforce the operation-specific invariants instead.

No background network fetch in v1. Explicit Fetch updates/prunes selected remote-tracking heads, without merging, deleting local branches, fetching arbitrary tags, or recursively updating submodules. PR/merge target preparation fetches visibly. Network failure preserves local browsing and marks remote state unknown/stale.

## Persistence

Use a versioned Codable JSON store under `~/Library/Application Support/Ship/` with atomic replacement. Use preferences for simple appearance/settings values. Store recent/pinned repository bookmarks or URLs, selected remotes, window layout, executable/editor paths, and minimal recovery metadata. Store ordered project IDs explicitly. Handle missing/moved folders without creating or initializing them.

Git is authoritative. Commit metadata and diffs may be cached in memory with bounded size; no persistent repository-content index in v1. Do not persist source, complete model requests/responses, scanner matches, raw subprocess diagnostics, generated drafts, or credentials. A recovered operation always needs fresh state and fresh approval before further mutation.

Recovery records must include only the identifiers needed to reconcile effects. Normalize and strip credentials from URLs; do not save raw remote URLs or environment dumps. Treat commit/ref names as untrusted display data. Preserve control/bidi escaping where needed to prevent misleading review text.

No key storage is needed for the Command Code provider. If a future provider needs credentials, use Keychain; it is outside v1. No CloudKit/iCloud synchronization or application telemetry is required.

## Invariants

1. **Exact request scanning:** the transmitted bytes are the successfully scanned bytes. Filename checks include both old/new rename paths; additions, deletions, context, metadata, and included PR subjects are scanned. Binary bodies, unrelated history, unstaged source, repository root, and remote URLs remain excluded from AI requests.
2. **Fail closed for generation:** findings, scanner failures, unsupported model capabilities, and invalid request state never result in unscanned model transmission. Manual entry can proceed only through the normal review with unresolved findings/failure visible.
3. **Model isolation:** retain the tool-free Command Code completion adapter, private temporary directory, stdin payload transfer, no-session/no-skills isolation, validated JSON schemas, no raw diagnostic disclosure, and no automatic generation retries. Preserve validation limits documented in `docs/implementation.md`.
4. **Selection preservation:** remediation and Staged only retain unrelated index/worktree changes. Do not delete local sensitive files, overwrite symlinks, or broaden staging after an approved repair.
5. **Approval identity:** verify source branch, HEAD, staged tree, destination identity, comparison, and PR target/cleanliness as applicable immediately before mutations. Recheck after hooks. Branch policy is enforced in the engine, not only by disabled buttons.
6. **Explicit publication:** pushes use the approved same-named refspec and set upstream; ambient mirror/follow-tags/submodule settings cannot expand publication. Normal shipping never implicitly opens/merges a PR.
7. **Remote uncertainty:** a network error does not prove no remote effect. Reconcile before retry; no automatic mutation retries or destructive rollback.
8. **Merge verification:** match the reviewed PR head, confirm merged state, fetch and verify the reported merge commit in target history before cleanup. Queued/unconfirmed merges keep branches.
9. **Conditional deletion:** source deletion uses expected SHAs, remote leases, local compare-and-delete, and worktree checks. A missing remote ref alone is not proof the local branch is safe to delete.
10. **Honest cancellation:** cancellation stops future work and reports any already applied staging/setup/remediation/commit/remote effects. It does not promise transactional rollback.

Do not weaken these invariants to make a graphical happy path easier. Reuse existing tests as executable examples, while adding coverage for the newly exposed UI/async boundary.
