# Changelog

## 2026-03-17

- **Phase 1 (JNI Zero-Copy + Build Scaffold)**: Replaced ByteArray frame path with ByteBuffer zero-copy JNI; added `jni_bridge.cpp`, `engine.h/cpp`, `canvas.h/cpp`, `types.h`; created `lib/stitcher/stitch_state.dart` (`NavigationState`, `StitchControl`); updated `NativeStitcher.kt` and `MainActivity.kt` with new stitch MethodChannel; camera now requests 1600×1200 analysis and calls `initEngine` after start.
- **Phase 2 (Navigation Pipeline)**: Added `navigation.h/cpp` with phase correlation (`cv::phaseCorrelate` + Hanning window), velocity EMA + deadband, Laplacian sharpness, tracking FSM (INIT→TRACKING→UNCERTAIN→LOST), and full capture gating (8 checks, structured reason-code logs); wired inline stitch commit path in `Engine::processAnalysisFrame`.
- Created OpenCV symlink `android/opencv → ../../eva_minimal_demo/android/opencv`; `CanvasView` now accepts `previewBytes` and displays live JPEG preview; nav state polled at 50ms via `Timer.periodic`.

## 2026-03-14

- Extracted camera stack into reusable Flutter plugin at `packages/eva_camera/` (Dart + Kotlin/CameraX).
- App's `MainActivity.kt` reduced to minimal FrameProcessor registration; NativeStitcher stays in-app.
- Added SCENE_MODE=DISABLED, CAPTURE_INTENT (with `CaptureIntent` enum toggle), ZSL capture mode, and TotalCaptureResult forwarded to FrameProcessor.
- Unified capture API: single `captureImage()` + `setCaptureFormat(yuv|jpeg)` replacing separate `captureJpeg`/`captureYuv`; format switch triggers camera rebind via extracted `rebindUseCases()`.
- ImageCapture defaults to YUV_420_888 via `setBufferFormat`; resolution bumped to 4208×3120 (capture) and 1280×960 (analysis).

## 2026-03-13 (update 43)

- Added `DUMP SETTINGS` button to camera settings bar; tap now triggers an explicit camera settings dump.
- Removed old startup auto-dump behavior so characteristics are captured only on user request.

## 2026-03-13 (update 42)

### Asset Migration

- Updated `MiniMap` and `CanvasView` to use the `assets/r04_c04.png` (registered in `pubspec.yaml`) instead of the temporary path in `scripts/tmp_files/`.

## 2026-03-13 (update 41)

### Bottom bar simplification

- Removed the `CAMERA` action button from `InteractiveBottomBar` and deleted its related widget props/callback wiring from `main.dart`.
- Removed `_showCameraFull` and all full-camera-mode behavior (toggle paths, size/position branching, and minimap visibility branching) from `main.dart`.

## 2026-03-12 (update 40)

### Instruction stack restructure per GitHub official guidelines

- Restructured `copilot-instructions.md`: compressed from ~180 to ~90 lines with essential info inline (not a router). Removed LeftToolbar reference, updated widget list, merged Build/Terminal subsections.
- Trimmed `context7.instructions.md` (~95→28 lines) and `self-explanatory-code-commenting.instructions.md` (~150→12 lines); removed JS examples and generic advice LLMs already know.
- Enhanced `code-review.instructions.md` with project-specific critical invariants checklist (Camera2 atomic writes, CameraSettingsQueue, theme compliance, widget conventions).

## 2026-03-11 (update 39)

### Canvas-first layout with floating camera preview window

- Canvas (`CanvasView`) is now the permanent base layer instead of an optional overlay.
- `CanvasView` refactored to use `InteractiveViewer` for pan/zoom, rendering a 6000×6000 logical canvas with background → grid → stitched-image stack. Mockup image (`scripts/tmp_files/r04_c04.png`) registered as a Flutter asset.
- Camera preview moved from full-screen fill to a centered, framed window: 60 % of screen width, 4:3 aspect ratio, with rounded border using `cs.primary`.
- `_showCanvas` state, `onToggleCanvas` callback, and the CANVAS button remain in `main.dart`/`InteractiveBottomBar`; the new canvas-first layout is layered on top of the existing toggle logic.

## 2026-03-09 (update 34)

### Material 3 full theme refactor — remove app_theme.dart

