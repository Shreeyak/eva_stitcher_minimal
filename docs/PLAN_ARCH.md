# Plan - Minimal Implementation for  Whole Slide Imaging

We are creating an android app for whole slide imaging. It needs to take in images from the device camera,
warp and blend them onto a canvas as they arrive and construct an image of the full slide.

## Requirements

We are implementing incremental image stitching. Here are some of the requirements.

1. Constructed image should prioritize quality while staying within 5fps.
2. We are implementing an incremental stitcher. Meaning that we cannot do global bundle adjustment.
We get images one by one and they must be stitched on.
3. Must use android cameraX or camera2 package to access the device camera.
4. Must display the image on the device screen as it is being updated with new frames.
5. Must display the current frame
6. Must display some diagnostic to the user if the tracking is good, bad, lost tracking.
It will allow the user to adjust.
7. Must minimize visible seams effectively. But prioritize speed if required.
8. The camera preview must not lag. Othewise the user will lose track of where they are.
9. Focus on a clean, minimal, modular architecture. Keep it simple.

## Technical specifications

1. Camera settings: resolution: 3120x2160 or approx 4000x3000px, Zoom: 1x.
2. Crop a region of 768px from the center. This should be stitched onto the canvas.
3. Must have buttons to toggle auto focus, auto white balance, auto exposure.
4. Must also have the ability to set focus level, exposure offset and calibrate white balance on user tap. Locked exposure, white balance and focus are very important to get good quality images.
5. Use cameraX to get frames in native Kotlin. Use camera2 interop to access low level features.
6. Use C++ OpenCV where possible. It is optimized.
7. Apart from blending, pixels written to canvas never change

### Camera setup

1. Setup Image Analysis, Camera Preview and Image Capture. Preview is displayed to user, image analysis is used to perform computer vision operations and image capture is used to capture high quality image for stitching.
2. Use CaptureRequest.SENSOR_EXPOSURE_TIME = 1_000_000L if available
3. Capture image with [OnImageCapturedCallback](https://developer.android.com/reference/androidx/camera/core/ImageCapture#takePicture(java.util.concurrent.Executor,%20androidx.camera.core.ImageCapture.OnImageCapturedCallback)), and [CAPTURE_MODE_MINIMIZE_LATENCY](https://developer.android.com/reference/androidx/camera/core/ImageCapture#CAPTURE_MODE_MINIMIZE_LATENCY()) to quickly get data directly into a buffer.
4. Set resolution to 3120x2160 or higher.

### The algorthms

**Evaluate Frames (Optional)**:

- Reject a frame if it is too blurry. Many options available. We can use tracked optical flow markers, motion threshold, sharpness detector, etc.

**Estimate transform**:

- Assume translation and rotation only. You may downsample image just for tracking.
- Use sparse optical flow (example, Lucas-Kanade) to track camera movement and get estimated transform.
- Try FAST detector + BRIEF descriptor (might not need it if ECC is good enough. Run it on each quadrant of input image)
- Use sliding window Bundle Adjustment, keeping all frames expect latest frozen.
- Use two-stage pyramidical ECC (Enhanced Correlation Coefficient) to fine-tune the transform to sub-pixel accuracy.

**Warp image**:

- Use similarity transform to warp image onto the canvas.(translation + rotation)
- Assume planar surface

**Blend image**:

- For full speed, don't blend.
- Experiment with Weighted average for tiles.

### Data Flow

- Use methods such as Surfaces, Textures, ByteArray, etc to minimize copy of data.
- Kotlin (cameraX Frame) -> JNI -> C++ OpenCV (Stitched Canvas) -> JNI -> Kotlin -> Dart -> UI Display

### References

- [CameraX on Flutter](https://github.com/Shreeyak/cameraX-demo-flutter) - Demonstrates how to access cameraX, use camera2 interop to access low level features and how to integrate with flutter.
- Documents in this repository in docs/.
