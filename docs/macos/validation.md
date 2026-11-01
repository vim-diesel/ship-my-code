# Validation and acceptance

## Approach

Use the existing temporary repositories, bare remotes, fake `cmd`, fake `gh`, and scanner fixtures in `Tests/ShipCoreTests`. Exercise production parsing and adapter code with fabricated inputs. Keep tests focused on behavior that could lose work, disclose content, publish the wrong state, misrepresent history, or fail to recover.

Do not call a live model with repository content or mutate real GitHub repositories to prove development behavior without applicable user authorization. Use fabricated credentials for scanner probes. Do not install software globally or alter the user's normal projects just to create a test fixture.

Run one baseline before the engine refactor, focused relevant tests after changes, and one broad regression pass at milestone/release integration points. Repeat only after a relevant change/failure. Documentation-only work requires link review and `git diff --check`; no Swift build is required.

## Existing coverage to preserve

| Current suite | Preserve coverage of |
| --- | --- |
| `RepositorySetupTests` | New project creation, visibility, name/remote selection, cancellation, existing connections, broken Git handling. |
| `WorkflowTests` | Branch policy, whole-repository/staged-only selection, edit/diff/cancel, model fallback, scanning, remediation, push retry, hook/state changes. |
| `SafetyTests` | Schema/ref validation, binary omission, filename/content scanning, scanner failure semantics, partial staging, odd paths, subprocess pipe handling, exact push behavior. |
| `PullRequestTests` | Direct main choice, PR generation/reuse, dirty-work gate, merge cleanup, blocked payloads, publication state changes, rejected merge handling. |

## Acceptance scenarios

| ID | Requirements | Required result |
| --- | --- | --- |
| A01 | P01–P04 | Open a nested project folder and resolve its worktree; initialize a genuinely new folder only after explicit choice; broken repository never gets reinitialized. Dependency guidance works from Finder. |
| A02 | P02, P20 | Two windows on the same/common repository cannot overlap mutations across suspension. Another repository stays responsive. Window close/cancel does not orphan ownership or falsely report rollback. |
| A03 | P05–P06 | Staged/unstaged/untracked contents are distinguishable; Stage/Unstage preserves disk bytes. Existing partial staging survives Staged only, review, and cancellation. File-level staging explicitly includes remaining file edits. |
| A04 | P07–P11 | First commit lands on main; established main requires explicit destination choice; work branch keeps its name; other protected default branches require a work branch. |
| A05 | P08, P10 | Edit proposal and inspect full diff, then cancel: no commit/push/new shipping branch. Existing explicit setup/staging/remediation effects remain accurately reported. Return never publishes accidentally. |
| A06 | P12–P13 | Secrets in added/deleted/context lines, renamed sensitive paths, and PR subjects block the model. Missing/failed scanner also blocks it. The transmitted clean request is byte-identical to the scanned request. |
| A07 | P12–P13 | Ignore/untrack preserves local data and independent `.gitignore` changes. Secret-bearing deletion gets a local/manual message. Source editing preserves partial staging and requires reviewed restaging. |
| A08 | P08, P12 | Unsupported/invalid/failed model response offers manual entry without an automatic retry. Findings/unscanned status remains visible through manual approval. No raw diagnostics or matched secrets leak to activity/persistence. |
| A09 | P10–P11 | An index, HEAD, branch, remote identity, comparison, or relevant target change during review invalidates execution. A hook changing commit content/message/parent stops publication. |
| A10 | P11, P19 | Commit success + push failure retains one local commit and offers reviewed push-only recovery without a new model request/commit. Model uncertainty and transport uncertainty are distinguishable. |
| A11 | P14–P15 | Dirty PR/merge offers Ship first or Cancel; after shipping, use a fresh source snapshot and require cleanliness. Target selection lists main first. |
| A12 | P15, P17 | PR generation uses the scanned merge-base payload; publication uses the selected repository/head/base. Existing PR is reused and text stays unchanged unless edited. Create PR never merges. |
| A13 | P16 | Final merge review is distinct from commit/PR approval. Rejected, queued, or uncertain merge keeps branches. No administrator bypass. |
| A14 | P16, P19 | Confirmed squash merge updates/switches the target only after verifying the merge OID; source cleanup matches exact reviewed refs. Changed source, divergent target, new local edits, or another worktree stops affected cleanup. |
| A15 | P19–P20 | Simulated termination after local commit or ambiguous remote publication produces reconciliation on reopen, no replayed approval or duplicate mutation. |
| A16 | G01–G03 | Linear/merge/octopus/squash/shallow histories, tags, duplicate ref labels, unborn and detached HEAD render honestly. Paging maintains lane continuity. Squash association is never a fabricated ancestry edge. |
| A17 | G02–G03 | A→B contents and merge-base→B comparisons produce correct file changes; no-common/multiple-base cases are explicit. Filters do not fabricate direct ancestry. Path search remains cancellable. |
| A18 | G04–G08 | Create/switch/publish and drag-to-prepare use shared policy and reviewed identities. Selecting a row/ref does not change checkout. Dirty work and linked worktrees prevent unsafe switching. |
| A19 | G09–G10 | Fetch prunes only remote-tracking heads. Upstream-gone alone never authorizes local deletion. Local cleanup uses ancestry or exact verified PR evidence plus expected-ref deletion. |
| A20 | P01–P20 | All core actions are usable by keyboard/VoiceOver; high contrast, Show Borders, Reduce Transparency/Motion, long paths, light/dark, narrow/inactive windows remain legible. |

