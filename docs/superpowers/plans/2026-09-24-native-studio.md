# Qwen Audio Studio for Mac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Ship a fully native macOS audio studio and a locally installable DMG with the accepted V2 functionality.

**Architecture:** SwiftUI/AppKit owns all windows and controls; StudioCore owns domain validation, SQLite, provider requests and local audio operations. The native process connects directly to the Next model. Old web data is copied through an explicit import flow.

**Tech Stack:** Swift 6.0.3, macOS 14 deployment target, SwiftUI, AppKit, AVFoundation, AudioToolbox, SQLite3, Security, URLSession, Swift Testing/XCTest, hdiutil.

**Spec:** `docs/spec.md`

## Global Constraints

- No WebView, localhost service, Python, Node or ffmpeg in the installed app.
- No real credentials, personal audio or private paths in source, logs, DMG screenshots or GitHub.
- Model ID is exactly `qwen-audio-3.1-tts-next`; maximum compiled Prompt 3000 Unicode scalars; 1–3 candidate seeds and at most 3 references.
- Screen baseline 1280×720 with no page or common-control scroll. Advanced settings appear in a native sheet.
- Web app and its metadata stay untouched; import reads its data and preserves IDs and generated audio.
- Every cloud reference upload requires an explicit batch-specific confirmation. Uncertain paid requests are never replayed automatically.
- All tests run with temporary stores and fake provider unless the single real smoke is separately identified.

## Review Focus

1. A second app instance or stale startup cannot reclassify a live paid task or free its reference lease. Pin in Task 4.
2. Provider response lost after submission cannot create a second paid batch on retry. Pin in Task 6.
3. A missing/reordered reference cannot silently attach the wrong voice to raw `@voiceN`. Pin in Task 3 and Task 7.
4. Selected output folder permissions can disappear after restart; generation fails before charging. Pin in Task 5.
5. Source web metadata can be corrupt or contain missing assets; import stays recoverable and reports counts. Pin in Task 10.

---

### Task 1: Buildable native shell and one-screen UI

**Files:** `Package.swift`, `Sources/StudioCore/StudioModels.swift`, `Sources/QwenAudioStudioMacApp/App.swift`, `AppShell.swift`, `CreationScreen.swift`, `LibraryScreen.swift`, `TemplateScreen.swift`, `SettingsScreen.swift`, `Resources/Info.plist`, `scripts/build-app.sh`, `Tests/StudioCoreTests/StudioModelsTests.swift`.

**Interfaces:** `enum CreationMode: String, Codable, CaseIterable`; `struct GenerationParams: Codable, Equatable` (format/sampleRate/channels/volume/rate/seed/enableCBR/bitRate/quality/enableAIGCTag); `struct ReferenceBinding: Codable, Equatable` (referenceID/alias); `struct StudioLayout { static let minWidth = 1120; static let minHeight = 720 }`; `@main struct QwenAudioStudioMacApp: App`.

- [x] Write a test that all seven modes retain their stable persisted IDs and that layout minima equal 1120×720. Run `swift test`; first run must fail for the missing model.
- [x] Create the Swift Package, seven-mode model and a SwiftUI window with navigation 创作台/作品库/灵感模板 and native Settings scene. Use a centered script editor plus right inspector; remove the old redundant workflow description and project-creation CTA. Bundle and register the legally renamed native TTF font so this works on another Mac without the user's local font installation.
- [x] Run `swift test` to green. Build an actual `.app` with `swift build -c release` and `scripts/build-app.sh`; launch and inspect the Mac window. Check 1280×720 and the dark appearance visually before accepting the slice.
- [x] Commit the shell and tests. Keep all preview data visibly marked as samples.

```swift
#expect(CreationMode.allCases.map(\.rawValue) ==
  ["podcast","advertisement","audiobook","drama","game","narration","auto"])
```

### Task 2: Project draft and editor experience

**Files:** `Sources/QwenAudioStudioMacApp/DraftModel.swift`, `PromptEditor.swift`, `ParameterInspector.swift`, `Theme.swift`, `Tests/StudioCoreTests/DraftTests.swift`.

**Interfaces:** `DraftFields(name:mode:prompt:params:referenceBindings:outputDirectoryID:)`; `protocol DraftStore` with `create(_:) async throws -> ProjectDraft` and `save(_:expectedRevision:) async throws -> ProjectDraft`; `DraftController.change(_:) / saveNow()` with 800ms debounce and revision conflict. Task 2 uses an in-memory DraftStore; Task 4 adds the SQLite implementation.