- Deleted `lib/app_theme.dart` and `lib/material_theme_util.dart`; created `lib/theme/material_theme_salmon.dart` (salmon `MaterialTheme`) and `lib/theme/theme_util.dart` (`createTextTheme` via `google_fonts`). Added `google_fonts: ^6.2.1` to `pubspec.yaml`.
- All widgets now use `Theme.of(context).colorScheme` directly (`cs.primary`, `cs.surfaceContainer`, `cs.outlineVariant`, etc.) — no `k*` constant imports remain anywhere in `lib/`.
- `_WbControlPanel` replaced `_WbActionButton` pair with M3 `SegmentedButton<bool>`; `_GridPainter` and `_MiniMapPainter` receive colors as constructor params from parent `build()`.
- Replaced custom `_CamSettingsChip` (GestureDetector+AnimatedContainer) with M3 `FilterChip` in `camera_settings_drawer.dart`
- ruler dial `fadeColor` derived via `Color.alphaBlend` to match the composite pill background exactly.
- `_StatusBadge` idle dot changed from `cs.outline` (muted) to `cs.tertiary` (warm gold = ready/ok); `SideButton.color` prop now respected when `isActive` so `cs.tertiary` renders for the scanning button.
- `snackBarShape` moved into `MaterialTheme.theme()` using `colorScheme.outlineVariant`

## 2026-03-09 (update 33)

### Fix missing @OptIn on resolveMaxAeFpsRange

- Added `@OptIn(ExperimentalCamera2Interop::class)` to `resolveMaxAeFpsRange` in `CameraManager.kt` to match the rest of the file and prevent compilation failure.

## 2026-03-09 (update 32)

### Fix WB lock UI/native desync on failure

- In `_initSettingsQueue` `onError` for `CameraSettingKey.wb`, added a `setState` that flips `wbLocked` back, reverting the optimistic UI update when the native lock/unlock call fails.

## 2026-03-09 (update 31)

### Fix CameraRulerDial spurious resyncs on parent rebuild

- Removed `config` identity check from `didUpdateWidget` in `camera_ruler_dial.dart`; only `initialValue` changes now trigger `_syncToInitialValue()`.
- Prevents the dial from jumping back to `initialValue` during FPS-event rebuilds (every 500 ms) while the user is dragging.

## 2026-03-09 (update 30)

### AE FPS range initialization and max-range selection

- `CameraManager.kt` now records the default live AE FPS range from the first `TotalCaptureResult` and stores it in `defaultAeTargetFpsRange` for diagnostics.
- Added storage of all device-supported AE FPS ranges from `CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES` and logs them during camera startup.
- On camera init, selects the highest supported FPS range (prefers fixed max like `[60,60]`) and applies it through `applyAllCaptureOptions()`.
- AE FPS cached values are reset on camera start/stop to avoid stale range/default values across rebinds.

### Unified camera settings latest-wins queue

- Replaced per-slider senders in `main.dart` with a unified `CameraSettingsQueue` (`lib/camera/camera_settings_queue.dart`) that serializes native camera writes and keeps only the latest pending value per setting key.
- Unifies Flutter camera writes to one queue path. All writes now route through queue updates:
AF, focus, ISO, shutter, zoom, WB.
- Removed `_focusNeedsAfDisable`; manual focus now always enforces AF-off first inside the queue, then applies the latest focus value, while AF-on drops pending manual focus writes.
- Routed AF/focus/ISO/shutter/zoom/WB writes through the same queue to avoid piling up and interleaving `applyAllCaptureOptions` calls during rapid UI scrubs.

## 2026-03-09 (update 29)

### Ruler helper readability cleanup

- Extracted `_isNearInteger(...)` in `ruler_picker.dart` and switched major-tick detection to use it for cleaner, self-documenting tick math.

## 2026-03-09 (update 28)

### Slider sender clarity + ruler tick fix

- Renamed sender init helper in `main.dart` to `_initSliderValueSenders()` and clarified focus prerequisite comments for AF-disable-before-manual-focus behavior.
- Fixed `RulerPicker` major-tick detection (removed a tautological expression), so minor ticks no longer misclassify major positions.
- Expanded `_RulerPainter.shouldRepaint` to include `step`, `pixelsPerStep`, and `labelBuilder` changes.

## 2026-03-09 (update 27)

### Unified latest-value slider sender

