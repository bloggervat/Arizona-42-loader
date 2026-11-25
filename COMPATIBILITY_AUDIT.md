# Arizona 42Loader compatibility audit

Audit date: 2026-11-25. This records source-level findings and binary metadata. No in-game behavior is claimed without a runnable iOS build and a device test.

## Source and IPA comparison

- The workspace source is `src/loader.mm` (108,374 bytes at this audit update). The copy packaged inside the IPA is `Payload/src/loader.mm` (78,113 bytes; SHA-256 `fb30d0cf7c032413cd23c2e789cb9d2d37985d09bb3647c53073c9a6c811c50c`). The two are not identical; the workspace copy contains newer functionality and should be treated as the active source.
- The IPA contains `Payload/Arizona.app/Frameworks/LuaLoader.dylib` (1,321,040 bytes), `libag-client.dylib` and three BASS libraries. The loader's Mach-O magic is `cffaedfe` (64-bit little-endian Mach-O, consistent with arm64). `Info.plist` sets MinimumOSVersion 15.0; CI previously targeted 13.0 and now targets 15.0.
- The app executable exports `_ui_input_end`; static inspection shows it converts the submitted string to a JNI string and dispatches `GTASA.OnInputEnd`. The source now installs a narrowly targeted Dobby hook there: recognized Loader commands are consumed, and unknown input is passed to the original function. This is based on the bundled Arizona build and still needs on-device confirmation. No local chat-output method was found among the exported functions. Strings such as `CChatWindow` do not establish a callable ABI.
- `Arizona_42loader.ipa` contains a packaged workflow and source copy, but not the supplied root `settime.lua` or `test.lua`. Those root scripts were inspected and left unchanged. Their Russian strings are visibly mojibake in the current files, so they cannot serve as a trustworthy CP1251/UTF-8 correctness fixture as-is.

## API status

| API group | Status | Source-level evidence / limitation |
|---|---|---|
| Lua 5.4 core, standard libraries, `require` | Partial | `luaL_openlibs` is used; app sandbox paths need device validation. |
| Script load and `main` coroutine | Partial | Initial state creation and chunk execution are scheduled on the Lua owner thread. Disable/reload cleanup and isolation still need device validation. |
| `wait`, `lua_thread.create` | Partial | Cooperative scheduler exists; a script can still block the frame by running unyielding Lua. |
| `lua_thread.create_suspended` / `resume` / active query / terminate all | Implemented in source, not built or runtime-tested | Suspended creation now starts suspended; resume and per-script termination helpers were added. Scheduler now removes terminated threads and releases registry references. |
| Local chat-style commands and outgoing game chat | Partial | `sampRegisterChatCommand` registers Lua callbacks. The `ui_input_end` hook consumes registered commands on the Loader side; all other input is forwarded to Arizona. Callback execution is queued to the Lua owner thread. The native path still needs device validation. |
| `sampAddChatMessage` | Unsupported in original game chat | The binding returns `false` and an explicit error because no local chat-output API with a verified ABI was found. |
| Game time/weather | Unsupported | These APIs now return explicit Lua errors instead of pretending internal variables changed the game. |
| INI (`inicfg`) | Partial | Lua serializer/parser exists and the diagnostic script includes a save/load round trip. Edge cases and atomic writes remain unverified. |
| Encoding | Not implemented | Current `encoding` module returns strings unchanged; CP1251 conversion is not implemented there. |
| JSON / cjson | Partial | Decoder now parses JSON tokens without `load`, supports nested arrays/objects, escapes, Unicode surrogate pairs, booleans, numbers, and a `json.null` sentinel. It is not runtime-tested; empty arrays and empty objects currently share Lua's empty-table representation. |
| FFI / memory | Unsupported | Arbitrary FFI and process-memory methods now raise clear iOS-unavailable errors instead of returning fake values. |
| `lfs` | Partial | Only `currentdir`, `mkdir`, and limited `attributes` are exposed; `dir` and `rmdir` are absent. |
| HTTP | Partial | Requests accept method, absolute URL, UTF-8 body, headers, and a bounded timeout; responses include status, UTF-8 text, and headers. Network callbacks only enqueue data. Lua callbacks run from the frame scheduler and are keyed to a unique script lifetime, so unload/reload cannot reuse a stale `lua_State`. This path is not compiled or runtime-tested here; requests are not actively cancelled on unload. |
| ImGui / mimgui | Partial | A small set of calls is bound; most widgets and state wrappers are absent. Metal integration is configured in CI but unbuilt here. |
| Render API | Not established | The requested `renderDraw*` APIs are absent from the active source. |
| Server/player/world APIs | Not supported reliably | Player, server, vehicle, key, dialog response, and textdraw APIs without a data source now return explicit unavailable errors. `isSampAvailable` and `isSampfuncsLoaded` return false; the connection-state query errors rather than claiming a connected game. |

## Repair work in this workspace

- Initial Lua script loading now happens in `TickScripts`, after it establishes the scheduler thread as the Lua owner. UI-originated commands, and command dispatch from any non-owner thread, are queued for that scheduler. Lua callbacks are not run from arbitrary UI threads.
- The floating button's UIKit target/action remains connected, and its pan recognizer no longer cancels a short button tap. The ImGui menu now uses responsive sizing and tab navigation. Touch input is captured only over the open Loader menu or active ImGui windows, so other screen areas pass through to the game.
- `tests/42loader_test.lua` exercises only bindings present in `src/loader.mm`. It marks full Lua-driven script unload and automated ImGui click verification as NOT SUPPORTED; users can disable a script in the Loader UI.
- The diagnostic Lua script has not been run. No Lua interpreter/compiler or Lua parser is installed in this workspace, and no iOS compiler/SDK is available. GitHub Actions was not dispatched because the workspace has no `.git` repository/remote and GitHub CLI is unavailable.

## Verification limits

The available workspace is Windows and has no `clang`, Xcode, iOS SDK, `otool`, or Apple signing tools. The iOS workflow cannot be executed locally. The IPA's embedded symbols/strings were inspected only as bytes; no ABI has been verified by calling game methods. No device is attached, so `settime.lua`, `test.lua`, and `tests/42loader_test.lua` have not been run in game. CI and in-game verification remain required before treating new compatibility as complete.
