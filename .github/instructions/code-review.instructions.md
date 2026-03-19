---
description: "Code review instructions for the eva_minimal_demo Flutter/Kotlin/C++ WSI camera stitching app"
applyTo: "**"
excludeAgent: ["coding-agent"]
---

# Code Review Instructions — eva_minimal_demo

Code review guidelines for the eva_minimal_demo whole slide imaging (WSI) app: a three-layer system (Flutter UI → Kotlin CameraX → C++ OpenCV stitching). Reviews cover correctness, architecture invariants, security, and performance across all three layers.

## Review Language

When performing a code review, respond in **English**.

## Review Priorities

When performing a code review, prioritize issues in the following order:

### 🔴 CRITICAL (Block merge)

- **Security**: Vulnerabilities, exposed secrets, authentication/authorization issues
- **Correctness**: Logic errors, data corruption risks, race conditions
- **Breaking Changes**: API contract changes without versioning
- **Data Loss**: Risk of data loss or corruption

### 🟡 IMPORTANT (Requires discussion)

- **Code Quality**: Severe violations of SOLID principles, excessive duplication
- **Test Coverage**: Missing tests for critical paths or new functionality
- **Performance**: Obvious performance bottlenecks (N+1 queries, memory leaks)
- **Architecture**: Significant deviations from established patterns

### 🟢 SUGGESTION (Non-blocking improvements)

- **Readability**: Poor naming, complex logic that could be simplified
- **Optimization**: Performance improvements without functional impact
- **Best Practices**: Minor deviations from conventions
- **Documentation**: Missing or incomplete comments/documentation

## General Review Principles

When performing a code review, follow these principles:

1. **Be specific**: Reference exact lines, files, and provide concrete examples
2. **Provide context**: Explain WHY something is an issue and the potential impact
3. **Suggest solutions**: Show corrected code when applicable, not just what's wrong
4. **Be constructive**: Focus on improving the code, not criticizing the author
5. **Recognize good practices**: Acknowledge well-written code and smart solutions
6. **Be pragmatic**: Not every suggestion needs immediate implementation
7. **Group related comments**: Avoid multiple comments about the same topic

## Code Quality Standards

When performing a code review, check for:

### Clean Code

