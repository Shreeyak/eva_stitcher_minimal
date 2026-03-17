#include <jni.h>
#include <android/log.h>
#include <memory>

#include "engine.h"

#define TAG "EvaJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, TAG, __VA_ARGS__)

// Single global Engine instance.
static std::unique_ptr<Engine> gEngine;

extern "C" {

// ── initEngine ────────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_initEngine(
    JNIEnv* env, jclass /*clazz*/,
    jint analysisW, jint analysisH, jstring cacheDir)
{
    const char* cacheDirStr = env->GetStringUTFChars(cacheDir, nullptr);
    gEngine = std::make_unique<Engine>();
    gEngine->init(static_cast<int>(analysisW), static_cast<int>(analysisH),
                  cacheDirStr ? std::string(cacheDirStr) : std::string());
    if (cacheDirStr) env->ReleaseStringUTFChars(cacheDir, cacheDirStr);
}

// ── processAnalysisFrame ──────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_processAnalysisFrame(
    JNIEnv* env, jclass /*clazz*/,
    jobject frameBuf,
    jint w, jint h, jint stride,
    jint rotation, jlong timestampNs)
{
    if (!gEngine) {
        LOGE("processAnalysisFrame called before initEngine");
        return;
    }

    auto* framePtr = static_cast<const uint8_t*>(env->GetDirectBufferAddress(frameBuf));
    if (!framePtr) {
        LOGE("processAnalysisFrame: null ByteBuffer pointer");
        return;
    }

    gEngine->processAnalysisFrame(
        framePtr,
        static_cast<int>(w), static_cast<int>(h), static_cast<int>(stride),
        static_cast<int>(rotation), static_cast<int64_t>(timestampNs));
}

// ── getNavigationState ────────────────────────────────────────────────────

JNIEXPORT jfloatArray JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_getNavigationState(
    JNIEnv* env, jclass /*clazz*/)
{
    jfloatArray result = env->NewFloatArray(NAV_STATE_SIZE);
    if (!result) return nullptr;

    float buf[NAV_STATE_SIZE] = {};
    if (gEngine) {
        gEngine->getNavigationState(buf);
    }

    env->SetFloatArrayRegion(result, 0, NAV_STATE_SIZE, buf);
    return result;
}

// ── getCanvasPreview ──────────────────────────────────────────────────────

JNIEXPORT jbyteArray JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_getCanvasPreview(
    JNIEnv* env, jclass /*clazz*/,
    jint maxDim)
{
    if (!gEngine) return nullptr;

    std::vector<uint8_t> jpeg = gEngine->getCanvasPreview(static_cast<int>(maxDim));
    if (jpeg.empty()) return nullptr;

    jbyteArray result = env->NewByteArray(static_cast<jsize>(jpeg.size()));
    if (!result) return nullptr;

    env->SetByteArrayRegion(result, 0, static_cast<jsize>(jpeg.size()),
                            reinterpret_cast<const jbyte*>(jpeg.data()));
    return result;
}

// ── resetEngine ──────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_resetEngine(
    JNIEnv* /*env*/, jclass /*clazz*/)
{
    if (gEngine) gEngine->reset();
}

// ── startScanning ─────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_startScanning(
    JNIEnv* /*env*/, jclass /*clazz*/)
{
    if (gEngine) gEngine->startScanning();
}

// ── stopScanning ──────────────────────────────────────────────────────────

JNIEXPORT void JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_stopScanning(
    JNIEnv* /*env*/, jclass /*clazz*/)
{
    if (gEngine) gEngine->stopScanning();
}

// ── saveCanvasToDisk ──────────────────────────────────────────────────────

JNIEXPORT jint JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_saveCanvasToDisk(
    JNIEnv* env, jclass /*clazz*/,
    jstring outputDir)
{
    if (!gEngine) {
        LOGE("saveCanvasToDisk called before initEngine");
        return -1;
    }

    const char* outputDirStr = env->GetStringUTFChars(outputDir, nullptr);
    int status = gEngine->saveCanvasToDisk(outputDirStr ? std::string(outputDirStr) : std::string());
    if (outputDirStr) env->ReleaseStringUTFChars(outputDir, outputDirStr);

    return status;
}

// ── saveCanvasAsImage ─────────────────────────────────────────────────────

JNIEXPORT jint JNICALL
Java_com_example_eva_1minimal_1demo_NativeStitcher_saveCanvasAsImage(
    JNIEnv* env, jclass /*clazz*/,
    jstring outputPath)
{
    if (!gEngine) {
        LOGE("saveCanvasAsImage called before initEngine");
        return -1;
    }

    const char* pathStr = env->GetStringUTFChars(outputPath, nullptr);
    int status = gEngine->saveCanvasAsImage(pathStr ? std::string(pathStr) : std::string());
    if (pathStr) env->ReleaseStringUTFChars(outputPath, pathStr);

    return status;
}

} // extern "C"
