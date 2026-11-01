# Apple platform, visual design, and distribution

## Verified baseline

Updated verification on 2026-11-01: the local tools report **Xcode 27.2 (27B52), Swift 6.4.2, and the macOS 27.2 SDK**. This supersedes the original Xcode 27.1 / macOS 27.0 SDK planning baseline. Public SwiftUI declarations for navigation tabs, reorderable content, toolbar priorities, and toolbar overflow were rechecked in the updated SDK. Treat this as dated verification, not a claim about the latest version at a future implementation date.

Build with the macOS 27.2 SDK while keeping the GUI deployment target at macOS 27.0+, initially arm64. An SDK update alone does not require raising the minimum supported OS. Adopt applicable 27.2-only APIs behind availability checks with equivalent 27.0 behavior, and validate both the minimum supported runtime and 27.2 when available. Keep shared core/CLI macOS 13 compatibility. New app targets use Swift 6 language mode and explicit main-actor presentation ownership. Verify SDK availability when implementing; do not copy an iOS-only API from an otherwise relevant WWDC session into the Mac target.

## Required native UI choices

| Capability | Application |
| --- | --- |
| `WindowGroup`, `NavigationSplitView`, `.inspector` | Native repository windows, sidebar, workspace, optional inspector, restoration. |
| `.pickerStyle(.tabs)` | Changes / History / Pull Requests navigation; distinguish navigation from value-selection pickers and expose tab accessibility semantics. Available on macOS 27. |
| Native `ToolbarItem` / customizable toolbar | Main repository controls; use `visibilityPriority` for important actions as space narrows. |
| `glassEffect`, `.glass`, `.glassProminent` | Custom graph controls and deliberate primary actions, with system treatment elsewhere. |
| `GlassEffectContainer`, `glassEffectID` | Group nearby custom glass controls and coordinate compact/expanded transitions. |
| Interactive glass | Use the macOS 27 interaction behavior for custom glass controls; avoid a separate simulated hover/refraction system. |
| `reorderable`, `reorderContainer` | Reorder pinned/recent projects; changing project order must not modify repository refs. |
| Expanded swipe-action containers | Non-destructive convenience actions on custom file rows, with full-swipe mutation disabled and ordinary buttons/menu equivalents. |
| `@Observable`, updated `@State`, `ContentBuilder` | Modern app state and reusable native view composition. Keep Git work out of view bodies and property initialization. |
| `Canvas` plus accessible rows | Git topology rendering, selection, keyboard navigation, and VoiceOver. |