- Added `lib/camera/latest_value_sender.dart`: a small latest-value-wins async sender used to serialize slider-driven native updates.
- Refactored ISO and shutter handlers to update UI immediately but send native updates through the shared sender, preventing in-flight Camera2 option update churn during scrubs.
- Replaced the custom focus worker with the same sender while preserving AF-disable-before-focus behavior and keeping AF-specific failure handling in `main.dart`.

## 2026-03-09 (update 26)

### Focus slider AF handoff

- Moving the focus slider now flips the UI into manual focus immediately, disables AF first if needed, and then applies the requested focus distance in sequence.
- While manual focus commands are in flight, Flutter now keeps only the latest pending slider value instead of queueing every intermediate drag step.
- While the focus slider is open and AF is enabled, the slider now polls the live autofocus lens distance so its thumb stays aligned with the current focal position.
- Camera startup now explicitly syncs AF on/off state to native Camera2 so the toolbar and native autofocus mode start in agreement.
- Simplified the manual-focus handoff worker to a single latest-value slot plus one AF-disable flag, keeping the logic aligned with the KISS goal.

## 2026-03-09 (update 25)

### Camera module extraction

- Created `lib/camera/` module: `camera_state.dart` holds `CameraParam` enum, `CameraValues`, `CameraRanges`, `CameraInfo` (all immutable with `copyWith`), and `CameraCallbacks`; `camera_control.dart` moved from `lib/` into `lib/camera/`.
- `CameraValues.initialFromRanges()` is the single source of truth for startup defaults; also syncs computed values to native camera immediately after ranging.
- `CameraControlOverlay` (formerly `FloatingHoverSlider`) drops from 17 constructor params to 4; `CameraSettingsDrawer` drops from 13 to 5; duplicate `CameraParam` enum removed from drawer.
- fixed bugs

## 2026-03-08 (update 23)

### CameraRulerSlider

- centralized style configuration
- composed style classes + configurable haptics
- Camera dial presets extracted from main.dart
- Simplified dial presets API
- Extracted the slider and wb action bar into its own widget library

- Added `CameraDialStyle` in `camera_dial_config.dart` to control slider appearance/layout (tick spacing, total height, tick top, icon paddings, fade, tick/label/indicator visuals).
- Replaced helper functions with simple per-dial objects in `camera_dial_presets.dart`: `IsoDialPreset`, `ShutterDialPreset`, `ZoomDialPreset`, `FocusDialPreset`, each exposing `toModel()`.

## 2026-03-08 (update 22)

### CameraRulerSlider: full file refactor

- Moved all layout constants to file level (`_kTickSpacing`, `_kTotalHeight`, `_kTickTop`, `_kIconPad`, `_kFadeZone`); removed duplicate `tickSpacing` static consts from state and painter classes.
- Renamed state fields to private (`_velocity`, `_lastDragTime`, `_inertiaTimer`); removed empty `didUpdateWidget` override; renamed drag/snap/inertia methods to `_updateDrag`, `_snapToNearest`, `_startInertia`, `_onDragEnd`.
- Made `_TicksPainter` and `_LabelsPainter` constructors `const`; added `_LabelsPainter._makeLabel` and `._paint` as proper methods; reworked all inline comments to be short and purposeful.

## 2026-03-08 (update 21)

### CameraRulerSlider: Per-tick alpha fade in painter (replaces ShaderMask)

- Rewrote `_TicksPainter` to accept `rulerOffset` and draw only viewport-visible ticks. Each tick alpha is computed from its distance from the inner-zone viewport edges (`_fadeZone = 30px`), fixing the invisible-tick-at-min/max bug permanently.
- Removed `ShaderMask`, `RawImage`, GPU cache, and scrolling `Positioned` — inner zone is now a single `ClipRect > Stack([Positioned.fill tick painter, Positioned.fill label painter])`.

- Wrapped inner zone `ClipRect` in `ShaderMask(blendMode: BlendMode.dstIn)` with gradient transparent→white (8%)→white (92%)→transparent for soft tick edge fade.
- Added `ColoredBox(Color(0xFF1A1A1A))` as first Stack child to give `ShaderMask` stable, scroll-independent bounds — fixes invisible ticks at min/max positions.
- Fade is seamless: background matches container color so the reveal has no color discontinuity.

## 2026-03-08 (update 19)

### CameraRulerSlider: bottom-aligned ticks, thicker indicator, transparent container

