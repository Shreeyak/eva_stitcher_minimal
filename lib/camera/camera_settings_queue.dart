import 'dart:async';

enum CameraSettingKey { af, focus, iso, shutter, zoom, wb }

typedef CameraSettingsQueueErrorHandler =
    void Function(CameraSettingKey key, Object error);

/// Serializes camera-setting writes while keeping only the latest pending value
/// for each setting key.
///
/// This prevents piling up native calls during rapid slider scrubs and avoids
/// interleaved Camera2 capture-option updates.
class CameraSettingsQueue {
  CameraSettingsQueue({
    required Future<void> Function(bool enabled) sendAf,
    required Future<void> Function(double distance) sendFocus,
    required Future<void> Function(int iso) sendIso,
    required Future<void> Function(int shutterNs) sendShutter,
    required Future<void> Function(double ratio) sendZoom,
    required Future<void> Function(bool locked) sendWbLock,
    required bool initialAfEnabled,
    this.onError,
  }) : _sendAf = sendAf,
       _sendFocus = sendFocus,
       _sendIso = sendIso,
       _sendShutter = sendShutter,
       _sendZoom = sendZoom,
       _sendWbLock = sendWbLock,
       _effectiveAfEnabled = initialAfEnabled;

  final Future<void> Function(bool enabled) _sendAf;
  final Future<void> Function(double distance) _sendFocus;
  final Future<void> Function(int iso) _sendIso;
  final Future<void> Function(int shutterNs) _sendShutter;
  final Future<void> Function(double ratio) _sendZoom;
  final Future<void> Function(bool locked) _sendWbLock;
  final CameraSettingsQueueErrorHandler? onError;

  bool _running = false;

  bool? _pendingAf;
  double? _pendingFocus;
  int? _pendingIso;
  int? _pendingShutter;
  double? _pendingZoom;
  bool? _pendingWbLock;

  bool _effectiveAfEnabled;

  bool get effectiveAfEnabled => _effectiveAfEnabled;

  void seedAppliedState({required bool afEnabled}) {
    _effectiveAfEnabled = afEnabled;
    _pendingFocus = null;
    _pendingIso = null;
    _pendingShutter = null;
    _pendingZoom = null;
    _pendingWbLock = null;
    _pendingAf = null;
  }

  void updateAf(bool enabled) {
    _pendingAf = enabled;
    if (enabled) {
      // AF ON wins over pending manual-focus writes.
      _pendingFocus = null;
    }
    _kick();
  }

  void updateFocus(double distance) {
    _pendingFocus = distance;
    _kick();
  }

  void updateIso(int iso) {
    _pendingIso = iso;
    _kick();
  }

  void updateShutter(int shutterNs) {
    _pendingShutter = shutterNs;
    _kick();
  }

  void updateZoom(double ratio) {
    _pendingZoom = ratio;
    _kick();
  }

  void updateWbLock(bool locked) {
    _pendingWbLock = locked;
    _kick();
  }

  void cancel() {
    _pendingAf = null;
    _pendingFocus = null;
    _pendingIso = null;
    _pendingShutter = null;
    _pendingZoom = null;
    _pendingWbLock = null;
  }

  bool get _hasPending =>
      _pendingAf != null ||
      _pendingFocus != null ||
      _pendingIso != null ||
      _pendingShutter != null ||
      _pendingZoom != null ||
      _pendingWbLock != null;

  void _kick() {
    if (_running) return;
    unawaited(_drain());
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (_hasPending) {
        if (_pendingAf != null) {
          final target = _pendingAf!;
          _pendingAf = null;
          final ok = await _run(CameraSettingKey.af, () => _sendAf(target));
          if (ok) _effectiveAfEnabled = target;
          continue;
        }

        if (_pendingFocus != null) {
          if (_effectiveAfEnabled) {
            final ok = await _run(CameraSettingKey.af, () => _sendAf(false));
            if (!ok) {
              // If AF cannot be disabled, drop pending manual focus and move on.
              _pendingFocus = null;
              continue;
            }
            _effectiveAfEnabled = false;
            continue;
          }

          final distance = _pendingFocus!;
          _pendingFocus = null;
          await _run(CameraSettingKey.focus, () => _sendFocus(distance));
          continue;
        }

        if (_pendingIso != null) {
          final iso = _pendingIso!;
          _pendingIso = null;
          await _run(CameraSettingKey.iso, () => _sendIso(iso));
          continue;
        }

        if (_pendingShutter != null) {
          final shutterNs = _pendingShutter!;
          _pendingShutter = null;
          await _run(CameraSettingKey.shutter, () => _sendShutter(shutterNs));
          continue;
        }

        if (_pendingZoom != null) {
          final ratio = _pendingZoom!;
          _pendingZoom = null;
          await _run(CameraSettingKey.zoom, () => _sendZoom(ratio));
          continue;
        }

        if (_pendingWbLock != null) {
          final locked = _pendingWbLock!;
          _pendingWbLock = null;
          await _run(CameraSettingKey.wb, () => _sendWbLock(locked));
          continue;
        }
      }
    } finally {
      _running = false;
      if (_hasPending) _kick();
    }
  }

  Future<bool> _run(
    CameraSettingKey key,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      return true;
    } catch (error) {
      onError?.call(key, error);
      return false;
    }
  }
}
