import 'dart:math';
import 'package:flutter/material.dart';

class RulerDial extends StatefulWidget {
  final double min;
  final double max;
  final double value;
  final ValueChanged<double> onChanged;

  const RulerDial({
    super.key,
    required this.min,
    required this.max,
    required this.value,
    required this.onChanged,
  });

  @override
  State<RulerDial> createState() => _RulerDialState();
}

class _RulerDialState extends State<RulerDial> {
  static const double tickSpacing = 14;
  static const int minorTicks = 5;

  late ScrollController controller;

  double get totalTicks => (widget.max - widget.min) * minorTicks;

  @override
  void initState() {
    super.initState();

    controller = ScrollController(
      initialScrollOffset: widget.value * tickSpacing * minorTicks,
    );

    controller.addListener(() {
      final v = controller.offset / (tickSpacing * minorTicks);
      widget.onChanged(v.clamp(widget.min, widget.max));
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xff3c3a36),
        borderRadius: BorderRadius.circular(40),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          ListView.builder(
            controller: controller,
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            itemCount: totalTicks.toInt(),
            itemBuilder: (context, i) {
              final isMajor = i % minorTicks == 0;

              return SizedBox(
                width: tickSpacing,
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Container(
                    width: 2,
                    height: isMajor ? 22 : 10,
                    decoration: BoxDecoration(
                      color: isMajor
                          ? Colors.pinkAccent.withOpacity(.9)
                          : Colors.white.withOpacity(.5),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            },
          ),

          // center indicator
          Container(
            width: 6,
            height: 34,
            decoration: BoxDecoration(
              color: Colors.pinkAccent,
              borderRadius: BorderRadius.circular(3),
            ),
          ),

          // edge fade
          Positioned.fill(
            child: IgnorePointer(
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            const Color(0xff3c3a36),
                            const Color(0xff3c3a36).withOpacity(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.centerRight,
                          end: Alignment.centerLeft,
                          colors: [
                            const Color(0xff3c3a36),
                            const Color(0xff3c3a36).withOpacity(0),
                          ],
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
