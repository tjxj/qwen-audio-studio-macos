# Windows desktop implementation plan

Goal: Implement, test, package and independently review the Windows edition described in design.md.

1. Core: Add failing Node tests for prompt/parameter/template/request parity; implement pure domain modules. Add real filesystem and fake-provider lifecycle tests first, then atomic store and generation service. Verify with `npm test`.
2. Shell: Add security and IPC tests, implement Electron main/preload with secure credentials, dialogs and allowlisted asset access. Build resources from the existing 42-template catalog.
3. UI: Build Chinese desktop screens for creation, scriptwriter, template variables, library/recycle bin and settings; add browser interaction tests and reference audio conversion tests.
4. Integration: Run actual Electron with test-only fake provider in temporary storage; test cancel/repeat/restart flows and verify secrets do not cross renderer boundary. Fix regressions.
5. Delivery: Produce Windows x64 ZIP, validate archive contents and executable headers, add Windows CI, push the independent branch and draft PR, wait for exact-commit checks, and document all passed/failed/not-run checks and consolidated Windows manual validation.

Review focus: duplicate clicks and uncertain requests must not double-bill; removed/reordered voices must not silently rebind; failed writes must stop paid POSTs; invalid provider URLs and renderer IPC must not expose arbitrary local files/credentials; closing, cancelling and reopening must preserve edits without automatically generating.
