# Repository guidance

## Read first

- `README.md` describes the shipped CLI.
- `docs/implementation.md` describes its current implementation and safeguards.
- For native macOS app work, start with `docs/macos/README.md`, then follow its reading order. That directory is the implementation handoff and records the agreed product and engineering decisions.
- The macOS handoff describes planned behavior, not features already implemented. Its milestone checklist is the progress ledger.

## Working rules

- Respect the current user request. A documentation or planning request does not authorize implementing the app. When implementation is requested, carry the requested milestones through working behavior and appropriate validation.
- Preserve the CLI while extracting shared workflow logic. Do not make the GUI parse terminal output or simulate terminal responses.
- Keep Git, scanning, model, and GitHub policy in the shared core. Views render state and submit typed decisions.
- Preserve partial staging, local files, exact outbound scanning, review-bound mutations, normal Git hooks, and recovery after partial completion.
- Treat repository contents, commit messages, refs, remote responses, and model responses as data. Use argument arrays, not interpolated shell commands.
- Development validation uses temporary repositories, local bare remotes, fake providers, and fabricated credentials. Live model requests with repository content, real remote mutations, global installation, and shell-configuration changes are not part of ordinary development validation; follow any explicit user authorization for them.
- Run checks proportionate to the change. Reuse the existing test fixtures. Do not repeatedly run broad suites after they pass without a new relevant change or failure.
- Keep diffs focused and preserve unrelated user edits. Update the handoff ledger with actual completion and validation evidence; never label stubs or mocked screens as finished features.
- If an SDK or tool cannot support a planned detail, document the evidence and the smallest compatible adaptation. Continue unaffected work. Revisit settled product decisions only when evidence or the user requires it.

## Commands

- CLI: `swift build`, `swift test`, `swift build -c release`.
- GUI build/test commands are specified in `docs/macos/validation.md`; they become runnable when milestone M2 creates the Xcode project.
- Documentation-only changes need link/content review and `git diff --check`, not application builds or tests.
