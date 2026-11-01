# Implementation sequence and progress ledger

Implement in order. Each milestone must leave the existing CLI usable and the code buildable. The next milestone may begin after the preceding exit criteria are met; do not use UI polish to postpone core integration. Preserve unrelated checkout changes.

## M1 — Extract the shared workflow engine

Scope: the typed boundary, core library product, asynchronous execution bridge, operation-scoped cancellation, and terminal adapter described in [architecture.md](architecture.md).

1. Inspect the current test fixtures and run a baseline once. Record pre-existing failures separately.
2. Add the `ShipCore` library product without changing CLI arguments or deployment target.
3. Extract decisions/events and snapshot-bound review for ordinary ship first. Keep real Git/scanner/model adapters in use through the CLI.
4. Extract repository setup, remediation, PR preparation/publication, and merge/cleanup into the same domain boundary. Remove UI wording/TTY assumptions from shared service decisions.
5. Introduce explicit mutation leases and per-operation cancellation; keep CLI signal handling at the executable boundary. Ensure the shared executor can run without blocking the app's main actor.

Exit: the CLI builds and existing workflow/PR/setup/safety scenarios pass with the new boundary. Add focused tests for stale/duplicate decisions, operation cancellation, and lease behavior across suspension. No GUI parsing of console prompts is planned or needed. Record any intentional internal API changes.

## M2 — Create the native repository workspace

Scope: P01–P06, foundational P19, dependency resolver, project persistence, and initial native appearance.

1. Create the Xcode project/targets/shared scheme and local ShipCore dependency at the specified paths.
2. Implement welcome/recent projects, Open Folder, repository discovery, settings/dependencies, setup sheets, and multiple windows.
3. Build Changes view with real status, staged/unstaged/untracked sections, file-level stage/unstage, and unified/side-by-side local diff views.
4. Add snapshot refresh, file observation, application activation refresh, and per-window selection restoration. Persist only approved metadata.
5. Use native split navigation, inspector, toolbar, and navigation tabs from the beginning. Add fixture-driven previews without invoking Git/model work in preview construction.

Exit: open a temporary repository from Finder-launched app, inspect actual files/diffs, stage/unstage selected files, preserve partial staging until explicitly changed, and exercise setup against a fake GitHub service. CLI still builds. App has working loading/error/empty states, not only sample content.

## M3 — Complete shipping and remediation

Scope: P07–P13, P19–P20 for commit/push, full integration with existing scanner/model behavior.

1. Connect Review & Ship to the shared preparation/state machine.
2. Implement branch choice, editable proposal/manual details, scan findings and repair actions, outgoing-commit review, and exact destination approval.
3. Connect real Git commit/push to local test remotes, hooks, cancellation, and postcondition verification.
4. Implement push-only behavior and local-commit/push-failure recovery. Reconcile interrupted operations without replaying approval.
5. Verify a generation request through the production Command Code adapter using a fake executable; expose authentic capability failures/manual fallback when actual tools are unavailable.

Exit: a new and an existing temporary project can be shipped entirely from the app, including direct main, suggested branch, existing branch, Staged only, secret remediation, and manual fallback. A failed push can be recovered without duplicate commit creation. This is the first useful end-to-end desktop build.

## M4 — Implement interactive Git history

Scope: G01–G09 and P18, excluding the dedicated stale cleanup UI until M5.

1. Add ref/worktree/history reading and deterministic graph layout with stable paging.
2. Render Canvas topology with virtualized accessible rows and selectable refs/working changes.
3. Add inspector details, diffs, two-selection comparison, search, filters, and explicit fetch freshness.
4. Implement reviewed create/switch/publish branch actions through the shared core.
5. Wire menu and drag interactions to PR/merge preparation intents; complete their execution in M5. No gesture performs a hidden mutation.

Exit: real branching/merge history is correctly rendered across page boundaries; graph actions modify only reviewed refs; a detached/unborn/shallow repository is understandable. Profile the synthetic large-history fixture and record results. Avoid shipping a smooth but inaccurate ancestry display.

## M5 — Complete PRs, merge, and reviewed cleanup

Scope: P14–P17, remaining P19–P20, G10 and graph PR/merge routing.

1. Implement visible target fetch/selection, dirty-work handling, existing PR reuse, generated/manual PR editing and publication.
2. Add PR list/status and an explicit final Merge & Clean Up review.
3. Preserve match-head merging and verified post-merge target update/conditional source deletion.
4. Implement stale-branch review with ancestry or exact verified PR evidence and linked-worktree checks.
5. Exercise remote uncertainty, blocked checks, queued merges, changing refs, and partial cleanup with fake GitHub responses and real local Git refs.

Exit: a feature can be shipped, represented by a PR, squash merged, and retired through the app's shared workflow. Failed or uncertain remote outcomes preserve work and produce correct next actions. Stale cleanup never treats remote absence as preservation proof.

## M6 — Finish Mac behavior and prepare release

Scope: all visual/accessibility/platform acceptance requirements and release preparation.

1. Finish interactive glass, adaptive layout, accessible graph/input, native menus/shortcuts, icon, and window restoration.
2. Validate Finder launch with constrained PATH, missing dependencies, authentication failures, long operations, and multiple windows/worktrees.
3. Run the focused UI matrix and large-history/diff profile. Fix material failures; do not expand into deferred Git features.
4. Run the complete relevant automated suites once against the final changes, build release CLI/app, and document commands/results.
5. Prepare archive/distribution instructions. Sign/notarize only when authorized and credentials exist; otherwise leave that exact external prerequisite recorded.
6. Update user documentation with actual app installation/use, supported limitations, and CLI compatibility. Replace future-tense handoff status only for features actually complete.

Exit: all product and graph acceptance scenarios pass, required capabilities are available without a terminal-only happy path, and the actual release readiness/signing state is accurately documented.

## Progress ledger

As of handoff creation, no application implementation or runtime validation has been performed for these milestones.

| Milestone | Status | Evidence / next step |
| --- | --- | --- |
| M1 Shared engine | Not started | Inspect source and fixtures, record baseline, then expose the library and extract typed ship decisions. |
| M2 Native workspace | Not started | Depends on M1. |
| M3 Shipping | Not started | Depends on M1–M2. |
| M4 Graph | Not started | Depends on workspace and shared mutation boundary. |
| M5 PR/merge/cleanup | Not started | Depends on shipping and graph action routing. |
| M6 Polish/release | Not started | Depends on working required features. |

At the end of each implementation session append a concise entry:

```text
Date / source revision:
Milestone and completed requirement IDs:
Implemented behavior:
Validation commands and outcomes:
Known gaps / external blockers:
Next concrete step:
```

Do not mark a milestone complete because code exists, previews render, or test doubles return success. Its real local Git behavior and acceptance criteria must be demonstrated. If the user requests a subset, complete that subset and state which milestones remain; do not silently change the overall completion definition.

## Change control

Routine implementation details can be resolved using these requirements and documented in the ledger. A different backend, raised CLI minimum OS, changed AI provider/privacy boundary, force-deletion policy, or removal of a required workflow is a product/architecture change; record the reason and follow the current user's direction. Unavailable credentials or one unavailable optional API do not justify stopping unrelated local implementation.
