# Interactive Git graph specification

## Scope and meaning

History is a directed acyclic graph of commits and parent relationships. Branches and tags are labels pointing at objects; a visual lane is not permanent branch ownership. A squash merge is a new commit and must never be drawn as a parent edge from the old feature tip.

V1 shows committed history plus a clearly synthetic Working changes row. Index/working changes do not have commit OIDs. Remote labels represent local remote-tracking state and display its freshness. PR relationships are annotations, visually distinct from ancestry.

## Data model

| Record | Minimum fields |
| --- | --- |
| Commit | Full OID, ordered parent OIDs, subject, author display name, author/committer dates. Load body/files/diffs on demand. |
| Ref | Full ref name, display name, kind, target/peeled commit OID, remote/upstream relationship where known. |
| HEAD | Symbolic local ref or detached OID; unborn state handled separately. |
| Graph page | Revision, stable ordering, rows, parent stubs, lane continuation state, boundary/cursor information. |
| Worktree | Canonical path, branch/HEAD, locked/prunable flags when available, current-worktree identity. |
| PR association | Repository identity, PR number/URL, reviewed source/target refs and OIDs, state, reported squash/merge OID. |
| Working row | Staged/unstaged/untracked counts, selected worktree identity, refresh revision. |

Keep object IDs opaque; do not assume a fixed 40-character width or use abbreviated hashes as identity. Abbreviate only for display.

## Git reads

- Enumerate refs through machine-readable `for-each-ref` fields, including peeled annotated tags. Do not parse colored branch lists or human decorations.
- Load a topological history walk rooted at a captured ref set plus explicit HEAD. Detached HEAD must remain visible even if no named ref reaches it. Empty repositories display the working row and setup guidance.
- Use well-defined record framing for metadata and NUL-delimited Git path output. Parse fixed metadata separately from free-form commit content; if using `cat-file --batch`, honor object byte lengths. Subjects/paths may contain whitespace or control characters.
- Resolve chosen user-visible refs to validated full refs/OIDs before operations. Put paths after `--` and use literal pathspec handling. Do not allow a search string or branch label to become an option or revision expression.
- Suppress external diff/textconv execution for inspection, consistent with current core behavior. Show symlink and submodule changes honestly; do not recursively browse or mutate submodule repositories automatically.
- Identify shallow boundaries and missing parents; render continuation/boundary markers rather than inventing ancestry or treating missing history as a root.
- A stable paging implementation can maintain a bounded streaming revision walk and parent-lane state. Avoid offset-only paging over moving refs. If the captured ref revision changes, invalidate/restart the walk while preserving the selected OID if still reachable.

## Layout and rendering

Order newest-to-oldest subject to topological constraints. Default to a 500-row first page and request another page near the viewport boundary. Keep graph edges in SwiftUI Canvas and selectable/accessibility-aware rows in a virtualized container with synchronized row geometry. Do not create one independent heavyweight SwiftUI path tree for every commit in the repository.

Allocate deterministic lanes using parent relationships. Carry lane state across page boundaries, reuse lanes only when their pending ancestry closes, and keep stable colors within a graph revision. Use rounded connectors, legible nodes, and a clear selected-row treatment. Minimize motion while loading; preserve scroll anchor on refresh. Horizontal scrolling accommodates wide graphs without shrinking text.

Use labels and node styles as well as color. HEAD has a textual badge. Local/remote refs at the same commit remain distinguishable. Remote-only tips, local-only commits, and ahead/behind values must not imply stronger freshness than available.

Compute lane layout off the main actor. Cache metadata and visible geometry with bounds. Load only the selected commit's file list and selected file's diff. Cancel superseded searches/diff reads. Large selections must not block window interaction or cancellation.

Canvas is decorative topology; rows provide keyboard selection, context menus, VoiceOver labels, and parent/child navigation. Every drag action must have a menu/keyboard equivalent.

## Selection and comparisons

**G01 — Commit selection:** show full message on demand, copyable SHA, author/date, ordered parents, refs, changed files, and local diff. For a merge commit, default to the first-parent diff and expose parent selection. Root commits compare with the empty tree.

**G02 — Two selections:** let the user explicitly choose A and B and show labels and direction. Offer:

- Compare contents: tree A → tree B (`git diff A B` semantics).
- Changes on B since shared ancestor: merge-base(A, B) → B, matching PR review semantics.

