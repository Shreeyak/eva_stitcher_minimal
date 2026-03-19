# GPU→CPU Camera Frame Readback for ML Inference

Two independently toggleable methods for capturing full-resolution camera frames on the CPU without `ImageAnalysis`. Both are contained in the `readback/` package under the app module.

---

## Quick start

### 1. Launch the activity

`FrameReadbackActivity` is registered in `AndroidManifest.xml`. Launch it from any context:

```kotlin
startActivity(Intent(this, FrameReadbackActivity::class.java))
```

Or add a launcher intent-filter if you want it as the entry point during development:

```xml
<!-- AndroidManifest.xml -->
<activity android:name=".readback.FrameReadbackActivity">
    <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
    </intent-filter>
</activity>
```

### 2. Choose a method

Open `FrameReadbackActivity.kt` and set the compile-time flag at the top of the companion object:

```kotlin
const val USE_GL_METHOD: Boolean = false   // Method 1 — TextureView getBitmap()
const val USE_GL_METHOD: Boolean = true    // Method 2 — EGL + double-buffered PBOs
```

### 3. Wire up your inference

Replace the stub at the bottom of `FrameReadbackActivity`:

```kotlin
fun runMlInference(data: Any, width: Int, height: Int) {
    // TODO: replace with real model
}
```

See the per-method sections below for what `data` is and how to consume it safely.

---

## Method 1 — `TextureViewBitmapCapture` (simpler, lower overhead)

**File:** `readback/TextureViewBitmapCapture.kt`

### How it works

1. `PreviewView` is forced into `COMPATIBLE` mode, which uses a `TextureView` backend.
2. A dedicated `HandlerThread` calls `PreviewView.getBitmap()` at up to `targetFps`.
3. The raw preview bitmap is scaled into a single pre-allocated output `Bitmap` — no per-frame GC pressure.

### Usage

```kotlin
// Must be called AFTER CameraX is bound and the preview surface is live.
val capture = TextureViewBitmapCapture(
    previewView  = previewView,
    captureWidth  = 4000,    // output resolution (can differ from preview size)
    captureHeight = 3000,
    targetFps     = 3f,
    callback      = object : TextureViewBitmapCapture.FrameCallback {
        override fun onFrameReady(bitmap: Bitmap, profile: TextureViewBitmapCapture.CaptureProfile) {
            // bitmap is the same pre-allocated instance every call — do NOT recycle it.
            runMlInference(bitmap, bitmap.width, bitmap.height)
            Log.d("MyApp", profile.summary())
        }
    }
)

// In onDestroy / onDestroyView:
capture.stop()
```

### Caveats

| Issue | Detail |
|---|---|
| Instantiation timing | Must be created **after** `cameraProvider.bindToLifecycle()`; before that, `getBitmap()` always returns `null`. |
| Blocking call | `getBitmap()` blocks 10–40 ms while the GL pipeline copies the frame. Keep the callback fast or dispatch to a background thread. |
| COMPATIBLE mode | Disables hardware surface transforms — the preview may not auto-rotate on orientation change. |
| Output bitmap | Always the same object; do not call `bitmap.recycle()` in the callback. |

---

## Method 2 — `GpuToCpuSurfaceProvider` (lower latency, GLES 3.0)

**File:** `readback/GpuToCpuSurfaceProvider.kt`

### How it works

1. Implements `Preview.SurfaceProvider` — CameraX delivers frames via an OES texture.
2. A dedicated GL thread owns an EGL 1.4 context with a window surface (renders preview) and a pbuffer surface (used during teardown).
3. Each frame is drawn from the OES texture through a GLSL shader into an FBO at `cameraWidth × cameraHeight`.
4. Two PBOs are double-buffered:
   - Frame N: `glReadPixels` into `PBO[N%2]` (async — returns immediately).
   - Frame N+1: map `PBO[(N-1)%2]` → deliver via `FrameCallback`, then start the next async read.
5. `FrameCallback.onFrameReady` fires at up to `targetReadbackFps` Hz.

### Usage