- Descriptive and meaningful names for variables, functions, and classes
- Single Responsibility Principle: each function/class does one thing well
- DRY (Don't Repeat Yourself): no code duplication
- Functions should be small and focused (ideally < 20-30 lines)
- Avoid deeply nested code (max 3-4 levels)
- Avoid magic numbers and strings (use constants)
- Code should be self-documenting; comments only when necessary

### Error Handling

- Proper error handling at appropriate levels
- Meaningful error messages
- No silent failures or ignored exceptions
- Fail fast: validate inputs early
- Use appropriate error types/exceptions

## Security Review

When performing a code review, check for security issues:

- **Sensitive Data**: No passwords, API keys, tokens, or PII in code or logs
- **Input Validation**: All user inputs are validated and sanitized
- **Authentication**: Proper authentication checks before accessing resources
- **Cryptography**: Use established libraries, never roll your own crypto
- **Dependency Security**: Check for known vulnerabilities in dependencies
- **Camera Data**: Raw frame data and captured images must not be leaked to unintended destinations

## Testing Standards

When performing a code review, verify test quality:

- **Coverage**: Critical paths and new functionality must have tests
- **Test Names**: Descriptive names that explain what is being tested
- **Test Structure**: Clear Arrange-Act-Assert or Given-When-Then pattern
- **Independence**: Tests should not depend on each other or external state
- **Assertions**: Use specific assertions, avoid generic assertTrue/assertFalse
- **Edge Cases**: Test boundary conditions, null values, empty collections
- **Mock Appropriately**: Mock external dependencies, not domain logic

## Performance Considerations

When performing a code review, check for performance issues:

- **Algorithms**: Appropriate time/space complexity for the use case
- **Caching**: Utilize caching for expensive or repeated operations
- **Resource Management**: Proper cleanup of connections, files, streams
- **Lazy Loading**: Load data only when needed

## Architecture and Design

When performing a code review, verify architectural principles:

- **Separation of Concerns**: Clear boundaries between layers/modules
- **Dependency Direction**: High-level modules don't depend on low-level details
- **Interface Segregation**: Prefer small, focused interfaces
- **Loose Coupling**: Components should be independently testable
- **High Cohesion**: Related functionality grouped together
- **Consistent Patterns**: Follow established patterns in the codebase

## Project-Specific Architecture Rules

### Flutter / Dart Layer (`lib/`)

- **State management**: Use `StatefulWidget` + `setState`. Never introduce Provider, Riverpod, or Bloc. `ValueNotifier` is acceptable only for cross-widget state.
- **Widget structure**: One widget per file in `lib/widgets/`. Prefer `StatelessWidget`; use `StatefulWidget` only when local mutable state is needed. Files must stay ≤ 300 lines.
- **Data flow**: Pass callbacks down explicitly. No global state singletons.
- **Theme**: Use `Theme.of(context).colorScheme` for all colours — never hardcode hex values. Use Material 3 components (`FilterChip`, `SegmentedButton`, etc.).
- **Camera state**: Camera data classes live in `camera_state.dart`. Channel writes go through `CameraControl` → `CameraSettingsQueue` — never call MethodChannel directly from UI code.

### Kotlin / Android Layer (`android/app/src/main/kotlin/…`)

- **Camera encapsulation**: All CameraX and Camera2 logic must stay in `CameraManager.kt`. Do not scatter camera state or logic into `MainActivity.kt` or other files.
- **New commands**: New `MethodChannel` commands are wired in `MainActivity.kt`'s `when` block but implemented in `CameraManager.kt`.
- **Settings writes**: Every manual camera override **must** go through `applyAllCaptureOptions()`. Never call `setCaptureRequestOptions` for individual settings — it cancels prior pending futures and causes races.
- **Sequential writes**: Camera2 `setCaptureRequestOptions` calls must be sequential (one at a time). Never use `Future.wait` / `awaitAll` for capture option writes.
- **WB lock**: Lock white balance by capturing live CCM + gains while AWB is in auto mode, then replaying on lock. Do not hardcode WB gains.
- **Processor registration**: `EvaCameraPlugin.set*Processor()` calls must come **before** `super.configureFlutterEngine()` in `MainActivity`. Calling them after `super()` leaves `CameraManager` with null processors.

### C++ / OpenCV Layer (`android/app/src/main/cpp/`, `native/stitcher/`)

- **Source location**: New JNI source files belong in `android/app/src/main/cpp/`; stitcher logic belongs in `native/stitcher/`. Wire via `externalNativeBuild` in `android/app/build.gradle.kts`.
- **API choice**: Use the OpenCV C++ API only. Never use Java/Kotlin OpenCV bindings — the native library is at `android/opencv/`.
- **No GPU**: `cv::cuda::`, `cv::ocl::`, and any OpenCL calls are forbidden. OpenCV is CPU-only in this project.
- **Memory discipline**: Prefer in-place operations and pre-allocated buffers in per-frame paths. Avoid heap allocations inside the analysis/stitch callbacks.
- **Lock ordering**: Acquire `Canvas::_canvasMutex` before `Engine::_stateMutex`. Never hold `_stateMutex` while calling `getBounds`, `compositeFrame`, or `renderPreview`.
- **Frame format**: Analysis frames arrive as YUV `ImageProxy` (640×480). Canvas tiles use `CV_8UC3` BGR + `CV_8UC1` mask. No BGRA in the tile grid.
- **Orientation**: Canvas frames require 180° rotation (`cv::ROTATE_180`) to match display orientation.

## Documentation Standards

When performing a code review, check documentation:

- **API Documentation**: Public APIs must be documented (purpose, parameters, returns)
- **Complex Logic**: Non-obvious logic should have explanatory comments
- **README Updates**: Update README when adding features or changing setup
- **Breaking Changes**: Document any breaking changes clearly
- **Examples**: Provide usage examples for complex features

## Comment Format Template

When performing a code review, use this format for comments:

```markdown
**[PRIORITY] Category: Brief title**

Detailed description of the issue or suggestion.

**Why this matters:**
Explanation of the impact or reason for the suggestion.

**Suggested fix:**
[code example if applicable]

**Reference:** [link to relevant documentation or standard]
```

## Review Checklist

When performing a code review, systematically verify:

### Code Quality

- [ ] Code follows consistent style and conventions
- [ ] Names are descriptive and follow naming conventions
- [ ] Functions/methods are small and focused
- [ ] No code duplication
- [ ] Complex logic is broken into simpler parts
- [ ] Error handling is appropriate
- [ ] No commented-out code or TODO without tickets

### Security

- [ ] No sensitive data in code or logs
- [ ] Input validation on all user inputs
- [ ] Authentication and authorization properly implemented
- [ ] Dependencies are up-to-date and secure
- [ ] Camera frame data not leaked to unintended destinations

### Testing

- [ ] New code has appropriate test coverage
- [ ] Tests are well-named and focused
- [ ] Tests cover edge cases and error scenarios
- [ ] Tests are independent and deterministic
- [ ] No tests that always pass or are commented out

### Performance

- [ ] No obvious performance issues (N+1, memory leaks)
- [ ] Appropriate use of caching
- [ ] Efficient algorithms and data structures
- [ ] Proper resource cleanup

### Architecture

- [ ] Follows established patterns and conventions
- [ ] Proper separation of concerns
- [ ] No architectural violations
- [ ] Dependencies flow in correct direction
- [ ] Flutter: no global state; callbacks passed down explicitly
- [ ] Flutter: no hardcoded colours; `Theme.of(context).colorScheme` used
- [ ] Flutter: no Provider/Riverpod/Bloc introduced
- [ ] Kotlin: all camera logic in `CameraManager.kt`; `MainActivity.kt` only wires channels
- [ ] Kotlin: all camera setting writes go through `applyAllCaptureOptions()`
- [ ] Kotlin: no concurrent `setCaptureRequestOptions` calls (`Future.wait` forbidden)
- [ ] Kotlin: processor `set*Processor()` calls placed before `super.configureFlutterEngine()`
- [ ] C++: no `cv::cuda::` / `cv::ocl::` / OpenCL usage
- [ ] C++: no per-frame heap allocations in hot paths
- [ ] C++: lock ordering respected (`_canvasMutex` before `_stateMutex`)
- [ ] CHANGELOG.md updated when a feature, algorithm, or implementation is added/modified/deleted

### Documentation

- [ ] Public APIs are documented
- [ ] Complex logic has explanatory comments
- [ ] README is updated if needed
- [ ] Breaking changes are documented

## Project Context

- **Tech Stack**: Flutter (Dart), Kotlin (CameraX + Camera2), C++ / OpenCV
- **Architecture**: Three-layer — Flutter UI (`lib/`) → Kotlin camera (`android/…/CameraManager.kt`) → C++ stitching (`native/stitcher/`, `android/app/src/main/cpp/`)
- **Build Tool**: Flutter CLI, Gradle 8.12, AGP 8.9.x, NDK 27, C++17, `arm64-v8a` only, Java 17
- **Testing**: `flutter test`, `flutter analyze`, `flutter build apk --debug`
- **Code Style**: Minimal abstractions; plain `StatefulWidget` + `setState`; one widget per file ≤ 300 lines; Material 3 dark theme
- **Channel names**: `PlatformView "camerax-preview"`, `MethodChannel "com.example.eva/control"`, `EventChannel "com.example.eva/events"`
- **Key invariants**: All camera settings via `applyAllCaptureOptions()`; all camera logic in `CameraManager.kt`; sequential Camera2 writes only; CPU-only OpenCV; CHANGELOG.md updated on every feature change