References: [TabsPickerStyle](https://developer.apple.com/documentation/swiftui/tabspickerstyle), [toolbar visibility priority](https://developer.apple.com/documentation/swiftui/customizabletoolbarcontent/visibilitypriority(_:)), [SwiftUI updates](https://developer.apple.com/documentation/Updates/SwiftUI), [Glass](https://developer.apple.com/documentation/swiftui/glass), and [WWDC26 SwiftUI update](https://developer.apple.com/videos/play/wwdc2026/269/).

The installed SDK marked `toolbarOverflowMenu` unavailable on macOS. Do not use it or iOS-only pinned top-bar placements as Mac requirements. Use native Mac toolbar overflow behavior and an explicit secondary-actions menu. Recheck declaration availability if a later SDK changes this.

## Liquid Glass design rules

Use the system's sidebar/titlebar/toolbar appearance first. Custom glass belongs to floating graph controls, scope/navigation controls where appropriate, and the action surface. Use regular glass and a restrained accent tint for the primary action. Avoid nested independent glass layers and putting a glass effect on every row.

Diff text, code backgrounds, scan findings, and dense metadata use semantic content backgrounds with predictable contrast. Scroll-under-toolbar separation should use native scroll-edge behavior. Keep badges legible over arbitrary wallpaper, light/dark appearance, and active/inactive windows.

Use system fonts and SF Symbols. Code, SHAs, and aligned numeric counts use a monospaced face. A single app accent identifies interactive selection; branch colors identify lanes and are supplemented by shapes/labels. Errors and unscanned states must differ by text/icon as well as color. Avoid large decorative gradients, animated graph backgrounds, or continuously shimmering controls.

Use restrained native transitions for sheet progress and expanding controls; never animate every history row when new pages load. Honor Reduce Motion and preserve selection/scroll anchors during refresh.

Use an Asset Catalog and an original simple shipping/branching app icon. Icon Composer can be used for the final layered icon if available, with a static fallback asset. A final icon is polish, not a prerequisite for real repository workflows.

Apple documents the platform refinements and automatic adaptations in [Platforms State of the Union](https://developer.apple.com/videos/play/wwdc2026/102/) and [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).

## Accessibility and input

- Honor Reduce Transparency, increased contrast, Reduce Motion, and `accessibilityShowBorders`. macOS 27 has a dedicated Show Borders preference. Draw visible boundaries on custom controls when required. [Apple documentation](https://developer.apple.com/documentation/swiftui/environmentvalues/accessibilityshowborders)
- Every graph commit has an accessible row label containing subject, abbreviated SHA, branch/HEAD labels, and selection state. Offer parent/child navigation and full details without requiring Canvas hit-testing.
- Preserve standard selection/copy shortcuts in source, hashes, and messages. Make diffs navigable by file and hunk even though hunk staging is deferred.
- Keyboard: Cmd+O opens a folder, Cmd+, opens Settings, Cmd+F searches the active workspace, Cmd+R refreshes local state, and Escape dismisses/cancels. Use a separately labeled menu shortcut for network Fetch; Cmd+R must not silently fetch.
- Review & Ship may have Cmd+Shift+Return. Final commit/push, merge, and deletion have no plain-Return default action. Only explicitly focused controls or a documented modified shortcut can approve them.
- Provide native contextual menus, useful tooltips, focus indication, predictable tab order, and status text announcements for operation completion/recovery. Never require dragging or color perception to operate the app.
- Test larger accessibility text, long paths/messages, multiple displays, light/dark appearance, inactive windows, and narrow windows.

## Command-line dependencies

The Finder-launched app does not assume the user's shell setup has run. Implement a dependency resolver with this order:

1. Explicit user-configured absolute executable path.
2. Trusted absolute directories from the launch environment, excluding empty/relative entries and paths inside the active worktree.
3. Known user/system locations such as `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `/usr/bin`, and `/bin`, with the actual user home expanded by Foundation.

Report the selected path and capability checks. Do not source `.zshrc`, run a login shell, or automatically install Node, Command Code, GitHub CLI, Gitleaks, or developer tools. If a launcher depends on a runtime such as Node, verify that the resolved subprocess environment can start it; report the missing dependency rather than repeatedly invoking it.

Retain environment hardening for Git and Gitleaks. Preserve supported credential-helper and SSH-agent integration, but never dump environment variables or raw credentials into diagnostics. GitHub status checks must suppress authentication secrets. For Command Code, expose actual capability/authentication failures without inventing a status API or requiring a repository-content completion to check readiness.

Provide copyable installation/login commands and an Open Terminal action where possible. The app does not need an embedded terminal or a new OAuth implementation for v1. After the user completes external setup, Recheck refreshes capabilities without restarting the app. If GUI authentication cannot proceed noninteractively, stop with the relevant action rather than hanging on invisible stdin.

Configure editors as an executable/application plus arguments, with safe parsing for imported `VISUAL`/`EDITOR` settings. Use native opening for ordinary Open in Editor, with an explicit Recheck after the user edits. Preserve the existing review-before-restaging behavior. Do not infer editing completion from a GUI launcher's immediate exit.

## Local permissions and packaging

Use folder selection and ordinary macOS file permissions. Handle denied/revoked access and moved projects as recoverable errors. Do not request Full Disk Access as a prerequisite or silently initialize a missing/inaccessible path. The initial directly distributed application is not App Sandbox-enabled, so security-scoped bookmark handling must not be treated as a substitute for normal path/access validation.

Release packaging requires Developer ID signing, hardened runtime, notarization, and a stapled distribution artifact. Never commit signing identities, team credentials, certificates, or tokens. Development builds can disable code signing. Test the packaged app launched from Finder with the real subprocess environment; running only from Xcode is insufficient. [Apple notarization guidance](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

External tools remain installed prerequisites in v1; do not bundle/sign/update third-party executables in this milestone. Produce a local archive/build and release instructions when credentials are unavailable, and report signing/notarization as incomplete rather than claiming a distributable release. Uploading/notarizing/publishing a release requires the user's applicable authorization and credentials; finish all local preparation first.

## Deferred platform integrations

MenuBarExtra, Shortcuts/App Intents, Spotlight indexing of repository contents, Foundation Models or compatible cloud providers, automatic updates, and cross-device sync are deferred. The latest APIs should improve the required workflows; they are not a reason to add unrelated app behavior or send code to a new provider.
