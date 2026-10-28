# Macbar: from experiment to a usable desktop utility

Assessment date: 28 October 2026.

## Verdict

Macbar has enough features for an initial product. Its main gap is dependable operation across the complete user journey: download, first launch, permissions, daily switching, reboot, changing displays, updates, and recovery.

The next milestone should be a small, supported private beta. Position it as a Windows-style app and window taskbar for macOS. Its strongest differentiator is separate window tiles, including minimized windows. Make that workflow dependable before expanding the system tray or adding other desktop features.

The scope should explicitly say which displays and macOS versions are supported, how the system Dock coexists with Macbar, and what happens with native fullscreen and other Spaces. Do not promise that the current implementation reserves desktop space.

## Evidence and limits

- Reviewed all application services, models and views, the test sources, project configuration, installation script and README.
- Ran the current Xcode test suite: **50 passed, 0 failed, 0 skipped**, on Apple silicon with macOS 26.5.2. Result bundle: `build/Logs/Test/Test-Macbar-2026.10.28_00-44-08-+0200.xcresult`.
- Inspected the running installed app, launcher and accessibility tree. Search acquired focus and Escape closed the launcher. With `cal` entered, Calculator and Calendar appeared; pressing Down left focus in the search field and showed no selected result.
- The installed application is an arm64 development-signed build with hardened runtime. This does not demonstrate a distributable, notarized release or Intel support.
- The checkout did not report as a Git working tree. No CI, release packaging or updater configuration was present in the inspected project. These observations do not establish whether infrastructure exists elsewhere.
- Did not revoke permissions, change user preferences, join networks, resize user windows, reboot, test other displays, or install an update. Those journeys remain unverified.

Useful foundations already exist: native UI; optional, user-triggered capture permission; previews cleared on dismissal; no analytics or remote-upload code found in the reviewed sources; background window enumeration and fitting; explicit capture error states; persistence of pins and settings; and meaningful tests for geometry, cancellation, minimized windows and audio failures. Preserve these.

## Prioritized implementation backlog

### 1. Distribution and repeatable releases

**Before external beta.** The current install path assumes Xcode and a specific development identity. `scripts/run.sh` builds Debug, verifies that identity and copies the result into `/Applications`. That is a developer workflow.

Implement:

- Separate development and release signing configuration; Developer ID Application signing for direct distribution, hardened runtime, notarization and stapling.
- A reproducible Release archive and DMG with an Applications shortcut. Include versioned artifacts, release notes and an explicitly declared CPU/OS support policy. Verify universal output if claiming Intel and Apple silicon support; otherwise label the initial beta Apple silicon only.
- Test launching the actual downloaded, quarantined artifact on a clean supported Mac or user account without development credentials. Verify launch offline after stapling as well.
- Load the displayed version/build from bundle metadata; settings currently hard-codes `0.1` separately from the plist version.
- Establish source control if it is genuinely missing here; add automated build/test checks and a deliberate release process. Keep signing secrets out of source control.

**Acceptance:** another person downloads and installs Macbar with no Xcode, terminal instructions, development certificate or security-warning bypass. A release can be reproduced from an identified source revision.

