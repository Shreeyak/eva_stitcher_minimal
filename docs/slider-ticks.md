# Goal: a reusable production-style camera dial usable for zoom, focus, ISO, shutter with:

- uniform tick spacing
- magnetic snapping
- haptic feedback
- <0.2 ms paint cost
- flexible value mapping (linear/log/custom)

Key architectural principle: angle is linear, value mapping is separate.

# Dial configuration model

Each dial defines its own behavior.

```dart
class DialConfig {
  final double min;
  final double max;

  final int ticks;
  final int majorTickEvery;

  final bool logarithmic;

  const DialConfig({
    required this.min,
    required this.max,
    this.ticks = 120,
    this.majorTickEvery = 10,
    this.logarithmic = false,
  });

  double percentToValue(double p) {
    if (!logarithmic) {
      return min + p * (max - min);
    }

    return min * pow(max / min, p);
  }

  double valueToPercent(double v) {
    if (!logarithmic) {
      return (v - min) / (max - min);
    }

    return log(v / min) / log(max / min);
  }
}
```


# 2. Dial widget

Handles gestures + snapping.

```dart
class CameraDial extends StatefulWidget {
  final DialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  const CameraDial({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<CameraDial> createState() => _CameraDialState();
}

class _CameraDialState extends State<CameraDial> {
  late double percent;

  final startAngle = pi;
  final sweepAngle = pi;

  @override
  void initState() {
    super.initState();
    percent = widget.config.valueToPercent(widget.initialValue);
  }

  void updateFromAngle(double angle) {
    double p = (angle - startAngle) / sweepAngle;
    p = p.clamp(0.0, 1.0);

    p = snapToTicks(p);

    setState(() {
      percent = p;
    });

    widget.onChanged(widget.config.percentToValue(p));
  }

  double snapToTicks(double p) {
    final step = 1 / widget.config.ticks;
    final snapped = (p / step).round() * step;

    if ((snapped - percent).abs() > step * 0.5) {
      HapticFeedback.selectionClick();
    }

    return snapped;
  }

  void handleGesture(Offset pos, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final angle = atan2(
      pos.dy - center.dy,
      pos.dx - center.dx,
    );

    double normalized = angle;

    if (normalized < startAngle) {
      normalized += 2 * pi;
    }

    updateFromAngle(normalized);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);

        return GestureDetector(
          onPanUpdate: (d) => handleGesture(d.localPosition, size),
          onTapDown: (d) => handleGesture(d.localPosition, size),
          child: CustomPaint(
            painter: DialPainter(
              percent: percent,
              config: widget.config,
              startAngle: startAngle,
              sweepAngle: sweepAngle,
            ),
          ),
        );
      },
    );
  }
}
```

# 3. GPU-cheap painter (<0.2 ms)

Only draws lines + one circle.

```dart
class DialPainter extends CustomPainter {
  final double percent;
  final DialConfig config;

  final double startAngle;
  final double sweepAngle;

  DialPainter({
    required this.percent,
    required this.config,
    required this.startAngle,
    required this.sweepAngle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final minorPaint = Paint()
      ..color = Colors.white70
      ..strokeWidth = 2;

    final majorPaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 3;

    final step = sweepAngle / config.ticks;

    for (int i = 0; i <= config.ticks; i++) {
      final angle = startAngle + step * i;

      final isMajor = i % config.majorTickEvery == 0;

      final outer = Offset(
        center.dx + cos(angle) * radius,
        center.dy + sin(angle) * radius,
      );

      final inner = Offset(
        center.dx + cos(angle) * (radius - (isMajor ? 22 : 12)),
        center.dy + sin(angle) * (radius - (isMajor ? 22 : 12)),
      );

      canvas.drawLine(
        inner,
        outer,
        isMajor ? majorPaint : minorPaint,
      );
    }

    final indicatorAngle = startAngle + percent * sweepAngle;

    final knob = Offset(
      center.dx + cos(indicatorAngle) * (radius - 30),
      center.dy + sin(indicatorAngle) * (radius - 30),
    );

    canvas.drawCircle(
      knob,
      8,
      Paint()..color = Colors.orange,
    );
  }

  @override
  bool shouldRepaint(covariant DialPainter oldDelegate) {
    return oldDelegate.percent != percent;
  }
}
```


