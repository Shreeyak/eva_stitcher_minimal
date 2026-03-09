typedef LatestValueErrorHandler<T> =
    void Function(Object error, T? lastApplied);

/// Serializes async sends while keeping only the latest pending value.
///
/// UI can call [update] rapidly (e.g. slider scrubs). The sender guarantees
/// there is at most one [send] call in flight and drops intermediate values.
class LatestValueSender<T extends Object> {
  LatestValueSender({required this.send, this.onError});

  final Future<void> Function(T value) send;
  final LatestValueErrorHandler<T>? onError;

  T? _pending;
  T? _lastApplied;
  bool _running = false;

  T? get lastApplied => _lastApplied;

  set lastApplied(T? value) {
    _lastApplied = value;
  }

  void update(T value) {
    _pending = value;
    if (_running) return;
    _process();
  }

  void cancel() {
    _pending = null;
  }

  Future<void> _process() async {
    _running = true;
    try {
      while (_pending != null) {
        final value = _pending;
        _pending = null;
        if (value == null) continue;

        try {
          await send(value);
          _lastApplied = value;
        } catch (error) {
          _pending = null;
          onError?.call(error, _lastApplied);
          return;
        }
      }
    } finally {
      _running = false;
    }
  }
}