Apple documents the direct distribution and notarization process in [Notarizing macOS software](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) and [Packaging Mac software](https://developer.apple.com/documentation/xcode/packaging-mac-software-for-distribution).

### 2. First-run setup and permission recovery

**Before external beta.** The app currently starts the bar immediately. Explanations are scattered between settings, Wi-Fi and a hover panel. Window fitting defaults on, but a new user has not been guided through the implications.

Implement a short, resumable setup:

1. Show what Macbar does; let the user choose app icons or window titles.
2. Explain Accessibility for window titles/focusing, and separately offer automatic window adjustment. Granting access for titles must not silently opt someone into unrelated behavior.
3. Explain Dock coexistence, link to system settings, and offer launch at login.
4. Show a small practical completion step: pin an app, switch a window, and locate Hide/Quit.

Screen Recording and Location should remain optional and requested when their features are used. Include a persistent permissions page showing actual capability status, what each permission enables, and how to recover from denial/revocation. Support continuing with app launching when permissions are absent. If a restart is required, offer a clear safe relaunch path and recheck afterward.

**Acceptance:** an unfamiliar user completes setup unaided; denying all permissions still leaves a useful launcher; granting or revoking access updates visible feature state; setup is not repeated after every update.

### 3. Window switching is the primary product

**Before external beta.** There are separate implementations for app activation, AX window tiles and screenshot-preview activation. The tile route keeps an AX element; preview activation instead matches by geometry/title and falls back to the first matching title. Duplicate titles can make that fallback ambiguous. AX activation calls discard errors.

Implement a common window activation service with explicit outcomes: focused, target disappeared, permission missing, app unresponsive, or unsupported. Preserve process/window identity where available, revalidate before acting and avoid silently treating an ambiguous title match as success. If precise selection cannot be supported, fall back to clearly described app activation.

Define and test click behavior for:

- A closed app; a running app with no open windows; hidden apps; minimized windows; a currently active window; multiple windows; windows closed between enumeration and click; duplicate titles; multiple instances of the same app.
- Windows in another Space or on another display. Do not claim reliable cross-Space behavior until tested with public APIs.
- Running apps with no windows: the current path calls `activate`, with no explicit reopen request. Validate representative apps and add reopen behavior where needed.

Offer a textual window list in grouped mode using Accessibility, without requiring Screen Recording. In the current grouped mode, specific-window browsing is tied to a hover screenshot panel. Provide a click/context-menu and keyboard route, including minimized windows.

The AX tile provider enumerates an app's windows without an explicit Space/display filter. Preview enumeration requests on-screen windows. Establish a consistent default scope and describe the difference if the APIs cannot support identical filtering. Do not invent desktop membership from unavailable data.

**Acceptance:** choosing a listed window reliably restores/focuses that window in the supported test matrix, or gives an understandable fallback. Duplicate names never silently select the wrong window as if selection succeeded.

### 4. Dock coexistence, overlap and reversible window adjustment

**Before external beta, with continued compatibility work.** This is the largest architectural constraint. The current bar is a floating status-level panel. It does not reserve the system work area. Fitting only considers a focused, standard, eligible maximized window. Smaller overlapping windows deliberately remain unchanged. Hiding the bar, disabling fitting or quitting does not restore previous sizes; disabling also discards the stored adjustments.

Choose and expose a clear policy:

- Keep the current visible-bar option, with an honest explanation of overlap.
- Add auto-hide and reliable reveal as an escape from overlap. Start with one understandable mode; intelligent overlap detection can follow.
- Keep fitting optional. Add per-app exclusions, a pause action and conservative restoration of windows Macbar adjusted during the current session.
- Restore only when the window still matches Macbar's last applied frame and the display/work-area context is valid. Never overwrite a subsequent manual resize. Handle normal quit, disabling fitting, hiding the bar and display changes deliberately. Do not promise restoration after a crash.
- Revalidate pending work before resizing after preferences or permissions change.
- Preserve the existing exclusions for dialogs, fullscreen, tiled and manually resized windows.

**Acceptance:** users can reach controls behind the bar, pause adjustment immediately, and leave Macbar without unexplained persistent layout changes during supported normal shutdown paths. Native fullscreen and other window managers do not trigger repeated resize fights.

### 5. Display and desktop lifecycle

**Minimum before beta:** selected-display support with a fallback. **Before broader public release:** validate the common multi-display configurations; a bar on every display is optional.

`TaskbarController.screen` and fitting both use `NSScreen.screens.first`. Notifications reposition the bar, but there is no display preference or per-display coordinator.

Implement a `DisplayCoordinator` that resolves a stored display selection, falls back when unplugged, and supplies the same display context to the bar, flyouts, previews and fitting. If adding bars on several displays later, share application/permission state and keep panel/hover state separate per display.

Handle monitor unplug/replug, clamshell transitions, primary-display changes, resolution/scaling changes, sleep/wake, screen lock/unlock, Spaces and fullscreen transitions. Dismiss or reposition open flyouts and previews coherently.

**Acceptance:** the bar remains discoverable after every supported transition; it never stays offscreen or fits windows against a different monitor's geometry. Publish clear limitations for Stage Manager and fullscreen until verified.

### 6. Daily-use controls

**Before external beta:** launch at login, launcher keyboard selection, pin reordering and a recovery route.

- Add a launch-at-login control using `SMAppService.mainApp`; show actual service status and approval/errors rather than persisting only an optimistic Boolean. See [Apple's main app service documentation](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp).
- Add configurable global shortcuts for search and Show/Hide. Avoid requiring users to find a small menu bar icon when the bar is hidden. Do not depend solely on menu bar shortcuts.
- Model selected search result explicitly. Up/Down changes selection, Return launches it, Escape dismisses, and the selected row scrolls into view. Current Return always chooses `results.first`.
- Allow pin order changes by dragging and provide an accessible alternative. Pinning currently only appends; reordering requires unpinning and repinning. Handle removed/moved applications and stale pins visibly.
- Preserve a stable running-app order. If keeping recent apps, persist only app identifiers and offer Clear; cross-session recents are useful but lower priority than reliable switching.

**Before public release:** keyboard access to window lists and all flyouts, VoiceOver validation, full keyboard access, increased contrast, Reduce Motion and Reduce Transparency. Labels already exist, but the main bar and preview panel intentionally cannot become key, and previews are hover-triggered. Adding labels alone does not prove operability.

**Acceptance:** the main launcher/window-switching path works without a mouse; pin order survives restart; the user can find and disable login launch and recover the bar without support.

### 7. Bound asynchronous work and measure background cost

**Before broader beta.** Off-main-thread work is a good foundation, but does not by itself guarantee freshness or battery efficiency.

Specific code risks:

- Catalog scans start at launch and on every launcher opening. Detached scans have no generation/cancellation control; old scans can publish after newer scans. Icon lookup for the whole catalog occurs on the main actor.
- Window tiles poll every second. The provider uses a serial queue and multiple AX reads per app/window. Per-call timeouts do not impose a deadline on a full refresh. Cancelling the Swift task discards results but does not stop the provider's loop.
- A failed AX enumeration preserves prior tiles without an age limit. That avoids flicker, but can leave stale windows indefinitely.
- Audio and fitting poll every second; the bar clock also updates every second although it shows only minutes. Work continues while the bar is hidden in several services.
- Wi-Fi begins with optimistic powered/available values and refreshes on panel opening, permission change and user refresh. It does not subscribe to network/power changes, so the tray can be stale.

Implement latest-request control for catalog work, cached/coalesced catalog updates, cancellation checks between AX operations, bounded refresh work, stale-state expiry and retry/backoff. Prefer available system notifications with a modest reconciliation timer. Pause unnecessary work while hidden/asleep. Refresh Wi-Fi state through CoreWLAN events without continuously scanning.

Measure release-build idle CPU, wakeups, memory and UI latency with few/many apps, many windows, an unresponsive app, repeated preview opening and an extended idle session. Set budgets from those measurements; there is no measured performance regression established by this audit.

**Acceptance:** one slow app does not delay updates for every other app indefinitely; rapid mode changes do not accumulate obsolete work; memory does not grow continually during repeated use; idle behavior meets a documented battery-conscious budget.

### 8. Updates, support and diagnostics

**Before public release; a documented manual update process can serve a small private beta.**

- Integrate a maintained signed updater such as Sparkle 2, with Check for Updates, release notes, deferred installation and failure handling. Test the signed release-to-release path, pin/settings migration and permissions after replacement. [Sparkle documents signed update verification](https://github.com/sparkle-project/Sparkle).
- Add structured local logging for permission state, capture/enumeration failures, activation outcomes and display transitions. Avoid logging window titles, passwords, network names or screenshot contents by default.
- Add About, Help, Report a Problem and a user-reviewable diagnostic export containing app/build, OS, architecture, display layout, capability status and sanitized recent errors. Manual bug reporting is sufficient initially; cloud telemetry is not a prerequisite.
- Provide a short privacy explanation, known limitations, support destination and instructions for disabling login launch/removing the app.

**Acceptance:** a beta user can report a problem with enough sanitized context to investigate; a signed update preserves preferences and has a tested recovery path. Do not add an updater that requires reconstructing trusted signing identity later.

## Architecture changes that are justified

Keep SwiftUI/AppKit and the existing service boundaries. A rewrite or backend is unnecessary.

Introduce small owners around the missing responsibilities:

| Component | Responsibility |
| --- | --- |
| `PermissionStore` | Capability state, rechecks and recovery actions |
| `OnboardingCoordinator` | Resumable setup and explicit user choices |
| `LoginItemStore` | Actual service status and registration failures |
| `DisplayCoordinator` | Display selection, lifecycle and shared geometry |
| `WindowActivationService` | One activation policy and observable outcomes |
| `AppCatalogService` | Cached discovery, latest-request control and icon loading |
| `UpdateController` / `DiagnosticsStore` | Release updates and support evidence |

Keep window fitting separate from general window access. Enabling window titles should not enable resizing as an accidental side effect.

## Validation required beyond the existing 50 tests

Use disposable user accounts or test machines rather than resetting the developer's permissions. Add focused integration/UI coverage and a manual hardware matrix where automation cannot establish behavior.

| Journey | Required evidence |
| --- | --- |
| First install | Downloaded release opens on a clean supported account; setup can be completed unaided |
| Permissions | Fresh, denied, granted and revoked; returning from settings; relaunch when needed |
| Window switching | Finder, Safari, a Chromium browser, a native document app and an Electron app; duplicate titles, minimized/hidden/closed windows and unresponsive app |
| Desktop lifecycle | Sleep/wake, reboot/login, monitor changes, Spaces, fullscreen and Stage Manager |
| Layout | Small supported screen, scaled display, long titles, many windows, light/dark and accessibility display settings |
| Persistence | Pins/order/settings/login preference across restart and release update |
| Distribution | Declared minimum/current macOS and every advertised architecture; actual DMG and update artifacts |
| Long session | Normal workday, repeated previews, idle CPU/wakeups and memory trend |
| Exit/recovery | Hide, pause, normal quit, crash/relaunch and removal of login launch |

Tests using simulated providers remain valuable. They cannot establish real TCC permission behavior, cross-app activation, desktop visibility or Gatekeeper acceptance.

## Suggested delivery order

1. **Establish the release lane:** source revision, Release artifact, signing/notarization, minimum support policy, clean installation and basic diagnostics. This allows all subsequent usability tests to use the actual delivery method.
2. **Make first use and escape reliable:** onboarding, permission state, login launch, Hide shortcut and an explicit overlap/fitting policy.
3. **Make the central workflow reliable:** unified activation, text window list, minimized/no-window cases, search selection, pin reordering and selected-display recovery.
4. **Run a small private beta:** approximately 5–10 people, including unfamiliar users and external-monitor users, using it through normal workdays. Observe setup; collect concrete failures and reasons they return to the Dock. Treat the group size as a practical suggestion, not statistical proof.
5. **Prepare broader release:** resolve beta failures; implement signed updates; complete accessibility, OS/hardware matrix, performance measurements and support material.

A useful private-beta gate is that unfamiliar users can install and set up without the developer, complete their daily app/window switching, recover the bar after reboot/display changes and explain how to disable it. A public-release gate adds tested upgrades and adequate coverage for every advertised configuration.

## Explicitly defer

Accounts, cloud sync, subscriptions, plugin systems, calendar integration, weather/news widgets, extra theme packs and a custom Wi-Fi manager beyond the current supported scope. They do not resolve the present adoption blockers. Battery/network status improvements can follow evidence from users; expanding the tray is secondary to trusted window switching.

The highest-value next work is distribution plus setup, then window behavior and recovery. More visible features should follow evidence that people can already depend on the taskbar they have.