# 4. Dial presets for camera controls

Zoom

```dart
DialConfig(
  min: 1,
  max: 10,
  ticks: 120,
  majorTickEvery: 10,
  logarithmic: true,
)
```

focus distance

```dart
DialConfig(
  min: 0.1,
  max: 10,
  ticks: 150,
  logarithmic: true,
)
```

ISO

```dart
DialConfig(
  min: 100,
  max: 6400,
  ticks: 60,
  logarithmic: true,
)
```

shutter

```dart
DialConfig(
  min: 1/8000,
  max: 1,
  ticks: 100,
  logarithmic: true,
)
```

# Improvements

A fixed half-arc dial with magnetic snapping, haptics, and predictable mapping requires three layers:

```
gesture → angle → percent → snapped percent → value mapping
```

The dial stops at min/max by clamping percent to [0,1].


# 1. Dial model (supports all camera controls)

Keep value mapping independent of UI.

```dart
import 'dart:math';

class DialConfig {
  final double min;
  final double max;
  final int ticks;
  final int majorTickEvery;
  final bool logarithmic;

  const DialConfig({
    required this.min,
    required this.max,
    this.ticks = 120,
    this.majorTickEvery = 10,
    this.logarithmic = false,
  });

  double percentToValue(double p) {
    if (!logarithmic) {
      return min + p * (max - min);
    }

    return min * pow(max / min, p);
  }

  double valueToPercent(double v) {
    if (!logarithmic) {
      return (v - min) / (max - min);
    }

    return log(v / min) / log(max / min);
  }
}
```


# 2. Gesture → angle conversion

Core trick: convert finger position into an angle around the dial center.

```dart
double angleFromTouch(Offset touch, Offset center) {
  return atan2(
    touch.dy - center.dy,
    touch.dx - center.dx,
  );
}
```

# 3. Normalize angle into dial range

The dial spans 180°.


```dart
const startAngle = pi;
const sweepAngle = pi;

double angleToPercent(double angle) {
  double normalized = angle;

  if (normalized < startAngle) {
    normalized += 2 * pi;
  }

  double percent = (normalized - startAngle) / sweepAngle;

  return percent.clamp(0.0, 1.0);
}
```


# 4. Magnetic tick snapping

Snapping happens in percent space, not value space.

```dart
double snapPercent(double percent, int ticks) {
  final step = 1 / ticks;
  return (percent / step).round() * step;
}
```

# 5. Haptic feedback

Trigger only when crossing a new tick.

```dart
double lastTick = -1;

void maybeHaptic(double percent, int ticks) {
  final tick = (percent * ticks).roundToDouble();

  if (tick != lastTick) {
    lastTick = tick;
    HapticFeedback.selectionClick();
  }
}
```

# 6. Full dial widget

