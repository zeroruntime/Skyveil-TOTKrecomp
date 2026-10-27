# TOTK iOS Menu Handoff

Date: 2026-10-27

## Tested checkpoint
- Branch: `codex/totk-main-menu`; menu checkpoint `8ff34b8`. This note records the Settings checkpoint; tag `totk-settings-tested-2026-10-27` will point to its commit.
- Tested on iPhone 14 Pro Max. ARM64 build and device install passed.
- Settings UI is in `games/totk/ios/Sources/main_menu.m`.
- FPS choices are 30 or up to 60, wired to the runtime getter/setter and saved as `TOTK_PHONE_FPS` string values in `NSUserDefaults`.
- Gyro and haptics choices persist as booleans and are applied before Play. UI choice and persistence were verified; physical sensor behavior was not measured independently.
- Close button, scrim, and Escape dismiss the panel; menu video continues underneath it.
- Panel appearance was confirmed; close/reopen retains choices. Stored preferences were verified as 30 FPS, gyro on, haptics on.
- All 35 save files were byte-identical before and after the update.
- Focused checks passed: `python3 -m unittest discover -s tests -p test_phone_settings.py -v` and `test_ios_display_pacing.py` (2 passes each). Earlier packaging, vision, and game-selection checks passed (32 total).

## Menu and build notes
- Optional local video: `game_essentials/totk_menu_video.mp4` (H.264, 1080p60, about 32 seconds / 13 MB); it is not versioned. The packager accepts `--menu-video`, and the normal TOTK iOS root builder detects the file when present.
- Menu is full-bleed video with a top-aligned, vertically centered right-side button list (30 pt type, 0.2 tracking, 4 pt gaps); Play keeps the existing startup path. BOTW and vision direct-start behavior remain intact.
- Cached local build helper: `game_essentials/TOTK_menu_build/run_cached_ipa.py`; it reuses verified ARM64 dependencies and skips the dependency step. Outputs and logs are local; original `TOTK_build` files are preserved.

## Proposed follow-up (not approved)
- FPS overlay visibility and four-corner positioning, plus a neutral badge showing measured FPS (for example, 57 FPS), need explicit plan approval before implementation.
- `fps_overlay.c` / `fps_overlay.h` expose OFF, ALL, and MINIMAL modes; iOS currently uses ALL. MINIMAL hides diagnostics but still shows resolution and the green status mark.
- Overlay position is hardcoded top-right in `nvn_mtl.m`. The centered 30/60 touch button is a cap selector, not a live FPS counter.
- Language selection was deferred. Leave shared Mac/BOTW defaults and pacing unchanged.
