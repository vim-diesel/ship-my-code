# Ship for Mac implementation handoff

Status: **approved design direction; application implementation has not started**.

Prepared: 2026-10-31. Toolchain baseline updated: 2026-11-01. Baseline source commit: `a1a72bec82292235e8cdd1f24408c7f51ac6a2a0`. The checkout was on `feat/frontend` when this handoff was prepared. This is historical context, not an instruction to reset or switch branches.

## Objective

Build a native macOS 27 SwiftUI application named **Ship** around the existing `ship` CLI's workflow. Users must be able to inspect changes, fix common secret findings, review generated or manual proposals, commit and push, create PRs, squash merge, and safely clean up branches. An interactive Git history graph must make it clear where local work lives and what has reached the remote.

The app and CLI share one workflow engine. The app is complete only when the core workflows work against real local Git repositories; a visual mockup is not the deliverable.

## Reading order

1. [Current CLI behavior](../../README.md) and [implementation notes](../implementation.md).
2. [Product and workflow specification](product.md): scope, screens, choices, cancellation, and recovery.
3. [Architecture](architecture.md): target layout, typed workflow contracts, execution, persistence, and invariants.
4. [Git graph](git-graph.md): data, rendering, interactions, comparison semantics, and branch cleanup.
5. [Apple platform and design](platform.md): macOS 27 APIs, Liquid Glass, dependencies, accessibility, and distribution.
6. [Implementation sequence](implementation-plan.md): milestone boundaries and progress ledger.
7. [Validation](validation.md): acceptance scenarios, commands, performance, and release checks.

## Settled decisions

| Decision | Required direction |
| --- | --- |
| Product name | Ship; CLI remains `ship`. |
| GUI platform | Native SwiftUI, minimum macOS 27.0; initial release targets Apple silicon. |
| Toolchain baseline | Xcode 27.2 (27B52), Swift 6.4.2, and macOS 27.2 SDK, verified locally on 2026-11-01. Build against this SDK while retaining the GUI's macOS 27.0 minimum; guard any 27.2-only API and provide an equivalent 27.0 fallback. |
| CLI compatibility | Preserve macOS 13 runtime support. Do not raise the package deployment target just to add the app. |
| Code sharing | Expose `ShipCore` as a library; CLI and app use typed core operations. |
| Git backend | Existing Git subprocess approach, extended for history and graph actions. No libgit2 migration. |
| Model provider | Existing Command Code adapter/login/model; manual fallback is first-class. |
| Secret checks | Existing path checks and Gitleaks, on the exact immutable outbound request. |
| GitHub integration | Existing `gh` integration, with explicit repository/source/target identity. |
| Primary actions | Review & Ship; Create Pull Request; Merge & Clean Up. |
| History | Interactive commit DAG, virtualized rows and SwiftUI Canvas edges. |
| Persistence | Small versioned local JSON metadata plus preferences; Git remains authoritative. No database framework required for v1. |
| Networking | No background fetch by default. Explicit Fetch; PR/merge preparation fetches as an explained part of that action. |
| Distribution | Direct Developer ID distribution with hardened runtime and notarization; initial app is not App Sandbox-enabled. |
| Dependencies | No new third-party Swift/UI dependency required. Discover existing command-line tools; do not silently install them. |
| Visual design | Native Liquid Glass navigation and controls; readable opaque/semantic content surfaces for source and dense history. |
| Milestones | Execute M1–M6 in dependency order. Use completion criteria, not a human-week estimate. |

## Scope boundary

V1 includes every existing CLI capability, graphical file staging and diffs, graph browsing/comparison, branch creation/switching, reviewed stale-branch cleanup, PR status, multiple repository windows, and dependency/settings UI.

Deferred: hunk staging, clone UI, worktree creation/removal, arbitrary local merges, cherry-pick/rebase, stash/reset/force-push, built-in conflict resolution, alternate model providers, menu-bar companion, Shortcuts/App Intents, and automatic updating. Detect existing worktrees and conflicting Git operations in v1. Do not implement deferred features as substitutes for the required workflows.

Keep the application folder-based. New SwiftUI document serialization APIs do not fit managing an existing Git repository and are not a requirement.

## Current foundation

The package already has `ShipCore` and the executable, but only the executable is exported as a product. `Workflow`, `RepositorySetup`, and `PullRequestFlow` mix domain logic with `Console` prompts. `ProcessRunner` runs synchronously and uses process-global interruption. These are the main extraction seams.

Reuse `Git.swift`, `Privacy.swift`, `Model.swift`, `Remediation.swift`, and the existing integration fixtures. Preserve the safeguards in [architecture.md](architecture.md#invariants). The graph and native app are new work.

## Start prompt for a new implementation chat

> Implement Ship for Mac using `AGENTS.md` and `docs/macos/README.md` as the entry point. Read the linked specifications and inspect the current checkout before editing. Follow M1–M6 in `docs/macos/implementation-plan.md`, preserving CLI behavior and the documented privacy/Git invariants. Build working vertical slices, run proportionate validation, and update the milestone ledger with evidence and the exact next step. Use the settled decisions without asking me to redesign routine details. Do not substitute a mockup for working repository operations. Report concrete blockers while continuing independent work. Do not perform real remote mutations, send repository content to a live model, install tools globally, or publish a release merely to validate development work.

This prompt is for a future implementation request. Creating this handoff has not implemented any milestone.

## Continuation protocol

Before a new implementation session: inspect `git status`, read the ledger, and inspect the claimed implementation. Do not assume the baseline commit is still current or overwrite existing work.

At each milestone: record the date, completed requirements, focused checks and outcomes, remaining gaps, changed architectural decisions if any, and the next executable step. Keep product requirements stable and use the ledger for progress. Never save raw model payloads, scanner secrets, or authentication output in this documentation.