Test stale and duplicate decision tokens directly at the core API. Do not test only disabled UI buttons: a stale decision delivered to the engine must also be refused. Test mutation leases across an actual suspended decision and cancellation.

## Commands

Current CLI commands, from the repository root:

```sh
swift build
swift test
swift build -c release
```

Use `swift test --filter WorkflowTests` or the corresponding suite/case for focused runs. Avoid executing all suites repeatedly while editing one isolated behavior.

After M2 creates the project and shared scheme, use these GUI commands. They are planned commands, not evidence that a project currently exists:

```sh
xcodebuild -project Apps/ShipMac/ShipMac.xcodeproj -scheme ShipMac -configuration Debug -destination 'platform=macOS' -derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Apps/ShipMac/ShipMac.xcodeproj -scheme ShipMac -destination 'platform=macOS' -derivedDataPath .build/xcode -only-testing:ShipMacTests CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Apps/ShipMac/ShipMac.xcodeproj -scheme ShipMac -destination 'platform=macOS' -derivedDataPath .build/xcode -only-testing:ShipMacUITests CODE_SIGNING_ALLOWED=NO test
```

The UI test host may require local permissions/signing appropriate to the machine; report the concrete issue and adjust the local invocation without committing a developer identity. Do not claim UI tests passed if only unit tests ran. Use the existing cache-path workaround in [implementation notes](../implementation.md#development) if the environment cannot write user caches.

Add test schemes/configuration so fake executables and temporary worktrees can be supplied explicitly to the test app. Keep test injection separate from production defaults and ensure a normal launch never picks fixtures accidentally. A fake GitHub response does not replace real local Git ref verification.

## UI and performance checks

Use previews for layout states with immutable fixtures: empty/new repo, dirty worktree, partially staged file, scanner finding/failure, long proposal, graph selection, PR blocked, partial cleanup, and offline mode. Preview construction must not spawn subprocesses or network requests.

Keep focused XCUITests for opening a fixture, selecting/staging files, main versus branch review, remediation, final cancellation, push recovery, graph selection/compare, and PR/merge review boundaries. Core tests own the exhaustive Git state cases; do not duplicate the entire matrix through slow UI scripts.

Profile the 100,000-commit history fixture and a large per-file diff on the target Mac. Record cold and warm first-page time, scrolling/frame behavior, main-thread stalls, peak memory, and cancellation responsiveness. Verify bounded metadata/geometry caching and absence of eager historical diff loading. See [graph targets](git-graph.md#fixtures-and-performance-goals).

Manual visual QA: light/dark, increased contrast, Show Borders, Reduce Transparency, Reduce Motion, inactive windows, sidebar/inspector collapse, long/non-ASCII paths, and multi-display scale. Check that glass does not impair code or findings and that red/green is not the sole indicator of additions/deletions or graph state.

## Release readiness

- [ ] CLI regression suites and release build pass after the final core changes.
- [ ] GUI build and focused UI/presentation suites pass, with actual commands/results recorded.
- [ ] P01–P20 and G01–G10 have acceptance evidence, including failure/cancellation paths.
- [ ] Finder-launched app discovers dependencies without shell initialization; unavailable tools/authentication have actionable recovery.
- [ ] No repository content, raw model output, secrets, or credentials are persisted in metadata/activity.
- [ ] Multiple windows/worktrees and external Git edits invalidate stale review correctly.
- [ ] Performance and accessibility checks are recorded with known limitations.
- [ ] User documentation matches actual installed behavior and distinguishes CLI/app minimum OS.
- [ ] Archive and signing/notarization status are recorded honestly. A local unsigned build is not labeled a notarized release.

Signing credentials or publication authorization may remain an external release blocker while local implementation is complete. Record that distinction; do not invent release evidence or omit unfinished functional work.