- [x] Add tests for a hand-edited prompt surviving all seven mode changes, for a generated sample being replaced only while untouched, for Cmd-S waiting for an in-flight save, and for a 409 revision conflict keeping its local recovery text. See tests fail before implementation.
- [x] Build an AppKit NSTextView bridge for selection/undo and structured tag insertion. Add appearance and script font/size preferences, clear save states, keyboard focus and a stable first-window layout.
- [x] Run focused tests and resize the native window; no clipping at the accepted minimum. Commit.

### Task 3: Prompt compiler and 42 templates

**Files:** `Sources/StudioCore/PromptCompiler.swift`, `TemplateEngine.swift`, `Resources/templates.json`, `Sources/QwenAudioStudioMacApp/TemplateLibraryView.swift`, `Tests/StudioCoreTests/PromptCompilerTests.swift`, `TemplateEngineTests.swift`.

**Interfaces:** `PromptCompiler.compile(mode:prompt:bindings:) throws -> CompiledPrompt`; `TemplateEngine.preview(templateID:values:) throws -> TemplatePreview`.

- [x] Copy the existing public 42-template dataset, preserving all IDs. Add tests that each mode has six items, defaults expand without unresolved variables, unknown/overlong values fail, and applying a template then Undo restores previous text.
- [x] Add compiler tests for 3000 Unicode scalars, seven mode mappings, a missing `@voiceN`, and changed binding order. Run tests red.
- [x] Implement pure Swift expansion and prompt compilation. Present variable form and full preview in a native sheet; built-ins stay read-only, custom templates support create/edit/remove/favorite. Run green and commit.

### Task 4: SQLite store, migration schema and ownership

**Files:** `Sources/StudioCore/SQLiteConnection.swift`, `StudioStore.swift`, `Schema.swift`, `InstanceOwnership.swift`, `Tests/StudioCoreTests/StudioStoreTests.swift`.

**Interfaces:** `actor StudioStore` with `createProject`, `saveProject(expectedRevision:changes:)`, `createBatch(clientRequestID:requestHash:)`, `claimJob`, `cancelQueued`, `listLibrary`; `InstanceOwnership.acquire(dataRoot:)`.

- [x] Write temporary-file tests for optimistic revision, atomic batch insertion, duplicate ID same/different body, one ownership lock across processes, restart interruption and queued-cancel race. Run red.
- [x] Implement versioned SQLite migrations, WAL, foreign keys and short transactions. Preserve immutable request snapshots and file journals. Do not open or mutate the web database here.
- [x] Run focused and full store tests, including crash/reopen. Commit.

### Task 5: Output folders, Finder and recoverable files

**Files:** `Sources/StudioCore/OutputDirectoryStore.swift`, `GeneratedAssetStore.swift`, `Sources/QwenAudioStudioMacApp/OutputFolderPicker.swift`, `Tests/StudioCoreTests/OutputDirectoryTests.swift`, `AssetRecoveryTests.swift`.

**Interfaces:** `OutputDirectoryStore.register(selectedURL:) -> DirectoryID`, `resolveForJob(_:directoryID:) throws -> URL`; `GeneratedAssetStore.trash(job:scope:) / restore(job:)`.

- [x] Add red tests for cancel preserving current selection, Chinese/space names, unreadable/disconnected volume, bookmark reopen, unique job paths, record-only removal and generated-files trash/restore with conflicting target names.
- [x] Integrate NSOpenPanel and security-scoped bookmarks, register only authorized URLs, write `prompt.txt` and reports beside each generated asset. Add Finder reveal for registered assets/directories.
- [x] Run green and test the real dialog on a Mac. Commit.

### Task 6: Keychain, Next client and paid-request state machine

**Files:** `Sources/StudioCore/CredentialStore.swift`, `NextClient.swift`, `GenerationService.swift`, `Sources/QwenAudioStudioMacApp/GenerationSheet.swift`, `Tests/StudioCoreTests/NextClientTests.swift`, `GenerationServiceTests.swift`.

**Interfaces:** `protocol SynthesizerClient { func synthesize(_ request: CompiledRequest) async throws -> ProviderOutput }`; `GenerationService.preflight(_:) / submit(_:confirmedHash:clientRequestID:)`.

- [x] Add red tests with URLProtocol/fake synthesizer: exact Beijing endpoint and model, no plaintext credential in response/log, compiler+params preflight stopping paid calls, two different seeds causing exactly two calls, duplicate nonce not causing extra calls, uncertain outcome never auto-resubmitting, and a queued-only cancel.
- [x] Store API Key and Workspace ID in dedicated native Keychain items. Build URLSession request/download, validate server response, show compiled prompt/call count/reference names in an explicit charge confirmation sheet. Keep cloud/network work off the UI actor.
- [x] Run green and commit. Real API calls remain separate from automatic tests.

