# GPU→CPU Camera Frame Readback

This package implements two methods for capturing full-resolution camera frames on the CPU for ML inference, without using ImageAnalysis.

## Files

- **GpuToCpuSurfaceProvider.kt** - Method 2: Custom GL EGL pipeline with double-buffered PBOs
- **TextureViewBitmapCapture.kt** - Method 1: Synchronous `getBitmap()` readback
- **CameraReadbackTestActivity.kt** - Demo activity with both methods

## Usage

### Quick Start

Toggle between methods by changing `USE_GL_METHOD` in `CameraReadbackTestActivity.kt`:

```kotlin
private const val USE_GL_METHOD = false  // false = Method 1, true = Method 2
```

### Method 1: TextureViewBitmapCapture

**Pros:**
- Simplest integration
- Works with existing PreviewView layouts
- No custom shaders or GL code

**Cons:**
- Synchronous GPU stall (30-120ms per frame at 4000×3000)
- Caps at ~6fps to avoid preview stutters

**Integration:**
```kotlin
// Set BEFORE binding camera
previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE

// AFTER binding camera
val capture = TextureViewBitmapCapture(
    previewView = previewView,
    captureWidth = 4000,
    captureHeight = 3000,
    targetFps = 3f,
    callback = object : TextureViewBitmapCapture.FrameCallback {
        override fun onFrameReady(bitmap: Bitmap, profile: CaptureProfile) {
            // Process bitmap (ARGB_8888)
        }
    }
)
capture.start()
```

### Method 2: GpuToCpuSurfaceProvider

**Pros:**
- Zero GPU stall in steady state
- Asynchronous readback via PBOs
- Can hit 30fps if needed

**Cons:**
- One frame of latency (always reading previous frame's PBO)
- Requires SurfaceView (not PreviewView)
- More complex setup

**Integration:**
```kotlin
surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
    override fun surfaceCreated(holder: SurfaceHolder) {
        glSurfaceProvider = GpuToCpuSurfaceProvider(
            displaySurface = holder.surface,
            displayWidth = surfaceView.width,
            displayHeight = surfaceView.height,
            cameraWidth = 4000,
            cameraHeight = 3000,
            targetReadbackFps = 3f,
            callback = object : FrameCallback {
                override fun onFrameReady(buffer: ByteBuffer, profile: GlFrameProfile) {
                    // Process buffer (RGBA, bottom-left row order)
                    // Buffer only valid during this call - copy if needed
                }
            }
        )
        preview.setSurfaceProvider(glSurfaceProvider!!)
    }
})
```

## Performance Metrics

Both methods provide detailed profiling:

- **Method 1**: `CaptureProfile` with `getBitmapMs`, `totalReadbackMs`, `endToEndFps`
- **Method 2**: `GlFrameProfile` with `oesUpdateMs`, `displayRenderMs`, `fboRenderMs`, `glReadMs`, `glMapMs`, `achievedPreviewFps`, `achievedReadbackFps`

## Testing

Run `CameraReadbackTestActivity` to see either method in action. The profiling overlay updates every second with performance metrics.

## Requirements

- Android API 29+ (scoped storage)
- OpenGL ES 3.0 (for Method 2)
- CameraX 1.5.3+
- Target resolution: 4000×3000 @ 3fps

## Notes

- Both methods pre-allocate buffers (no per-frame allocations)
- Method 1 delivers Bitmap (ARGB_8888)
- Method 2 delivers ByteBuffer (RGBA, bottom-left origin)
- See full documentation in each file's header comments