- Ticks reverted to bottom-aligned (grow upward from baseline), matching reference images; center-alignment was wrong.
- Center indicator enlarged from 3×20 to 4×24 px capsule (`Color(0xFFED9478)`) — now clearly taller than major ticks (14px) and visibly protrudes above them.
- Container changed from `Color(0xFF121212)` at 0.8 alpha → `Colors.black` at 0.65 alpha; `fadeColor` also set to `Colors.black` — matches the more transparent dark-glass look in reference.

## 2026-03-08 (update 18)

### CameraRulerSlider: no icon overlap + reference visual style

- Tick strip and labels now clipped to inner `[_kIconPad=36px, width-36px]` zone via nested `ClipRect` + `Positioned`; icons always render over the non-tick edges so there is zero overlap.
- Tick color changed from white → warm salmon `Color(0xFFD4847A)` (major 85%, minor 45%), ticks center-aligned vertically to match the reference camera-app style.
- Center indicator changed from flat 2×16 `Colors.orange` line → 3×20 rounded capsule `Color(0xFFED9478)` with `borderRadius: 100`; fade gradient tightened to stops `[0, 0.12, 0.22, 0.78, 0.88, 1]`.

## 2026-03-08 (update 17)

### CameraRulerSlider: end icons per slider

- Added optional `leftIcon`/`rightIcon` (`Widget?`) params to `CameraRulerSlider`; icons are positioned inside the capsule at each edge, centered vertically in the fade zone.
- Added `_sliderLeftIcon()`/`_sliderRightIcon()` helpers in `main.dart`; ISO uses brightness_5/brightness_7, shutter uses shutter_speed both sides, zoom uses zoom_out/zoom_in, focus uses center_focus_weak/center_focus_strong.
- Left icon 14px / right icon 20px, both at 50% white opacity — mirrors the reference camera app style (smaller left = min, larger right = max).

## 2026-03-08 (update 16)

### CameraRulerSlider + main.dart: ISO/shutter stops, compact size, 600px width

- ISO: expanded to 1/3-stop values 50–6400 (22 stops), majorTickEvery=3 (full stops: 50,100,200,400,800,1600,3200,6400).
- Shutter: replaced uneven stops with standard 1/3-stop sequence 1/8000–1/15 (28 stops), majorTickEvery=3; previously all-major clustering fixed.
- Slider height halved (totalHeight 80→44, cacheHeight 28→16, tickTop 44→24, tick heights 22/11→14/7, indicator 28→16, fonts 24/12→18/10); container width capped at 600px centered, padding minimised (4px v), Positioned height 140→80.

## 2026-03-08 (update 15)

### CameraRulerSlider: compact visual redesign

- Bottom-aligned ticks (major 22px/2px, minor 11px/1.5px), reduced tick spacing 22→18px, refined opacity (85% major / 35% minor); center glow removed.
- Label hierarchy: large bold center value (24px) + small faint major-tick-only labels (12px) with opacity falloff; minor ticks unlabelled.
- Total widget height reduced 100→80px (full-width gesture zone preserved); tick strip at `_tickTop=44`, indicator height matches tick strip (28px).

## 2026-03-07 (update 14)

### CameraRulerSlider: scrolling-texture layer architecture

- Replaced `CustomPainter` + `canvas.translate` with `Transform.translate` + `RawImage` — texture translation is now a compositor GPU op, zero Dart CPU per drag frame.
- Edge fade and center glow moved to widget-layer `Container` gradients (also GPU composited, no canvas code).
- `_RulerPainter` removed; replaced with thin `_LabelsPainter` (text-only, ~8 labels, cheap). Accumulator snapping and inertia unchanged.

## 2026-03-07 (update 13)

### CameraRulerSlider: per-tick snap during drag, subpixel rendering, no flicker

- **Snap-on-drag**: replaced float `percent` with `_currentIndex` (int) + `_dragAccum` (pixel accumulator). Index advances one step per `tickSpacing` px of drag; haptic and visual snap simultaneously.
- **Subpixel rendering**: `canvas.translate(dx, 0)` feeds the fractional offset into the GPU matrix instead of rounding it through `drawImage(Offset)`.
- **No flicker**: `didUpdateWidget` compares by config content (stopCount / majorTickEvery) and never nulls the cache before the rebuild completes.

## 2026-03-07 (update 12)

### Fixed CameraRulerSlider ticks spread/frozen, added labels

