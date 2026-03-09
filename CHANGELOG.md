# Changelog

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
