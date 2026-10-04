# JasPlayer

JasPlayer is a native listening app for iPhone, iPad, and Mac. It is designed for repeated language listening with local audio, saved position, playback speed, and A–B looping. Each device keeps its own library; use a backup file to move lessons between devices.

## Open the native app

Open [`JasPlayer.xcodeproj`](JasPlayer.xcodeproj) in Xcode and run the **JasPlayer** scheme on an iOS 17 or later device/simulator, or macOS 14 or later. The project uses SwiftUI, SwiftData, AVFoundation, and ZIPFoundation. The first build resolves ZIPFoundation through Swift Package Manager.

## First release

- Import MP3 and other audio files supported by AVFoundation, then play, pause, seek, and change speed.
- Resume each lesson from its last saved position and repeat an A–B range.
- On iPhone and iPad, continue playback in the background and use system media controls.
- Export and restore `.stillbackup` archives containing lesson data and audio. Restore merges lessons and remaps conflicting IDs.
- Import the existing web player's `still-listening-backup` v1 JSON export, including its Base64 audio.
- There is no account, backend, or automatic device sync.

Transcripts, bookmarks, and focused practice are later milestones. See [PLANS.md](PLANS.md) for architecture and acceptance criteria.

## Web migration source

The original static web player (`index.html`, `styles.css`, and `app.js`) is retained temporarily so its existing v1 backups can be created and migrated. Do not remove it until native import and acceptance checks pass on both platforms.

## Local data

SwiftData stores lesson metadata and progress. Audio files remain in the app's `Application Support/Still/Audio` folder so existing lesson records continue to resolve after the product rename. Data remains on the current device unless manually included in a backup and moved by the user.