- Restored async cache but with `const _cacheHeight = 100` (fixed) instead of `size.height` (was `infinity` inside Column → silent failure).
- Replaced scroll-offset translation with center-lock: `dx = width/2 − activeIndex × tickSpacing`, so the active tick always sits under the orange indicator and ticks move correctly on swipe.
- Added `_drawLabels()` in painter: fades ±4 stops around center, with bold weight on the active stop.

## 2026-03-07 (update 11)

### Fixed invisible ruler ticks in CameraRulerSlider

- Removed async GPU cache (`buildCache`) — it failed silently because `constraints.maxHeight` was `infinity` inside a `Column(mainAxisSize: min)`, causing `picture.toImage(w, infinity.toInt())` to produce nothing.
- Replaced with direct tick drawing in `_RulerPainter.paint()`. Strip spacing auto-expands when stop count × tickSpacing < widget width to prevent negative scroll offsets (bug with 6 ISO stops).

## 2026-03-07 (update 10)

### Fixed ISO/shutter stops and updated CameraDialConfig usage

- Replaced dynamic ISO stops with fixed list `[100, 200, 400, 800, 1200, 1600]` and shutter stops with 13 fixed fractions (1/10 – 1/500000) converted to nanoseconds.
- Updated all four `CameraDialConfig` usages in `_buildHoverSlider()` to the new API (`stops`, `majorTickEvery`, `formatter` only); zoom/focus generate log-spaced stops via `List.generate` + `pow`.

## 2026-03-07 (update 9)

### GPU-cached ruler rendering restored

- Restored the `CameraRulerSlider` tick strip to render from a prebuilt cached image again, while keeping major tick labels dynamic on top for readability.
- Cache rebuilds now only trigger when ruler geometry changes, preserving the intended smooth scrolling path from the original slider design.

## 2026-03-07 (update 8)

### Ruler tick visibility restored

- Fixed `CameraRulerSlider` so tick marks and labels are painted directly again, preventing blank sliders where only the orange center marker remained visible.
- Reduced label density on discrete ISO and shutter sliders by promoting every third stop to a major tick.

## 2026-03-07 (update 7)

### Settings drawer animation overflow fix

- Reworked the bottom camera settings strip open/close animation to use a clipped height-factor animation instead of shrinking child layout constraints.
- This prevents `_ParamChip` content from overflowing vertically during drawer open/close transitions and hot restarts.

## 2026-03-07 (update 6)

### Discrete ISO and shutter slider stops

- Updated `main.dart` to initialize the new `CameraDialConfig` API with `stops`/`formatter` instead of the old continuous-label config.
- ISO and shutter sliders now snap to practical photography-style discrete stops, filtered to each device's supported min/max range and padded with exact range endpoints when needed.

## 2026-03-07 (update 5)

### Manual-only exposure controls

- Removed AE/EV from the Flutter camera UI so exposure is always controlled directly with the ISO and shutter sliders.
- Defaulted the native camera pipeline to manual exposure mode on startup and applied stored ISO/shutter settings immediately after binding the camera.

## 2026-03-07 (update 4)

### All params now use floating CameraRulerSlider — no drawer expansion

- Removed the bottom dial-panel expansion entirely from `CameraSettingsDrawer`; it is now a pure stateless 52-px icon strip with no internal slider/dial state.
- Added ISO, Shutter, and EV cases to `_buildHoverSlider()` in `main.dart` so all 6 params show the floating `CameraRulerSlider` overlay above the strip.
- Simplified `CameraSettingsDrawer` constructor: removed `isoRange`, `exposureTimeRangeNs`, `exposureOffsetRange`, `minFocusDistance`, `minZoomRatio`, `maxZoomRatio`, and all `onXxxChanged` callbacks (those now live entirely in `main.dart`).

## 2026-03-07 (update 3)

### Floating CameraRulerSlider overlay for Zoom / Focus / WB

- Replaced bottom dial-panel expansion for Zoom, Focus, and WB with a floating `CameraRulerSlider` overlay that hovers above the camera preview; ISO / Shutter / EV still use the `CameraDial` bottom panel.
- Added `hoverParam` + `onHoverParamTap` to `CameraSettingsDrawer`; floating-param chips are routed through `_kFloatingParams`, lifting state to `main.dart`. Chip highlight works for both bottom-panel (`_activeParam`) and floating-overlay (`hoverParam`) params.
- Fixed `num`→`double` cast for `withOpacity` in `CameraRulerSlider._RulerPainter`.

