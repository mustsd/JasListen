# Project guidance

## Start here

- Read [PLANS.md](PLANS.md) before product or implementation changes. It defines the native app scope, milestones, and acceptance checks.
- The active implementation is the SwiftUI multiplatform project in `JasPlayer.xcodeproj`, targeting iOS/iPadOS 17 and macOS 14 or later.
- The root-level `index.html`, `styles.css`, and `app.js` are the legacy web migration source. Keep them available until native acceptance and web-backup migration are complete.

## Architecture

- Keep SwiftUI presentation separate from playback, persistence, import, and backup services.
- Use SwiftData for lesson metadata and progress; store audio in app-managed files and keep relative paths in the model.
- Route in-app, headset, and lock-screen transport through `AudioPlaybackController`.
- Keep the app local-first. Do not add a backend, account, or automatic synchronization unless product scope changes.
- Backups must contain audio and lesson data. Restore merges data and remaps ID collisions without overwriting existing lessons.

## Product boundaries

- The first release includes audio import, playback, seeking, speed, saved position, A–B looping, native backup/restore, and import of web backup v1.
- Transcripts, bookmarks, and focused practice are later milestones. Do not present them as current features.
- Do not retire the legacy web app before the migration and native platform acceptance conditions in `PLANS.md` are met.

## Implementation and handoff

- Keep changes focused on the requested milestone and update `PLANS.md` when scope or established behavior changes.
- Use the Xcode project and shared scheme for native builds and tests when the installed Xcode toolchain is available.
- Do not claim a build or test passed unless it was run successfully. In handoff, state what changed, what was verified, and any unresolved platform/toolchain limitation.