```dart
class CameraDial extends StatefulWidget {
  final DialConfig config;
  final double initialValue;
  final ValueChanged<double> onChanged;

  const CameraDial({
    super.key,
    required this.config,
    required this.initialValue,
    required this.onChanged,
  });

  @override
  State<CameraDial> createState() => _CameraDialState();
}

class _CameraDialState extends State<CameraDial> {
  double percent = 0;

  final startAngle = pi;
  final sweepAngle = pi;

  double lastTick = -1;

  @override
  void initState() {
    super.initState();
    percent = widget.config.valueToPercent(widget.initialValue);
  }

  void update(Offset touch, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final angle = atan2(
      touch.dy - center.dy,
      touch.dx - center.dx,
    );

    double normalized = angle;

    if (normalized < startAngle) {
      normalized += 2 * pi;
    }

    double p = (normalized - startAngle) / sweepAngle;
    p = p.clamp(0.0, 1.0);

    p = snapPercent(p, widget.config.ticks);

    final tick = (p * widget.config.ticks).roundToDouble();

    if (tick != lastTick) {
      lastTick = tick;
      HapticFeedback.selectionClick();
    }

    setState(() => percent = p);

    widget.onChanged(widget.config.percentToValue(p));
  }

  double snapPercent(double percent, int ticks) {
    final step = 1 / ticks;
    return (percent / step).round() * step;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (_, constraints) {
      final size = Size(constraints.maxWidth, constraints.maxHeight);

      return GestureDetector(
        onPanUpdate: (d) => update(d.localPosition, size),
        onTapDown: (d) => update(d.localPosition, size),
        child: CustomPaint(
          painter: DialPainter(
            percent: percent,
            config: widget.config,
            startAngle: startAngle,
            sweepAngle: sweepAngle,
          ),
        ),
      );
    });
  }
}
```

# 7. High-performance painter

This draws ~120 lines, which costs almost nothing on GPU.

```dart
class DialPainter extends CustomPainter {
  final double percent;
  final DialConfig config;
  final double startAngle;
  final double sweepAngle;

  DialPainter({
    required this.percent,
    required this.config,
    required this.startAngle,
    required this.sweepAngle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    final minorPaint = Paint()
      ..color = Colors.white60
      ..strokeWidth = 2;

    final majorPaint = Paint()
      ..color = Colors.orange
      ..strokeWidth = 3;

    final step = sweepAngle / config.ticks;

    for (int i = 0; i <= config.ticks; i++) {
      final angle = startAngle + i * step;

      final isMajor = i % config.majorTickEvery == 0;

      final outer = Offset(
        center.dx + cos(angle) * radius,
        center.dy + sin(angle) * radius,
      );

      final inner = Offset(
        center.dx + cos(angle) * (radius - (isMajor ? 22 : 12)),
        center.dy + sin(angle) * (radius - (isMajor ? 22 : 12)),
      );

      canvas.drawLine(
        inner,
        outer,
        isMajor ? majorPaint : minorPaint,
      );
    }

    final indicatorAngle = startAngle + percent * sweepAngle;

    final knob = Offset(
      center.dx + cos(indicatorAngle) * (radius - 30),
      center.dy + sin(indicatorAngle) * (radius - 30),
    );

    canvas.drawCircle(
      knob,
      8,
      Paint()..color = Colors.orange,
    );
  }

  @override
  bool shouldRepaint(covariant DialPainter oldDelegate) {
    return oldDelegate.percent != percent;
  }
}
```

# 8. Dial presets for camera controls

```dart
<!-- Zoom -->
DialConfig(
 min: 1,
 max: 10,
 ticks: 120,
 logarithmic: true
)
<!-- ISO -->
DialConfig(
 min: 100,
 max: 6400,
 ticks: 60,
 logarithmic: true
)
<!-- Shutter -->
DialConfig(
 min: 1/8000,
 max: 1,
 ticks: 100,
 logarithmic: true
)
<!-- Focus -->
DialConfig(
 min: 0.1,
 max: 10,
 ticks: 150,
 logarithmic: true
)
```


10. One production trick worth adding

Pro camera UIs highlight ticks near the indicator. This creates the cinematic glow effect around the pointer.

```dart
distance = |tickAngle - indicatorAngle|
opacity = exp(-distance * 4)
```

# Improvements

## 1. Velocity-based inertia

Track angular velocity while dragging and continue motion briefly after release.

Add to the dial state:

```dart
double _velocity = 0;
double _lastAngle = 0;
DateTime? _lastTime;
Timer? _inertiaTimer;
```

Update during drag:

```dart
void updateVelocity(double angle) {
  final now = DateTime.now();

  if (_lastTime != null) {
    final dt = now.difference(_lastTime!).inMilliseconds / 1000.0;
    final da = angle - _lastAngle;

    _velocity = da / dt;
  }

  _lastAngle = angle;
  _lastTime = now;
}
```

