cmake_minimum_required(VERSION 3.22.1)

project(eva_stitcher VERSION 1.0)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# 16KB page size alignment for Android 15+ compatibility
set(CMAKE_SHARED_LINKER_FLAGS "${CMAKE_SHARED_LINKER_FLAGS} -Wl,-z,max-page-size=16384")

# OpenCV_DIR is passed from build.gradle.kts via -DOpenCV_DIR
# Points to: android/opencv/sdk/native/jni (contains OpenCVConfig.cmake)
find_package(OpenCV REQUIRED COMPONENTS java)

# ── System libraries ─────────────────────────────────────────────────────────
find_library(log-lib log)

# ── Our JNI shared library ───────────────────────────────────────────────────
add_library(
    eva_stitcher
    SHARED
    stitcher_jni.cpp
)

target_include_directories(eva_stitcher PRIVATE
    ${OpenCV_INCLUDE_DIRS}
)

target_compile_options(eva_stitcher PRIVATE
    -O2
    -Wall
    -Wextra
)

target_link_libraries(eva_stitcher
    ${OpenCV_LIBS}
    ${log-lib}
    android
)