Do not conflate either diff with the symmetric commit set of `git log A...B`. If there is no common ancestor, offer content comparison but disable the PR-style comparison. If multiple merge bases make the PR-style meaning ambiguous, explain it and decline the simplified preview rather than silently choosing one.

**G03 — Search/filter:** search SHA, subject, author, branch, and changed path. Path search is a cancellable on-demand Git query; it must not preload every diff. Show result counts only when known. Default filters highlight matches in contextual history. If hiding rows, show an explicit collapsed-history connector, not a direct parent edge that never existed. Keep source/target selection visible when filtered out.

## Reviewed actions

| ID | Action | Required behavior |
| --- | --- | --- |
| G04 | Create branch from selected commit | Preview resolved start OID and validated name. Checkout toggle defaults off. Create only the reviewed ref; reject collisions including locally known remote names. |
| G05 | Switch branch | Explicit action, never selection/double-click side effect. V1 requires a clean index/worktree, no unfinished operation, and no conflicting linked worktree. Offer Ship changes first or handle externally when dirty. Remote branch checkout previews local tracking branch creation. |
| G06 | Publish branch | Use shared push-only review and branch policy; show actual outgoing comparison/freshness. |
| G07 | Prepare PR / Merge & Clean Up | Route through shared workflow for the checked-out supported work branch. If selecting another branch, offer a reviewed switch first; no hidden checkout. |
| G08 | Drag source ref onto target | Open an action chooser populated with source → target, then PR/merge preparation. Dropping itself mutates nothing; revalidate identity on use. Reject self-drop, unsupported refs, and unsupported repository relationships. |
| G09 | Fetch | Explicit selected-remote fetch/prune of remote-tracking heads; refresh graph. Never remove local branches as part of fetch. |
| G10 | Review stale branches | Show upstream-gone state after successful fetch, preservation evidence, current OID, checked-out worktrees, and per-branch cleanup eligibility. |

Graph actions must call the same core validation and mutation boundary as normal workflows. They are not an alternate path around approval/scanning/branch policy.

## Conservative stale-branch cleanup

Never equate upstream-gone with merged. Candidates require a user-selected local preservation target and fresh ref state. Protected branches, the current branch, branches checked out in any worktree, ambiguous/missing history, and branches that changed after review are ineligible.

For v1, allow deleting an eligible local source only with one of:

1. **Ancestry proof:** its current reviewed tip is reachable from the selected preserved local target tip.
2. **Verified squash/PR proof:** a confirmed same-repository merged PR identifies the source tip exactly; the current local source still equals that reviewed tip; the reported merge commit is present in the fetched target and safely updated preserved local target. Prefer an existing verified Ship merge receipt plus fresh verification. If GitHub cannot establish the association/OIDs, do not infer from names or similar patches.

Show which evidence applies and exactly which local ref will be removed. A generic PR with the same branch name, patch similarity, or a remote branch deletion is insufficient. With insufficient evidence, leave the branch and offer comparison/Open in Terminal; v1 has no force-delete override in this cleanup UI.

After approval, reacquire fresh state and worktree information and compare-and-delete the expected local ref. Abort that candidate if the source or preservation target changed. Remote deletion belongs to the already reviewed Merge & Clean Up flow, uses an expected-SHA lease, and is not a generic delete-remote action in this screen. Missing remote refs can be reported as already gone without weakening local preservation checks.

Bulk cleanup may show a reviewed list, but each candidate must independently satisfy the same proof and stale-state checks. No automatic cleanup on app launch, fetch, window close, or PR list refresh.

## Fixtures and performance goals

Use deterministic fixtures for linear history, parallel branches, two-parent and octopus merges, squash merges, reordered commit dates, multiple refs at a commit, annotated tags, detached HEAD, unborn/shallow repositories, deleted upstreams, and linked worktrees.

Profile a 100,000-commit synthetic local repository and a large text diff. Provisional targets on the development Mac: first 500 cached metadata rows/layout within 1 second, interactive scrolling near display refresh rate, no perceptible main-thread work bursts over 100 ms from Git parsing/layout, and memory that does not grow with all historical diff contents. Record hardware, cold/warm conditions, measurements, and any justified target adjustment. These are acceptance targets, not claims that the existing code achieves them.
