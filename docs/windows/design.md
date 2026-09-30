# Windows desktop implementation

## Goal and scope
Deliver a Windows 10/11 x64 desktop edition on an independent branch, preserving the existing macOS app and the seven creation modes, Next provider contract, 42 templates, reference voices, local draft/history, audio playback, and AI scriptwriter. The user requested autonomous implementation and testing, with necessary hands-on checks consolidated at delivery.

## Approach
A bundled Electron desktop process provides native dialogs, Windows DPAPI encrypted credentials, filesystem access, and a sandboxed local renderer. It requires neither a separately installed Node/Python runtime nor a local HTTP server. Alternatives were Swift-on-Windows (no SwiftUI/AVFoundation) and a full WPF rewrite (unavailable Windows runtime for iterative UI validation). A separate `windows/` application leaves macOS code and data unchanged.

Main-process domain modules own validation, immutable confirmed request snapshots, persisted idempotency, provider transport, and files. The renderer receives a narrow typed-by-contract IPC API, never credentials. Rendered model text is plain text, not HTML. Remote navigation, new windows, permissions, and network access in the renderer are denied. Credentials use Electron safeStorage/Windows DPAPI; no plaintext persistence fallback.

## Persistence and safety
Windows uses its own application-data directory and atomic versioned JSON database; write failures stop paid submission. Tasks are recorded before the one paid POST, never retried automatically. Interrupted or uncertain POSTs remain explicitly uncertain across restart. Downloads alone may retry and can be resumed without resubmission. Output folders are selected with the OS dialog and frozen per request. Files use generated identifiers, never user text as paths. Recycle-bin removal is logical and reversible; no destructive delete feature.

## Reference audio
Native selection allows WAV, MP3, M4A and OGG; Chromium decoding prepares a user-selected section (maximum 30 seconds) to mono PCM16 WAV. The main process independently validates bytes, size, duration and IDs before storing. Every generation preflight lists the selected reference files and the exact prompt and number of paid calls.

## Quality bar
Node tests cover actual data persistence, prompt parity, parameters, templates, request/response validation, timeouts, redirects, restart and duplicate submissions, downloads and WAV parsing. Browser/Electron integration tests exercise all navigation, drafts, settings, references, template use, preflight cancellation, paid-call deduplication with a fake provider, generation/history, and script import. Windows CI installs locked dependencies, runs tests, launches the desktop app and packages a portable ZIP. Real cloud calls are not made without a separately approved test budget/credentials. Actual sound quality, SmartScreen and physical Windows audio devices remain consolidated manual checks.

## Explicit first-edition limits
The independent Windows library does not import the macOS SQLite database or security-scoped bookmarks. Windows native ARM64 and installer/code-signing are outside this x64 portable build. These are documented gaps, not claimed parity.
