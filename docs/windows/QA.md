# Windows verification record

## Scope

Automated verification is performed with synthetic audio, temporary application data, encrypted fake keys and fake provider responses. No real billable Next or chat calls are made. Local Linux execution cannot run GUI browsers because the command environment blocks required socket operations; the supported cloud browser also rejects the local preview route. These are verification limits, not UI failures or passes.

## Automated gates

- Node domain, audio, persistence, transport, controller, security and independent-review tests: passing locally (98 at first integrated commit; final count recorded in the final PR summary)
- Syntax, shared 42-template catalog and dependency-lock consistency: passing locally
- Windows x64 cross-package: generated; executable PE machine 0x8664, required app resources and template count validated, ZIP SHA-256 generated
- Real Windows browser, desktop/DPAPI/media decoding and packaged executable tests: GitHub Actions is authoritative; consult the exact final commit checks rather than this initial record
- Original macOS Swift suite: not run in Linux; no existing Swift/macOS source or macOS build scripts changed

## Important regression checks

1. Confirmation cancellation or expiry causes no POST
2. Repeated clicks share one durable submission; restart never resubmits
3. Durable-write failure stops paid submission
4. Requesting-state crash recovers as uncertain with possible-charge warning
5. Downloads retry without a new paid request, and receipts stay out of the renderer
6. Changing chat provider binds the encrypted Key to its canonical endpoint; a failed settings write cannot send it to another provider
7. Renderer cannot access Node APIs, secrets, arbitrary local file paths or external networks
8. WAV validates actual physical bytes, streaming headers, metadata and duration; MP3 requires the bundled decoder, not just valid-looking frame headers
9. Original source draft and voice IDs are retained for reuse; slot removal does not renumber voices
10. Close flushes pending edits and keeps the app open when persistence fails

## Consolidated user-only checks

After all automated Windows checks pass, the remaining checks require your actual PC/account:

- Unzip and launch the portable app on your Windows 10/11 x64 PC; note SmartScreen/antivirus behavior without disabling protection
- At your normal display scaling, confirm creation, dialogs, keyboard navigation and Chinese text are usable; use Windows Narrator if needed
- Save test credentials yourself, restart, and verify configured status without a plaintext Key appearing
- Pick a writable local output folder using the real Windows dialog; cancel once and confirm the prior selection stays
- Import your authorized WAV, MP3, M4A and OGG reference files, choose a ≤30-second segment, and listen on your actual output device
- Make one explicitly approved short real Next call, with one candidate, after checking provider pricing. Confirm the result downloads, plays, matches the requested voice/text, and appears once in provider billing
- If you use AI 编剧, make one short real request against your configured provider and import its script

Hardware listening quality, real service entitlements/pricing and Windows security-product prompts cannot be established by deterministic mocks. Report any failure with the operation and visible error; do not send API Keys or credentials.
