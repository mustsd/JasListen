# JasListen — Native Listening App

## Goal and platform scope

Build a native listening-practice app for iPhone, iPad, and Mac. The first release focuses on importing audio, repeated listening, saved playback position, and manual backup transfer. There is no account, backend, or automatic device sync in the first release.

- Use one SwiftUI multiplatform Xcode target for iOS/iPadOS and macOS.
- Minimum deployment targets: iOS/iPadOS 17 and macOS 14.
- The existing static web player is a migration source only. Retire it after native import of its v1 backup and native acceptance on both platforms.

## Architecture

### UI and application layer

- Use adaptive SwiftUI views: a compact lesson list/player flow on iPhone and a library sidebar with player detail on Mac.
- Adding audio accepts one file, several files at once, or a folder that is searched recursively for audio. On Mac the same sources can also be dragged onto the library.
- On Mac, the space bar plays or pauses the loaded lesson and the left and right arrow keys move back and forward. Text fields, sheets, and open panels keep their own keys.
- Keep user-interface code separate from playback and storage logic.
- Expose shared app interfaces: `LessonRepository` for course metadata/progress, `AudioPlaybackController` for transport and repeat state, and `BackupService` for archive import/export.

### Local storage

- Persist lesson metadata and progress with SwiftData.
- Copy selected audio into the app-managed `Application Support/Still/Audio` directory; keep this storage path stable across the product rename and store only relative file names in SwiftData.
- Do not retain security-scoped source URLs. If import or persistence fails, remove staged files and leave the existing library intact.
- Each device maintains its own local library. Backups provide manual transfer; do not add a network API or cloud sync.

### Native audio

- Use AVFoundation `AVPlayer` for local MP3 and browser/system-supported audio, seeking, playback rate, and A–B loop boundaries.
- Preserve pitch during rate changes.
- On iOS, configure the playback audio session and background audio capability. Route app controls, lock-screen commands, and headset commands through the same playback controller.
- Present playback errors clearly when a file is missing or the media decoder rejects it.

## Backup and migration

- Native export uses a versioned `.stillbackup` ZIP archive containing `manifest.json` and an `Audio/` directory. The manifest stores lesson IDs, titles, audio paths/types, durations, creation/last-played dates, and saved positions.
- Use ZIPFoundation for archive creation and extraction. Validate the manifest and referenced paths before importing; do not extract arbitrary archive paths.
- Restore merges lessons without overwriting existing ones. Reassign IDs that collide with current or other imported lessons, and roll back copied files/models on failure.
- Import the existing web format `still-listening-backup` version 1 (JSON with base64 audio) and map its title, audio, duration, dates, and position into native storage.
- Do not attempt direct access to the web browser's IndexedDB.

## Data model

```text
Lesson
  id: UUID
  title: String
  relativeAudioPath: String
  audioType: String
  duration: TimeInterval
  createdAt: Date
  lastPlayedAt: Date?
  lastPosition: TimeInterval
```

Transcripts, bookmarks, practice queues, and automatic transcription remain later milestones.

## Acceptance and test plan

- Unit-test A–B range validation and legacy web backup decoding.
- Test import/export round trips, ID collisions, malformed or unsafe archives, unsupported audio, and file/database failure rollback.
- Test that a folder is searched recursively, that several files and folders in one selection keep their audio and report the rest, and that lesson titles come from file names.
- On iPhone, verify MP3 playback, speed, seek, A–B repetition, saved position, background playback, lock-screen commands, and headset play/pause/seek.
- Verify playlists can switch between manual, name, and recently-added ordering, and that playlist playback opens the full player with the active queue visible, advances in the selected order with wraparound, and resets completed lesson progress.
- On iPhone, verify playlist creation, renaming, switching, playback on selection, and volume adjustment.
- Verify the player and playlist views use the available iPhone screen with compact controls and system-adaptive backgrounds.
- On Mac, verify MP3 import/playback, speed, seek, A–B repetition, saved position, backup creation, and restore.
- On Mac, verify adding several files at once, adding a folder (including nested folders), dropping files or a folder onto the library, and that space, ←, and → drive transport while a text field or sheet keeps its own keys (PLANS.md line 16).
- Retire the web player only after both native targets pass acceptance and an exported web v1 backup imports successfully.
