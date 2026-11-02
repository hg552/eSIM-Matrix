import 'package:flutter/widgets.dart';

/// Creates a tab on its first visit, retaining its state and pausing inactive animations.
class LazyTabBody extends StatefulWidget {
  const LazyTabBody({super.key, required this.active, required this.builder});

  final bool active;
  final WidgetBuilder builder;

  @override
  State<LazyTabBody> createState() => _LazyTabBodyState();
}

class _LazyTabBodyState extends State<LazyTabBody> {
  late bool _visited = widget.active;

  @override
  void didUpdateWidget(LazyTabBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    _visited = _visited || widget.active;
  }

  @override
  Widget build(BuildContext context) => TickerMode(
    enabled: widget.active,
    child: _visited
        ? Builder(builder: widget.builder)
        : const SizedBox.shrink(),
  );
}