### Task 7: Voice import, trim, codec coverage and leases

**Files:** `Sources/StudioCore/ReferenceAudioService.swift`, `AudioSignalMeter.swift`, `ReferenceLeaseStore.swift`, `Sources/QwenAudioStudioMacApp/VoiceSheet.swift`, `Tests/StudioCoreTests/ReferenceAudioTests.swift`.

**Interfaces:** `ReferenceAudioService.importSource(url:)`, `prepare(importID:start:end:persistent:name:) -> PreparedReference`, `acquire(_:forJob:) / release(job:)`.

- [ ] Add red tests for WAV/MP3/M4A/OGG Opus, a 40-second source trimmed to six seconds, 0/30-second boundaries, file/container mismatch, oversize, original-file preservation, silence/low-volume/clipping hints and two jobs holding the same temporary clip.
- [ ] Use AVFoundation/Core Audio for supported containers, with an app-bundled native OGG/Opus decoder if the host lacks one. Convert selected range to mono PCM16 WAV, ≤10 MiB and ≤30 seconds. Show source and selection audio preview.
- [ ] Persist only clips explicitly saved by the user; enforce one-batch ten-minute consent and reference leases. Run tests/real UI manual trim, then commit.

### Task 8: Single-source player, waveform and A/B

**Files:** `Sources/StudioCore/AudioDecoder.swift`, `Sources/QwenAudioStudioMacApp/AudioPlaybackController.swift`, `WaveformView.swift`, `ResultScreen.swift`, `Tests/StudioCoreTests/AudioPlaybackTests.swift`.

**Interfaces:** `AudioPlaybackController.play(assetID:)`, `seek(seconds:)`, `compare(assetA:assetB:)`, `switchToA/B()`, `setLoop(start:end:)`.

- [ ] Add red playback tests with distinct 5/8-second real test tones: switching A/B produces one audible output at a shared position within 150ms, main playback pauses when compare starts, seek/10s-back/volume/0.5s loop, missing file and route change release old output.
- [ ] Decode actual samples and cache waveform by asset hash; use one AVAudioEngine player ownership controller. List every version; show actual validation result and PCM playability only after correct native decoding.
- [ ] Verify with audio fixture and inspect the native result screen, then commit.

### Task 9: Library and settings full wiring

**Files:** `Sources/QwenAudioStudioMacApp/LibraryScreen.swift`, `SettingsScreen.swift`, `AppState.swift`, `Tests/StudioCoreTests/LibraryTests.swift`, `SettingsTests.swift`.

**Interfaces:** Filter values map to `StudioStore.listLibrary`; row actions call registered job/asset IDs. Settings patch one credential field without changing the other.

- [ ] Add red tests for all job states, missing-file actions, filters with stable pagination, rename/favorite/note/continue/final/project archive/report export, trash restore and partial Keychain edits.
- [ ] Connect UI to store, generator, references and playback; use real loading/error/confirmation states. Help links open official docs through NSWorkspace. Keep secrets out of export reports and preferences.
- [ ] Run green and use the app window to click each primary control. Commit.

### Task 10: Read-only web import, DMG and final QA

**Files:** `Sources/StudioCore/LegacyImporter.swift`, `Sources/QwenAudioStudioMacApp/ImportSheet.swift`, `scripts/build-dmg.sh`, `docs/QA.md`, `README.md`, `Tests/StudioCoreTests/LegacyImportTests.swift`.

**Interfaces:** `LegacyImporter.preview(source:) -> ImportCounts`, `import(source:target:) throws -> ImportReport`; old source never opened for writing.

- [ ] Add red fixtures for old JSON and V2 SQLite with exact project/job/asset IDs, final selection, missing file, corrupted JSON and interrupted import. Tests assert old fixture hashes and counts do not change.
- [ ] Implement backup, staging database, counted copy of managed assets, journal repair and atomic activation. Import requires an explicit user-selected old folder and confirms source count. Refuse import while the web app's old data-root ownership lock is held.
- [ ] Run full `swift test`, launch the actual app, inspect all 13 requirement groups, four window sizes, light/dark, keyboard/VoiceOver, real M4A/OGG files and signed-output playback. Use one identified short Next smoke only when configured.
- [ ] Build a local DMG with an Applications shortcut; run `hdiutil verify`, mount, install and relaunch. Record actual code-signing/notarization status. If a Developer ID is configured, sign, notarize and staple; never claim an ad-hoc DMG is publicly notarized.
- [ ] Save Retina screenshots, README usage/setup, QA evidence and known limits; scan Git files for credentials/private paths; commit and publish to the approved new repository.