Start inertia when the finger lifts:

```dart
void startInertia() {
  const friction = 0.92;

  _inertiaTimer?.cancel();

  _inertiaTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
    _velocity *= friction;

    if (_velocity.abs() < 0.001) {
      _inertiaTimer?.cancel();
      return;
    }

    final angle = _lastAngle + _velocity * 0.016;

    updateFromAngle(angle);
    _lastAngle = angle;
  });
}
```

Attach to gesture handlers:

```dart
onPanUpdate: (d) {
  final angle = angleFromTouch(d.localPosition, center);
  updateVelocity(angle);
  updateFromAngle(angle);
},

onPanEnd: (_) => startInertia(),
```

This creates the momentum wheel feel common in camera apps.


## 2. Tick glow around indicator

Compute brightness based on angular distance. Inside the painter loop:

```dart
final indicatorAngle = startAngle + percent * sweepAngle;

final distance = (angle - indicatorAngle).abs();

final glow = exp(-distance * 6);

final paint = Paint()
  ..color = Color.lerp(
      Colors.white30,
      Colors.orange,
      glow,
  )!
  ..strokeWidth = isMajor ? 3 : 2;
```

Result: ticks near the pointer fade brighter.

## 3. Major value labels

Labels appear only on major ticks.

Add inside the paint loop:

```dart
if (isMajor) {
  final textPainter = TextPainter(
    text: TextSpan(
      text: formatLabel(i),
      style: const TextStyle(
        color: Colors.white,
        fontSize: 12,
      ),
    ),
    textDirection: TextDirection.ltr,
  );

  textPainter.layout();

  final labelRadius = radius - 40;

  final offset = Offset(
    center.dx + cos(angle) * labelRadius,
    center.dy + sin(angle) * labelRadius,
  );

  textPainter.paint(
    canvas,
    offset - Offset(textPainter.width / 2, textPainter.height / 2),
  );
}
```

Example formatter:

```dart
String formatLabel(int tickIndex) {
  final percent = tickIndex / config.ticks;
  final value = config.percentToValue(percent);

  return value.toStringAsFixed(1);
}
```
## 4. Smooth tick highlight band

Instead of glowing only the closest ticks, compute a falloff band. Used to scale opacity or length.:

```dart
double band(double distance) {
  return max(0, 1 - distance * 3);
}
```

5. Prevent accidental jumps

Professional camera dials avoid large jumps when a drag begins. Add dead-zone gating:

```dart
bool allowMovement(double angle) {
  final indicatorAngle = startAngle + percent * sweepAngle;

  final delta = (angle - indicatorAngle).abs();

  return delta < 0.7;
}
```

Ignore movement if the finger begins too far from the pointer.

## 6. Frame stability optimization

To keep the painter under ~0.2 ms, avoid per-frame allocations. Move paint objects outside the loop. Avoid rebuilding TextPainter each frame if labels are static—cache them.:

```dart
final minorPaint = Paint();
final majorPaint = Paint();
```

## 7. Dial presets tuned for camera controls

Recommended tick densities:

Dial	Ticks	Major
Zoom	120	10
ISO	60	6
Shutter	100	10
Focus	150	15

Focus requires the highest precision.

## 8. Real production UI detail

Professional camera apps rarely draw all ticks equally. They render:

```dart
center region: bright ticks
edges: dim ticks
outside arc: hidden
```

This keeps the dial visually calm. Implementation:

```dart
final edgeFade = pow(percent - (i / ticks), 2);
opacity = 1 - edgeFade;
```

## 9. Resulting architecture

The full dial becomes:

```
Gesture layer
  ↓
Angle normalization
  ↓
Percent mapping
  ↓
Magnetic snapping
  ↓
Value mapping (zoom/ISO/etc)
  ↓
Painter (ticks + glow + labels)
```