```kotlin
// Use SurfaceView (not PreviewView) for the display surface.
val surfaceView = findViewById<SurfaceView>(R.id.surfaceView)

surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
        val provider = GpuToCpuSurfaceProvider(
            displaySurface     = holder.surface,
            displayWidth       = surfaceView.width,
            displayHeight      = surfaceView.height,
            cameraWidth        = 4208,
            cameraHeight       = 3120,
            targetReadbackFps  = 3f,
            frameCallback      = object : GpuToCpuSurfaceProvider.FrameCallback {
                override fun onFrameReady(
                    buffer: ByteBuffer,
                    width: Int,
                    height: Int,
                    profile: GpuToCpuSurfaceProvider.ReadbackProfile,
                ) {
                    // ⚠ buffer is a mapped PBO slice — INVALID after this function returns.
                    // Copy it before dispatching to a slow worker:
                    val copy = ByteBuffer.allocateDirect(buffer.remaining())
                    copy.put(buffer); copy.flip()

                    executor.execute { runMlInference(copy, width, height) }
                }
            },
        )
        glSurfaceProvider = provider

        // Bind CameraX INSIDE surfaceCreated — NOT in onCreate.
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            val preview = Preview.Builder().build().also { it.setSurfaceProvider(provider) }
            future.get().bindToLifecycle(this@MyActivity, CameraSelector.DEFAULT_BACK_CAMERA, preview)
        }, ContextCompat.getMainExecutor(context))
    }

    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) = Unit

    override fun surfaceDestroyed(holder: SurfaceHolder) {
        glSurfaceProvider?.release()
        glSurfaceProvider = null
    }
})

// Also call release in onDestroy as a safety net:
override fun onDestroy() {
    super.onDestroy()
    glSurfaceProvider?.release()
}
```

### Pixel format

Frames are **RGBA, bottom-left row order** (standard OpenGL convention). If your model expects top-left (most common), flip the rows before inference:

```kotlin
// In-place vertical flip of an RGBA ByteBuffer (width × height × 4 bytes)
fun flipVertically(buf: ByteBuffer, width: Int, height: Int) {
    val rowBytes = width * 4
    val tmp = ByteArray(rowBytes)
    val arr = ByteArray(buf.remaining()).also { buf.get(it); buf.rewind() }
    for (y in 0 until height / 2) {
        val top = y * rowBytes
        val bot = (height - 1 - y) * rowBytes
        System.arraycopy(arr, top, tmp, 0, rowBytes)
        System.arraycopy(arr, bot, arr, top, rowBytes)
        System.arraycopy(tmp, 0, arr, bot, rowBytes)
    }
    buf.put(arr); buf.rewind()
}
```

### Caveats

| Issue | Detail |
|---|---|
| GLES 3.0 required | Declared in `AndroidManifest.xml`. PBOs are a GLES 3.0 feature. |
| Bind camera in `surfaceCreated` | The EGL window surface is constructed from the `SurfaceHolder` — the surface must exist before CameraX is bound. |
| PBO buffer lifetime | The `ByteBuffer` passed to `onFrameReady` is a mapped GPU buffer. It becomes **invalid** the moment the callback returns. Copy it immediately if inference takes more than ~100 ms. |
| `release()` idempotency | `release()` is safe to call multiple times. Call it in both `surfaceDestroyed` and `onDestroy`. |
| Resolution mismatch | `cameraWidth/cameraHeight` is the FBO and readback resolution. `displayWidth/displayHeight` is the preview window — the preview is letter/pillar-boxed to fit. |

---

## Choosing between methods

| | Method 1 (TextureView) | Method 2 (EGL/PBO) |
|---|---|---|
| Setup complexity | Low | Medium |
| GLES requirement | None | GLES 3.0 |
| Readback latency | 10–40 ms (blocking) | ~1 frame behind (async) |
| Memory | One pre-allocated `Bitmap` | Two PBOs on GPU + one mapped slice |
| Output format | `Bitmap` (ARGB_8888) | `ByteBuffer` (RGBA, bottom-left) |
| Preview display | Via `PreviewView` | Via EGL window surface on `SurfaceView` |
| Orientation handling | Manual (COMPATIBLE mode) | Manual (OES texture matrix applied) |

For most use cases at ≤5 fps readback, Method 1 is simpler and sufficient. Use Method 2 if you need to avoid blocking the preview pipeline or require the lowest possible capture-to-inference latency.