## 2026-03-07

### Full UI redesign — Material dark + deep blue theme

- Replaced the overlay/glass UI with a structured layout: 70 px left toolbar (`LeftToolbar`), full-area camera preview/canvas (`CanvasView`), top-right minimap (`MiniMap`), and a 36 px bottom info bar (`BottomInfoBar`), all in a solid Material dark palette with deep blue accent (`kAccent = #2979FF`).
- Added bottom `CameraSettingsDrawer` that slides up with tabbed ruler pickers (ISO, Shutter, EV, Focus, WB, Zoom). Each tab has an "A" auto toggle: ISO/Shutter share AE on/off, Focus = AF, WB = lock/unlock, EV resets to 0, Zoom resets to min. Custom `RulerPicker` widget draws a horizontal tick-ruler with center orange marker + drag-to-scroll.
- Extracted `CameraControl` to `lib/camera_control.dart`; color palette to `lib/app_theme.dart`; all new widgets in `lib/widgets/`. Added scan toggle + session timer (`_sessionSeconds`, `_sessionTimer`) and scene-state fields (`_isScanning`, `_showCanvas`, `_settingsDrawerOpen`).

### Gradle settings fix

- Restored missing `:opencv` module registration in `android/settings.gradle.kts` before assigning its `projectDir`, fixing Gradle's `Project with path ':opencv' could not be found` failure.
- Repaired a corrupted `android/app/build.gradle.kts`: restored `dependencies {}`, `externalNativeBuild`, CameraX/OpenCV wiring, Java 17 toolchain settings, and `arm64-v8a` ABI filtering.

### OpenCV Gradle module alignment

- Aligned OpenCV setup with `eva_stitching_demo` reference project: `:opencv` Gradle module registered in `settings.gradle.kts`, linked via `implementation(project(":opencv"))`.
- `CMakeLists.txt` now uses `find_package(OpenCV REQUIRED COMPONENTS java)` + `${OpenCV_LIBS}` instead of a manual `IMPORTED` target; `OpenCV_DIR` passed from `build.gradle.kts`.
- `libc++_shared.so` packaging handled automatically by the module (removed explicit `-DANDROID_STL=c++_shared`); `ndkVersion` pinned to `27.0.12077973`, `jvmTarget` bumped to `17`.

### JNI / C++ scaffolding

- Created `android/app/src/main/cpp/CMakeLists.txt` + `stitcher_jni.cpp` with `processFrame()` stub: YUV→BGR, returns mean-Y luminance (1/16-sampled).
- Created `NativeStitcher.kt` JNI bridge (`System.loadLibrary`, `external fun processFrame → Float`).
- Fixed `build.gradle.kts` (missing `dependencies {}`, added `externalNativeBuild`, `ndk { abiFilters += "arm64-v8a" }`, `cameraxVersion = "1.5.3"`).

### Manual exposure / ISO control

- Removed custom AE P-controller (EV compensation index approach) from `CameraManager.kt` and `MainActivity.kt`.
- Added `SENSOR_EXPOSURE_TIME` + `SENSOR_SENSITIVITY` raw manual control: `setExposureTimeNs`, `setIso`, `getExposureTimeRangeNs`, `getIsoRange` in Kotlin and Dart.
- Device capability ranges (`exposureTimeRangeNs`, `sensitivityIsoRange`) now stored as class fields in `CameraManager` after camera start.

### ISP quality settings

- `applyAllCaptureOptions()` now always sets `EDGE_MODE_OFF`, `NOISE_REDUCTION_MODE_FAST`, `COLOR_CORRECTION_ABERRATION_MODE_FAST`, `CONTROL_VIDEO_STABILIZATION_MODE_OFF`, `HOT_PIXEL_MODE_FAST`, `SHADING_MODE_FAST` for WSI quality.

### CameraCharacteristics dump

- Added `dumpCameraCharacteristics()` to `CameraManager.kt`: writes all key characteristics to `camera_dump.txt` in app external files dir on first camera start.

### Flutter UI

- When AE is disabled, exposure slider replaced with two sliders: exposure time (µs) and ISO. EV offset slider shown only when AE is on.
- Added `_buildVerticalSlider` `left` parameter (default 60) for side-by-side slider layout.
